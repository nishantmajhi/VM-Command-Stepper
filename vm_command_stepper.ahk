#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
SendMode "Event" ; VirtualBox's console window expects real simulated keystrokes
                  ; (like an actual keyboard driver), not raw Unicode packet
                  ; injection. SendInput/SendText can get dropped or scrambled
                  ; by it; Event mode (keybd_event-based) is what VMs and games
                  ; reliably recognise.

; VM Command Stepper — steps through a list of shell commands and types them,
; one at a time, into whichever window has keyboard focus.
;
; This file is the plumbing: the file on disk, the GUI, the hotkeys and the
; keystrokes. Every decision it makes — what counts as a line worth keeping,
; where the pointer goes after a reload, which characters need escaping, and
; whether a batch of lines is safe to fire unattended — lives in lib/core.ahk,
; which has no side effects and is what tests/run.ahk exercises.
;
; See README.md for what the hotkeys do and what this cannot do.

#Include lib\core.ahk

CommandsFile := A_ScriptDir "\commands.txt"
CharDelayMin := 3   ; ms, lower bound of the random per-character delay — raise both bounds (e.g. 15-60)
CharDelayMax := 25  ; ms, upper bound of the random per-character delay   if the VM console drops/garbles characters
SendAllDelay := 300 ; ms to wait after each Enter during Send All, before typing the next line
ABORT_KEY := "Esc"  ; pressed during a Send All, stops it — see AbortSend()

; Items is the whole file, as ParseCommandFile returned it. Lines is the subset
; the list shows: commands and the comments that give them context. CurrentIndex
; indexes Lines, and Lines.Length + 1 means "past the end".
Items := []
Lines := []
CurrentIndex := 1

; Tracks which row was "current" last time the list was drawn, so RefreshList
; can just move the highlight from PrevIndex to CurrentIndex instead of tearing
; down and rebuilding the whole ListView every time — that rebuild was what made
; the list appear to "jump around".
PrevIndex := 0

MyGui := ""
LV := ""
PreviewBox := ""
StatusText := ""
btnBack := ""
btnPaste := ""
btnSkip := ""
MarginX := 10

; Remembers the last window OTHER than this script's own that had focus, so that
; clicking a button in this GUI (which steals keyboard focus) can be corrected
; by re-activating the real target (e.g. the VM window) right before typing.
; Updated continuously by a background timer.
LastForeignHwnd := 0
OwnPid := DllCall("GetCurrentProcessId", "UInt")

; Prevents a send from being triggered again while one is already in progress
; (e.g. a fast double-click, or a hotkey auto-repeating while held down).
; Without this, two sends can interleave their characters into the VM, which is
; what produced garbled text like "ddgdg".
;
; It also locks out everything that moves the pointer. Hotkeys interrupt a
; running thread at its next Sleep and SendSlow sleeps between every character,
; so Back, Next and Reload all used to land in the middle of a Send All. Reload
; was the bad one: it reset the position to 1 and the loop simply carried on
; from the top of the file.
Busy := false

; The Send All currently running, as a SendSession over a snapshot of Lines.
; "" when nothing is running. AbortSend() is the only thing that stops one.
CurrentSession := ""

Armed := true  ; false while the global hotkeys are suspended

LoadCommands()
BuildGui()
SetTimer(TrackForeignWindow, 150)

; ---------------- Hotkeys ----------------

; Pause is exempt from Suspend so it can turn the others back on. Without it
; these five keys are taken from the whole system for as long as this script
; runs, which is the rest of the session: F5 stops refreshing your browser and
; F6-F8 do nothing anywhere.
#SuspendExempt
Pause::ToggleArmed()
#SuspendExempt False

F5::ReloadCommands()
^F5::SendAll()
F6::GoBack()
F7::PasteCurrentLine()
F8::SkipLine()

; ---------------- Core functions ----------------

; Simple lock so overlapping sends can't interleave characters, and so nothing
; can move the pointer out from under a running Send All.
; Returns false (and does nothing) if a send is already in progress.
BeginSend() {
    global Busy
    if Busy {
        ShowStatus("Still sending — press " ABORT_KEY " to stop, or wait for it to finish.")
        return false
    }
    Busy := true
    return true
}
EndSend() {
    global Busy
    Busy := false
}

; Refuse anything that moves the pointer while a send is in progress.
RefuseWhileBusy(what) {
    global Busy
    if !Busy
        return false
    ShowStatus(what " is not available while a send is running — press " ABORT_KEY " to stop it.")
    return true
}

ToggleArmed() {
    global Armed
    Suspend -1
    Armed := !A_IsSuspended
    if Armed {
        ShowStatus("Hotkeys armed. Pause suspends them.")
        A_IconTip := "VM Command Stepper — hotkeys armed"
    } else {
        ShowStatus("Hotkeys suspended — F5-F8 belong to the rest of Windows again. Pause re-arms them.")
        A_IconTip := "VM Command Stepper — hotkeys suspended"
    }
}

; Runs every 150ms. If the currently active window belongs to another process,
; record it as the "foreign" (i.e. real target, like VirtualBox) window.
;
; Comparing process ids rather than the GUI's window handle matters now that
; this script raises dialogs: a MsgBox is active, is not the GUI, and would
; otherwise be remembered as the window to type into — and by the time anything
; typed, it would be gone.
TrackForeignWindow() {
    global LastForeignHwnd, OwnPid
    hwnd := WinExist("A")
    if IsOwnWindow(hwnd, OwnPid, WindowPid)
        return
    LastForeignHwnd := hwnd
}

WindowPid(hwnd) {
    try return WinGetPID("ahk_id " hwnd)
    return 0
}

; Makes sure the VM (or whatever window was last focused before this GUI) is
; actually focused before we type into it. This is what makes clicking the
; on-screen buttons behave the same as pressing the physical hotkeys — without
; it, clicking a button leaves focus on this GUI and keystrokes never reach the
; VM. Returns false when the target has gone, so the caller can decline to type
; into whatever happens to be in front instead.
FocusTarget() {
    global LastForeignHwnd, OwnPid
    active := WinExist("A")
    if !IsOwnWindow(active, OwnPid, WindowPid)
        return true            ; something else is focused: type into it, as documented

    if !LastForeignHwnd {
        ShowStatus("Nothing to type into yet — click into your VM window first.")
        return false
    }
    if !WinExist("ahk_id " LastForeignHwnd) {
        ShowStatus("Warning: could not find the target window to type into.")
        return false
    }
    WinActivate("ahk_id " LastForeignHwnd)
    WinWaitActive("ahk_id " LastForeignHwnd, , 1)
    return true
}

LoadCommands() {
    global CommandsFile, Items, Lines, CurrentIndex

    if !FileExist(CommandsFile) {
        selected := FileSelect("1", , "Select your commands file", "Text Files (*.txt)")
        if selected = ""
            ExitApp()
        CommandsFile := selected
    }

    ; The original let a read failure throw out of ReloadCommands, which on a
    ; locked or deleted file killed the script mid-run with a stack trace.
    ;
    ; UTF-8 rather than the system codepage because that is what a text file is
    ; now, and because a file that is not valid UTF-8 decodes to replacement
    ; characters — which ScanUntypable then reports, so a wrongly-encoded file
    ; is named on screen rather than discovered inside the VM.
    raw := ""
    try {
        raw := FileRead(CommandsFile, "UTF-8")
    } catch as err {
        MsgBox("Could not read:`n" CommandsFile "`n`n" err.Message
             , "VM Command Stepper", "Icon!")
        return false
    }

    previousText := CurrentCommandText()
    previousIndex := CurrentIndex

    Items := ParseCommandFile(raw)
    Lines := VisibleItems(Items)

    ; The original ended LoadCommands with CurrentIndex := 1 unconditionally, so
    ; pressing Reload after editing the file part-way through a run silently
    ; sent you back to the top and the next Paste retyped commands that had
    ; already run.
    CurrentIndex := RestoreIndexAfterReload(Lines, previousText, previousIndex)
    return true
}

CurrentCommandText() {
    global Lines, CurrentIndex
    if IsSendable(Lines, CurrentIndex)
        return Lines[CurrentIndex].text
    return ""
}

ReloadCommands() {
    global Lines
    if RefuseWhileBusy("Reload")
        return
    if !LoadCommands()
        return
    RefreshList(true)
    ShowStatus("Reloaded " CountPending(Lines, 1) " commands.")
    WarnAboutUntypable()
}

; Send in Event mode goes through the active keyboard layout, so a smart quote
; or an em dash pasted in from a document does not arrive as itself. Say so at
; load time rather than letting it be discovered inside the VM.
WarnAboutUntypable() {
    global Lines
    warning := FormatUntypableWarning(ScanUntypable(Lines))
    if warning != ""
        ShowStatus(warning)
}

; Types the current line into the focused window WITHOUT pressing Enter, so you
; can look it over and run it yourself, then advances the pointer to the next
; command — stepping over any comment rows in between.
PasteCurrentLine() {
    global Lines, CurrentIndex
    if !IsSendable(Lines, CurrentIndex) {
        CurrentIndex := ClampIndex(Lines, CurrentIndex)
        if !IsSendable(Lines, CurrentIndex) {
            ShowStatus("No more commands.")
            RefreshList()
            return
        }
    }
    if !BeginSend()
        return
    try {
        line := Lines[CurrentIndex].text
        if !FocusTarget()
            return
        SendSlow(line)
        CurrentIndex := NextSendable(Lines, CurrentIndex)
        RefreshList()
    } finally {
        EndSend()
    }
}

; Sends every remaining line + Enter, one after another, until the list is
; exhausted — use for commands you trust to run unattended.
;
; "Trust" is doing a lot of work in that sentence, which is why this asks first.
; The pacing is a fixed delay: it has no idea whether the previous command
; finished, so a line that opens an editor, prompts for a password or opens a
; remote shell makes everything after it land somewhere unintended. ScanHazards
; finds those lines and the confirmation names them.
SendAll() {
    global Lines, CurrentIndex, SendAllDelay, CurrentSession, ABORT_KEY

    if !BeginSend()
        return

    try {
        start := ClampIndex(Lines, CurrentIndex)
        pending := CountPending(Lines, start)
        if pending = 0 {
            ShowStatus("No more commands.")
            return
        }

        prompt := FormatSendAllPrompt(pending, ScanHazards(Lines, start), ABORT_KEY)
        if MsgBox(prompt, "Send All — VM Command Stepper", "YesNo Icon! Default2") != "Yes" {
            ShowStatus("Send All cancelled.")
            return
        }

        ; A snapshot, so that nothing which happens while this runs can move the
        ; cursor it is iterating.
        CurrentSession := SendSession(Lines, start)

        ; Registered only for the duration of the run, so Esc belongs to
        ; whatever you are using for the rest of the time.
        ; "S" makes it exempt from Suspend, so pressing Pause during a run
        ; cannot take away the one key that stops it.
        try Hotkey(ABORT_KEY, AbortSend, "On S")

        while CurrentSession.HasNext() {
            item := CurrentSession.Take()
            if item = ""
                break
            if !FocusTarget() {
                CurrentSession.Abort()
                break
            }
            SendSlow(item.text)
            if CurrentSession.aborted
                break              ; no Enter: a half-typed line is not a run command
            Send("{Enter}")
            CurrentIndex := NextSendable(Lines, CurrentSession.lastIndex)
            RefreshList()
            if CurrentSession.HasNext()
                Sleep(SendAllDelay)
        }

        if CurrentSession.aborted
            ShowStatus("Stopped after " CurrentSession.sent " of " pending
                     . ". The last line may be half-typed — check the VM before continuing.")
        else
            ShowStatus("All " CurrentSession.sent " commands sent.")
    } finally {
        try Hotkey(ABORT_KEY, AbortSend, "Off")
        CurrentSession := ""
        EndSend()
    }
}

; The abort key, live only while a Send All is running. It sets a flag rather
; than doing anything itself: this runs as an interrupting thread, and the run
; has to unwind in its own.
AbortSend(*) {
    global CurrentSession
    if CurrentSession != ""
        CurrentSession.Abort()
}

SkipLine() {
    global Lines, CurrentIndex
    if RefuseWhileBusy("Next")
        return
    CurrentIndex := NextSendable(Lines, CurrentIndex)
    RefreshList()
}

GoBack() {
    global Lines, CurrentIndex
    if RefuseWhileBusy("Back")
        return
    previous := PrevSendable(Lines, CurrentIndex)
    if previous
        CurrentIndex := previous
    RefreshList()
}

SendSlow(text) {
    global CharDelayMin, CharDelayMax, CurrentSession
    Loop Parse, text {
        Send(EscapeForSend(A_LoopField))
        ; Checked between characters so the abort key stops within a few
        ; milliseconds rather than at the end of a 200-character line.
        if CurrentSession != "" && CurrentSession.aborted
            return
        Sleep(Random(CharDelayMin, CharDelayMax))
    }
}

; ---------------- GUI ----------------

BuildGui() {
    global MyGui, LV, PreviewBox, StatusText, btnBack, btnPaste, btnSkip
    global Lines, CurrentIndex

    MyGui := Gui("+AlwaysOnTop +Resize", "VM Command Stepper")
    MyGui.SetFont("s10", "Consolas")

    FileMenu := Menu()
    FileMenu.Add("Reload`tF5", (*) => ReloadCommands())
    FileMenu.Add("Send All`tCtrl+F5", (*) => SendAll())
    TopMenuBar := MenuBar()
    TopMenuBar.Add("File", FileMenu)
    MyGui.MenuBar := TopMenuBar

    LV := MyGui.Add("ListView", "w600 h300 vLineList", ["#", "Command"])
    LV.ModifyCol(1, 40)
    LV.ModifyCol(2, 540)
    LV.OnEvent("Click", LV_Click)
    LV.OnEvent("DoubleClick", LV_DoubleClick)

    StatusText := MyGui.Add("Text", "xm y+10 w600", "")
    PreviewBox := MyGui.Add("Edit", "w600 h50 ReadOnly")

    btnBack := MyGui.Add("Button", "xm y+10 w140", "Back (F6)")
    btnBack.OnEvent("Click", (*) => GoBack())

    btnPaste := MyGui.Add("Button", "x+10 w140", "Paste (F7)")
    btnPaste.OnEvent("Click", (*) => PasteCurrentLine())

    btnSkip := MyGui.Add("Button", "x+10 w140", "Next (F8)")
    btnSkip.OnEvent("Click", (*) => SkipLine())

    MyGui.OnEvent("Close", (*) => ExitApp())
    MyGui.OnEvent("Size", GuiResize)
    MyGui.Show("w620 h480")

    A_IconTip := "VM Command Stepper — hotkeys armed"

    CurrentIndex := ClampIndex(Lines, CurrentIndex)
    RefreshList(true)
    WarnAboutUntypable()

    ; Run the layout once immediately so it matches the size we just showed
    ; at, rather than waiting for the user to trigger a resize manually.
    MyGui.GetClientPos(, , &gw, &gh)
    GuiResize(MyGui, 0, gw, gh)
}

; Recomputes every control's position/size whenever the window is resized,
; the way a CSS flex/grid layout would reflow instead of leaving controls
; pinned at their original size and position.
GuiResize(GuiObj, MinMax, Width, Height) {
    global LV, PreviewBox, StatusText, btnBack, btnPaste, btnSkip, MarginX

    if MinMax = -1 || !IsObject(LV)  ; minimized, or fired before controls exist
        return

    ContentWidth := Width - MarginX * 2
    if ContentWidth < 300
        ContentWidth := 300

    ; Space reserved below the list for: status text, preview box, gaps,
    ; and the button row.
    BottomReserved := 150
    ListHeight := Height - BottomReserved
    if ListHeight < 100
        ListHeight := 100

    LV.Move(MarginX, MarginX, ContentWidth, ListHeight)
    LV.ModifyCol(2, ContentWidth - 40 - 20)

    StatusY := MarginX + ListHeight + 10
    StatusText.Move(MarginX, StatusY, ContentWidth)

    PreviewY := StatusY + 25
    PreviewBox.Move(MarginX, PreviewY, ContentWidth, 50)

    ButtonY := PreviewY + 60
    ButtonGap := 10
    ButtonCount := 3
    ButtonWidth := (ContentWidth - ButtonGap * (ButtonCount - 1)) // ButtonCount

    btnBack.Move(MarginX, ButtonY, ButtonWidth)
    btnPaste.Move(MarginX + ButtonWidth + ButtonGap, ButtonY, ButtonWidth)
    btnSkip.Move(MarginX + (ButtonWidth + ButtonGap) * 2, ButtonY, ButtonWidth)
}

; Single-clicking a row just moves the pointer there (like using Back/Next
; to navigate) — nothing is sent to the VM. Whatever you click becomes the
; "current" line, so Paste (F7) or double-click will act on it next. Clicking
; a comment row moves to the next command, because a comment cannot be sent.
LV_Click(ctrl, rowNumber) {
    global Lines, CurrentIndex
    if rowNumber = 0  ; click on empty area below the list
        return
    if RefuseWhileBusy("Choosing a line")
        return
    CurrentIndex := ClampIndex(Lines, rowNumber)
    RefreshList()
}

; Double-clicking a row in the list jumps straight to that command and
; pastes it immediately — no need to Back/Next your way there.
LV_DoubleClick(ctrl, rowNumber) {
    global Lines, CurrentIndex
    if rowNumber = 0  ; double-click on empty area below the list
        return
    if RefuseWhileBusy("Choosing a line")
        return
    CurrentIndex := ClampIndex(Lines, rowNumber)
    RefreshList()
    PasteCurrentLine()
}

; fullRebuild = true forces a Delete()+re-Add of every row (needed after
; loading a different file, since the actual line text/count changed).
; Otherwise we only move the "current line" highlight from the old row
; to the new one, and scroll just enough to keep the current row visible
; (never a full re-center) — so the list mostly stays where you scrolled
; it, and only nudges when the next command would otherwise be hidden.
RefreshList(fullRebuild := false) {
    global LV, Lines, CurrentIndex, PreviewBox, PrevIndex

    if fullRebuild || LV.GetCount() != Lines.Length {
        LV.Delete()
        ; The "#" column numbers the commands, not the rows, and is left blank
        ; on a comment. That is what marks a comment as context rather than
        ; something waiting to be typed.
        commandNumber := 0
        for i, item in Lines {
            label := ""
            if item.kind = "command"
                label := ++commandNumber
            LV.Add(i = CurrentIndex ? "Select" : "", label, item.text)
        }
    } else {
        if PrevIndex >= 1 && PrevIndex <= Lines.Length && PrevIndex != CurrentIndex
            LV.Modify(PrevIndex, "-Select")
        if CurrentIndex >= 1 && CurrentIndex <= Lines.Length
            LV.Modify(CurrentIndex, "Select")
    }
    PrevIndex := CurrentIndex

    if IsSendable(Lines, CurrentIndex) {
        LV.Modify(CurrentIndex, "Vis")  ; minimal scroll: only moves if the row is actually off-screen, and only by as much as needed to reveal it
        PreviewBox.Value := Lines[CurrentIndex].text
        ShowStatus("Command " CommandOrdinal(Lines, CurrentIndex) " of "
                 . CountPending(Lines, 1) " (file line " Lines[CurrentIndex].line "):")
    } else {
        PreviewBox.Value := "(no more commands)"
        ShowStatus(CountPending(Lines, 1) " commands, all sent.")
    }
}

; Which command this is, counting only sendable rows.
CommandOrdinal(items, index) {
    n := 0
    Loop Min(index, items.Length) {
        if items[A_Index].kind = "command"
            n++
    }
    return n
}

ShowStatus(msg) {
    global StatusText
    if IsObject(StatusText)
        StatusText.Text := msg
}
