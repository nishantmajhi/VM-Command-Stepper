#Requires AutoHotkey v2.0

; original.ahk — the pre-cleanup decision code, transcribed with its I/O lifted
; out, so the suite can prove that each regression test fails against it.
;
; The original cannot simply be run: vm_command_stepper.ahk at commit 74238bf is
; one file that builds a GUI and registers F5-F8 as unconditional global
; hotkeys the moment it loads. Running it from a test would take F5 away from
; the machine running the suite, and `Send` would type into whatever window the
; developer happened to have in front. So the three functions whose decisions
; changed are copied here verbatim apart from the calls that touch the outside
; world, and CheckTranscription() below asserts that what was copied is still
; what that commit contains — a transcription that has silently drifted proves
; nothing.
;
; Nothing in this file is used by the program. It exists only to be wrong.

ORIGINAL_COMMIT := "74238bf"


; Verbatim from LoadCommands(), minus the FileExist/FileSelect/FileRead that
; produced `raw` and minus the `global` declaration.
Original_LoadLines(raw) {
    rawLines := StrSplit(raw, "`n", "`r")
    Lines := []
    for line in rawLines {
        trimmed := Trim(line)
        if trimmed = "" || SubStr(trimmed, 1, 1) = "#"
            continue
        Lines.Push(line)
    }
    return Lines
}


; Verbatim.
Original_EscapeForSend(ch) {
    switch ch {
        case "{": return "{{}"
        case "}": return "{}}"
        case "!": return "{!}"
        case "^": return "{^}"
        case "+": return "{+}"
        case "#": return "{#}"
        default:  return ch
    }
}


; ReloadCommands() -> LoadCommands(), which ends `CurrentIndex := 1`. `state`
; stands in for the globals the original shared between them.
Original_Reload(state, raw) {
    state.Lines := Original_LoadLines(raw)
    state.CurrentIndex := 1
}


; Verbatim from SendAll(), with FocusTarget/SendSlow/Send/RefreshList/ShowStatus
; replaced by recording the line, and with the two points where the original
; yields to other threads made explicit.
;
; Those yields are the whole point. AHK runs a hotkey press as a new thread that
; interrupts the current one at its next Sleep, and the original sleeps between
; every character of SendSlow and again for SendAllDelay after each Enter. So
; anything F5, F6 or F8 does to CurrentIndex lands in the middle of this loop,
; which reads that global fresh on every iteration.
;
; `cap` is a runaway guard this transcription adds and the original does not
; have; reaching it is itself a finding.
Original_SendAll(state, onYield, cap := 200) {
    typed := []
    runaway := false

    while state.CurrentIndex <= state.Lines.Length {
        line := state.Lines[state.CurrentIndex]

        ; FocusTarget()
        ; SendSlow(line) — sleeps between every character
        typed.Push(line)
        if (typed.Length >= cap) {
            runaway := true
            break
        }
        onYield(state, "sending")

        ; Send("{Enter}")
        state.CurrentIndex++
        ; RefreshList()
        if state.CurrentIndex <= state.Lines.Length
            onYield(state, "delay")   ; Sleep(SendAllDelay)
    }

    return { typed: typed, runaway: runaway, index: state.CurrentIndex }
}


; Verbatim from TrackForeignWindow(), with WinExist("A") lifted into a
; parameter. MyGuiHwnd is 0 when there is no GUI yet.
Original_TracksAsForeign(hwnd, myGuiHwnd) {
    if hwnd && (!myGuiHwnd || hwnd != myGuiHwnd)
        return true
    return false
}


; ── Transcription fidelity ────────────────────────────────────────────────────

; Exact lines that must still be present in vm_command_stepper.ahk at
; ORIGINAL_COMMIT. If one of them has gone, the transcriptions above are no
; longer a record of anything and the regression checks that lean on them are
; worthless — so that is reported as a failure, not quietly skipped.
OriginalSnippets() {
    return [
        "        if trimmed = `"`" || SubStr(trimmed, 1, 1) = `"#`"",
        "            continue",
        "        Lines.Push(line)",
        "    CurrentIndex := 1",
        "        while CurrentIndex <= Lines.Length {",
        "            if CurrentIndex <= Lines.Length",
        "                Sleep(SendAllDelay)",
        "        case `"{`": return `"{{}`"",
        "    if hwnd && (!IsObject(MyGui) || hwnd != MyGui.Hwnd)",
        "F5::ReloadCommands()",
        "^F5::SendAll()"
    ]
}


; Fetch the original source from git. Returns "" when git is unavailable or the
; commit has gone, so the caller can skip rather than fail.
FetchOriginalSource(repoDir, commit) {
    temp := A_Temp "\vmcs-original-" A_TickCount ".ahk"
    try {
        RunWait(A_ComSpec ' /c git show ' commit ':vm_command_stepper.ahk > "' temp '" 2>nul'
              , repoDir, "Hide")
    } catch {
        return ""
    }
    if (!FileExist(temp))
        return ""
    text := ""
    try text := FileRead(temp, "UTF-8")
    try FileDelete(temp)
    return text
}
