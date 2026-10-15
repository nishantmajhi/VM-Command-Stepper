#Requires AutoHotkey v2.0

; core.ahk — every decision VM Command Stepper makes, with none of the plumbing.
;
; Nothing in this file sends a keystroke, reads a file, touches a window or
; draws a control. It takes strings and returns values, which is what makes it
; testable: tests/run.ahk includes this file directly and calls into it. The
; entry point, vm_command_stepper.ahk, supplies the real file, the real GUI and
; the real input.
;
; The split exists because the two things that went wrong in this script were
; both decisions, not plumbing: what counts as a line worth keeping, and whether
; a batch of lines is safe to fire unattended. Neither was reachable from a test
; while it lived between a ListView and a keybd_event call.


; ── Parsing ───────────────────────────────────────────────────────────────────

; ParseCommandFile(text) -> Array of items.
;
; An item is { kind, text, line }:
;   kind  "command" | "comment" | "blank"
;   text  the line exactly as it appeared, untrimmed — leading whitespace is
;         load-bearing when the line is a fragment of a YAML or config file
;   line  1-based line number in the source file, so a warning can name it
;
; Every line in the file produces an item, including the ones that are never
; typed. The original dropped comments and blanks at load time, which meant the
; section headers that say "paste inside nano" — the only thing distinguishing a
; command from a fragment of a config file — never reached the screen. Keeping
; them here also keeps the line numbers honest, so a warning can point at a line
; the user can actually find in their editor.
ParseCommandFile(text) {
    items := []

    ; Genuinely empty is no lines at all; everything else has at least one.
    if (text = "")
        return items

    ; A file ending in a newline yields a final empty field that is an artifact
    ; of the terminator, not a blank line in the document. Drop exactly one —
    ; after the emptiness test above, so that a file of just a newline is still
    ; the one empty line it is.
    if (SubStr(text, -1) = "`n")
        text := SubStr(text, 1, StrLen(text) - 1)
    if (SubStr(text, -1) = "`r")
        text := SubStr(text, 1, StrLen(text) - 1)

    ; StrSplit("") yields nothing at all, which would turn a file of a single
    ; newline into no lines rather than the one empty line it is.
    if (text = "") {
        items.Push({ kind: "blank", text: "", line: 1 })
        return items
    }

    n := 0
    for raw in StrSplit(text, "`n", "`r") {
        n++
        trimmed := Trim(raw)
        kind := "command"
        if (trimmed = "")
            kind := "blank"
        else if (SubStr(trimmed, 1, 1) = "#")
            kind := "comment"
        items.Push({ kind: kind, text: raw, line: n })
    }
    return items
}

; VisibleItems(items) -> the subset the list shows.
;
; Comments are shown because they are the context that says whether the next
; line is a command or a line of a file being typed into an editor. Blanks are
; not, because a runbook is mostly blank-separated sections and fifty empty rows
; would bury the commands. The consequence is recorded in the README: a blank
; line inside a heredoc is not reproduced.
VisibleItems(items) {
    out := []
    for item in items {
        if (item.kind != "blank")
            out.Push(item)
    }
    return out
}


; ── Navigation ────────────────────────────────────────────────────────────────
;
; Indexes below are into a visible list — the array VisibleItems returned — and
; a position of Length+1 means "past the end", which is how the caller knows
; there is nothing left to send.

IsSendable(items, index) {
    return index >= 1 && index <= items.Length && items[index].kind = "command"
}

; The next sendable position strictly after `from`, or Length+1 if there is
; none. Comments are stepped over rather than landed on.
NextSendable(items, from) {
    i := from + 1
    while (i <= items.Length) {
        if (items[i].kind = "command")
            return i
        i++
    }
    return items.Length + 1
}

; The previous sendable position strictly before `from`, or 0 if there is none.
; 0 rather than `from` so the caller can tell "already at the top" from "moved".
PrevSendable(items, from) {
    i := from - 1
    while (i >= 1) {
        if (items[i].kind = "command")
            return i
        i--
    }
    return 0
}

FirstSendable(items) {
    return NextSendable(items, 0)
}

; Force an arbitrary index onto a sendable position or onto the past-the-end
; slot. Used after a reload, when the index came from a list that no longer
; exists.
ClampIndex(items, index) {
    if (items.Length = 0)
        return 1
    if (index < 1)
        return FirstSendable(items)
    if (index > items.Length)
        return items.Length + 1
    if (items[index].kind = "command")
        return index
    return NextSendable(items, index)
}

; RestoreIndexAfterReload(newItems, previousText, previousIndex) -> index
;
; The original reset the position to 1 on every reload, so pressing F5 after
; editing the file part-way through a run silently sent you back to the top —
; and the next Paste retyped a command that had already run. Preserving the
; numeric index instead is just as wrong, because editing the file is exactly
; what moves the numbers.
;
; So match on the text. If the command that was current still exists, go to it,
; preferring the occurrence closest to where it used to be — `exit` and `ls -l`
; appear many times in a real runbook. Only when it has gone entirely does the
; index get clamped.
RestoreIndexAfterReload(newItems, previousText, previousIndex) {
    if (previousText = "")
        return ClampIndex(newItems, previousIndex)

    best := 0
    bestDistance := ""
    for i, item in newItems {
        if (item.kind != "command" || item.text != previousText)
            continue
        distance := Abs(i - previousIndex)
        if (bestDistance = "" || distance < bestDistance) {
            best := i
            bestDistance := distance
        }
    }
    if (best)
        return best
    return ClampIndex(newItems, previousIndex)
}


; ── Escaping ──────────────────────────────────────────────────────────────────

; Send() treats { } ! ^ + # as special (brace and hotkey-modifier) characters.
; SendText avoided this problem by injecting raw Unicode instead — but that is
; exactly what VirtualBox does not handle well. So with Send(), each of these
; must be individually escaped by wrapping it in braces: "!" becomes "{!}", so
; it is typed literally rather than interpreted as a modifier key.
;
; Those six are the complete set. ~ $ * < > & are special in a hotkey
; *definition*, not in a Send string, and are sent literally.
EscapeForSend(ch) {
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

; The whole line, escaped, for callers that want to check the result rather than
; type it a character at a time.
EscapeLine(text) {
    out := ""
    Loop Parse, text
        out .= EscapeForSend(A_LoopField)
    return out
}


; ── Load-time validation ──────────────────────────────────────────────────────

; Characters this script can actually type. Send in Event mode goes through
; keybd_event and the active keyboard layout; anything outside printable ASCII
; either needs a Unicode packet — the mechanism this whole script exists to
; avoid, because VirtualBox drops them — or a key the layout does not have.
; Tab is included because it is a real key; every other control character is
; not, and a stray one means the file was decoded wrongly.
IsTypableChar(ch) {
    code := Ord(ch)
    return code = 9 || (code >= 32 && code <= 126)
}

; ScanUntypable(items) -> Array of { line, index, text, char, code }
;
; One entry per offending character. Comments are not scanned: they are never
; typed, and an em dash in a section header is not a problem. U+FFFD shows up
; here too, which is what a file that was not really UTF-8 decodes to — so this
; doubles as an encoding check.
ScanUntypable(items) {
    found := []
    for i, item in items {
        if (item.kind != "command")
            continue
        Loop Parse, item.text {
            if (!IsTypableChar(A_LoopField))
                found.Push({ line: item.line, index: i, text: item.text
                           , char: A_LoopField, code: Ord(A_LoopField) })
        }
    }
    return found
}

; A one-line summary of a ScanUntypable result, or "" when it found nothing.
FormatUntypableWarning(found) {
    if (found.Length = 0)
        return ""

    seen := Map()
    order := []
    for entry in found {
        if (!seen.Has(entry.line)) {
            seen[entry.line] := true
            order.Push(entry.line)
        }
    }

    listed := ""
    Loop Min(order.Length, 5)
        listed .= (listed = "" ? "" : ", ") order[A_Index]
    if (order.Length > 5)
        listed .= " and " (order.Length - 5) " more"

    noun := order.Length = 1 ? "line has" : "lines have"
    return order.Length " " noun " characters this script cannot type (line "
         . listed "). They will not arrive correctly in the VM."
}


; ── Shell segmentation ────────────────────────────────────────────────────────

; SplitShellSegments(line) -> Array of segment strings.
;
; Splits on ; && || | & while respecting single quotes, double quotes and
; backslash escapes. Quote awareness is not a nicety here: a runbook contains
;
;     sudo grep -E "PermitRootLogin|PubkeyAuthentication|UsePAM" /etc/ssh/sshd_config
;
; and a naive split on "|" invents three commands that were never there.
SplitShellSegments(line) {
    segments := []
    current := ""
    inSingle := false
    inDouble := false
    i := 1
    len := StrLen(line)

    while (i <= len) {
        ch := SubStr(line, i, 1)

        if (ch = "\" && !inSingle && i < len) {
            current .= ch SubStr(line, i + 1, 1)
            i += 2
            continue
        }
        if (ch = "'" && !inDouble) {
            inSingle := !inSingle
            current .= ch
            i++
            continue
        }
        if (ch = '"' && !inSingle) {
            inDouble := !inDouble
            current .= ch
            i++
            continue
        }
        if (!inSingle && !inDouble) {
            two := SubStr(line, i, 2)
            if (two = "&&" || two = "||") {
                segments.Push(current)
                current := ""
                i += 2
                continue
            }
            if (ch = ";" || ch = "|" || ch = "&") {
                segments.Push(current)
                current := ""
                i++
                continue
            }
        }
        current .= ch
        i++
    }

    segments.Push(current)

    out := []
    for segment in segments {
        trimmed := Trim(segment)
        if (trimmed != "")
            out.Push(trimmed)
    }
    return out
}

; Tokenise one segment into words, honouring quotes so that a quoted argument
; stays one token. The quotes themselves are stripped.
SplitWords(segment) {
    words := []
    current := ""
    started := false
    inSingle := false
    inDouble := false
    i := 1
    len := StrLen(segment)

    while (i <= len) {
        ch := SubStr(segment, i, 1)

        if (ch = "\" && !inSingle && i < len) {
            current .= SubStr(segment, i + 1, 1)
            started := true
            i += 2
            continue
        }
        if (ch = "'" && !inDouble) {
            inSingle := !inSingle
            started := true
            i++
            continue
        }
        if (ch = '"' && !inSingle) {
            inDouble := !inDouble
            started := true
            i++
            continue
        }
        if ((ch = " " || ch = "`t") && !inSingle && !inDouble) {
            if (started)
                words.Push(current)
            current := ""
            started := false
            i++
            continue
        }
        current .= ch
        started := true
        i++
    }
    if (started)
        words.Push(current)
    return words
}

; Prefixes that are not the command: sudo and its friends, and the VAR=value
; assignments a shell allows in front of one. `sudo -u bob nano x` has to reach
; `nano`, not stop at `-u`.
PREFIX_COMMANDS := Map("sudo", true, "doas", true, "env", true, "time", true
                            , "nohup", true, "command", true, "exec", true)
PREFIX_FLAGS_WITH_ARG := Map("-u", true, "-g", true, "-U", true, "-p", true, "-C", true)

; EffectiveCommand(segment) -> { name, args }, name lower-cased and stripped of
; any directory part, args being everything after it.
EffectiveCommand(segment) {
    words := SplitWords(segment)
    i := 1
    while (i <= words.Length) {
        word := words[i]
        lower := StrLower(word)

        if (RegExMatch(word, "^[A-Za-z_][A-Za-z0-9_]*=")) {
            i++
            continue
        }
        if (PREFIX_COMMANDS.Has(lower)) {
            i++
            ; Step over the prefix's own switches, taking the argument with the
            ; ones that have one.
            while (i <= words.Length && SubStr(words[i], 1, 1) = "-") {
                if (PREFIX_FLAGS_WITH_ARG.Has(words[i]))
                    i++
                i++
            }
            continue
        }
        break
    }
    if (i > words.Length)
        return { name: "", args: [] }

    name := words[i]
    if (InStr(name, "/"))
        name := SubStr(name, InStr(name, "/", , -1) + 1)

    args := []
    Loop words.Length - i
        args.Push(words[i + A_Index])
    return { name: StrLower(name), args: args }
}

HasFlag(args, flags) {
    for arg in args {
        for flag in flags {
            if (arg = flag)
                return true
        }
    }
    return false
}


; ── Send All safety ───────────────────────────────────────────────────────────
;
; Send All types each remaining line, presses Enter, waits a fixed delay and
; moves on. It has no idea whether the previous command finished, so the pacing
; is only ever right for commands that return promptly and prompt for nothing.
; The runbook this was written for contains
; `sudo nano /etc/netplan/50-cloud-init.yaml` followed by the YAML to type into
; it; fired unattended, that types a network configuration into whatever nano
; has managed to draw in 300 ms.
;
; Nothing here can make that safe. What it can do is notice, before a single
; keystroke is sent, and say so.

EDITOR_COMMANDS := Map("nano", true, "pico", true, "vi", true, "vim", true
                            , "nvim", true, "emacs", true, "ed", true, "joe", true
                            , "mcedit", true, "visudo", true, "vipw", true, "vigr", true)

PAGER_COMMANDS := Map("less", true, "more", true, "most", true, "man", true
                           , "top", true, "htop", true, "watch", true)

; Commands that stop and wait for something typed that is not in the file — a
; password, a passphrase, a confirmation.
PROMPT_COMMANDS := Map("passwd", true, "adduser", true, "deluser", true
                            , "dpkg-reconfigure", true, "google-authenticator", true
                            , "ssh-keygen", true, "gpg", true, "gpg2", true
                            , "fdisk", true, "parted", true, "mysql_secure_installation", true)

; Commands that hand the terminal to a different shell. Everything after one of
; these runs somewhere else, which is the single most destructive way for the
; pacing to be wrong.
;
; Whether they do depends on their arguments, and the distinction is not
; academic: a runbook contains `ssh -V`, `ssh user@host` and
; `... | ssh user@host "mkdir -p ~/.ssh && cat >> authorized_keys"` within a few
; lines of each other, and only the middle one opens a session. So each entry
; says how many operands — arguments that are not switches and not a switch's
; value — mean "interactive", and which of its switches take a value.
;
; CONNECT_COMMANDS take a target and are interactive with exactly that: one
; operand and no remote command after it.
CONNECT_COMMANDS := Map(
    "ssh",    ["-i", "-p", "-l", "-o", "-F", "-c", "-m", "-b", "-D", "-L", "-R", "-W", "-e", "-J", "-Q", "-S"],
    "su",     ["-c", "-s", "-g", "--command", "--shell"],
    "telnet", [],
    "ftp",    [],
    "sftp",   ["-i", "-o", "-P", "-b", "-F", "-S"])

; INTERPRETER_COMMANDS drop into a REPL when given nothing to run.
INTERPRETER_COMMANDS := Map(
    "bash",    ["-c", "-o"],
    "sh",      ["-c", "-o"],
    "zsh",     ["-c", "-o"],
    "python",  ["-c", "-m", "-W", "-X"],
    "python3", ["-c", "-m", "-W", "-X"],
    "node",    ["-e", "-p", "--eval", "--print", "-r"],
    "irb",     [],
    "mysql",   ["-u", "-p", "-h", "-P", "-e", "-D", "-S"],
    "psql",    ["-U", "-h", "-p", "-d", "-c", "-f"],
    "sqlite3", ["-cmd", "-init"],
    "screen",  ["-S", "-s", "-c"],
    "tmux",    ["-S", "-f", "-L"])

; Switches that mean "run this and come back", so the command is not a session
; however many operands follow.
NON_INTERACTIVE_FLAGS := Map("-c", true, "-e", true, "-p", true, "-m", true
                           , "-V", true, "--version", true, "-h", true, "--help", true
                           , "--eval", true, "--print", true, "--command", true)

; CountOperands(args, valueFlags) -> how many arguments are neither a switch nor
; the value belonging to one.
CountOperands(args, valueFlags) {
    takesValue := Map()
    for flag in valueFlags
        takesValue[flag] := true

    count := 0
    i := 1
    while (i <= args.Length) {
        arg := args[i]
        if (SubStr(arg, 1, 1) = "-" && arg != "-" && arg != "--") {
            if (takesValue.Has(arg))
                i++
            i++
            continue
        }
        ; `su - user`: a bare dash is su's login switch, not an operand.
        if (arg = "-" || arg = "--") {
            i++
            continue
        }
        count++
        i++
    }
    return count
}

; Does this command open a session the rest of the file would be typed into?
OpensSession(name, args) {
    for arg in args {
        if (NON_INTERACTIVE_FLAGS.Has(arg))
            return false
    }
    if (CONNECT_COMMANDS.Has(name))
        return CountOperands(args, CONNECT_COMMANDS[name]) = 1
    if (INTERPRETER_COMMANDS.Has(name))
        return CountOperands(args, INTERPRETER_COMMANDS[name]) = 0
    return false
}

PACKAGE_COMMANDS := Map("apt", true, "apt-get", true, "dnf", true, "yum", true, "zypper", true)
PACKAGE_WRITE_VERBS := Map("install", true, "remove", true, "purge", true
                                , "upgrade", true, "full-upgrade", true, "dist-upgrade", true
                                , "autoremove", true)

; HazardReason(line) -> a short reason string, or "" when the line looks safe to
; fire and forget. One reason per line: the first thing found.
HazardReason(line) {
    ; A heredoc redirects everything after it into a file. The lines that follow
    ; are content, not commands, and the terminator is the only thing that ends
    ; it — so a Send All that stops partway leaves the shell collecting input
    ; with no prompt in sight.
    if (RegExMatch(line, "<<-?\s*[`"']?[A-Za-z_][A-Za-z0-9_]*[`"']?\s*$"))
        return "starts a heredoc - the following lines are file content, not commands"

    for segment in SplitShellSegments(line) {
        cmd := EffectiveCommand(segment)
        name := cmd.name
        if (name = "")
            continue

        if (EDITOR_COMMANDS.Has(name))
            return "opens " name ", which never returns on its own"
        if (PAGER_COMMANDS.Has(name))
            return "opens " name ", which waits for a key"
        if (name = "crontab" && HasFlag(cmd.args, ["-e"]))
            return "opens the crontab editor, which never returns on its own"
        if (name = "read")
            return "waits for input that is not in this file"
        if (PROMPT_COMMANDS.Has(name))
            return "prompts for a password or passphrase that is not in this file"
        if (OpensSession(name, cmd.args))
            return "hands the terminal to another shell - everything after it runs there"
        if (PACKAGE_COMMANDS.Has(name) && cmd.args.Length >= 1
            && PACKAGE_WRITE_VERBS.Has(StrLower(cmd.args[1]))
            && !HasFlag(cmd.args, ["-y", "--yes", "--assume-yes"]))
            return "asks for confirmation — no -y"
    }
    return ""
}

; ScanHazards(items, fromIndex) -> Array of { index, line, text, reason }
; covering the sendable items from fromIndex onwards.
ScanHazards(items, fromIndex) {
    found := []
    i := Max(fromIndex, 1)
    while (i <= items.Length) {
        item := items[i]
        if (item.kind = "command") {
            reason := HazardReason(item.text)
            if (reason != "")
                found.Push({ index: i, line: item.line, text: item.text, reason: reason })
        }
        i++
    }
    return found
}

; How many sendable items remain from fromIndex onwards.
CountPending(items, fromIndex) {
    count := 0
    i := Max(fromIndex, 1)
    while (i <= items.Length) {
        if (items[i].kind = "command")
            count++
        i++
    }
    return count
}

; The text of the Send All confirmation. Pure, so the wording is testable and
; the counts cannot drift from what is about to happen.
FormatSendAllPrompt(pending, hazards, abortKey := "Esc") {
    if (pending = 0)
        return ""

    noun := pending = 1 ? "command" : "commands"
    text := "Send All will type " pending " " noun " and press Enter after each,"
          . " waiting a fixed delay in between.`n`n"

    if (hazards.Length > 0) {
        plural := hazards.Length = 1 ? "line does" : "lines do"
        text .= hazards.Length " " plural " not fit that pattern:`n`n"
        Loop Min(hazards.Length, 5) {
            h := hazards[A_Index]
            text .= "  line " h.line ": " Ellipsis(Trim(h.text), 60) "`n"
                 .  "      " h.reason "`n"
        }
        if (hazards.Length > 5)
            text .= "  ... and " (hazards.Length - 5) " more.`n"
        text .= "`nSending past one of these types the rest of the list into "
             .  "whatever that command left on screen.`n`n"
    }

    text .= "Press " abortKey " while it runs to stop.`n`nContinue?"
    return text
}

Ellipsis(text, width) {
    if (StrLen(text) <= width)
        return text
    return SubStr(text, 1, width - 3) "..."
}


; ── Send All session ──────────────────────────────────────────────────────────

; A Send All run, as a cursor over a snapshot.
;
; The original read the shared CurrentIndex global on every iteration of its
; loop, and nothing else was locked out of writing to it. Hotkeys interrupt a
; running thread at every Sleep, and SendSlow sleeps between every character, so
; F8 during a run skipped a command and F6 resent one — but the bad one was F5:
; a reload sets CurrentIndex back to 1, and the loop's `while CurrentIndex <=
; Lines.Length` test then finds itself at the top of the file again. Pressing
; Reload during a Send All restarted it, for as long as the user kept pressing.
;
; A session owns its own cursor over its own copy of the list, so none of that
; reaches it, and Abort is the one documented way to make it stop.
class SendSession {
    __New(items, startIndex) {
        this.items := items
        this.cursor := Max(startIndex, 1)
        this.aborted := false
        this.sent := 0
        this.lastIndex := 0
    }

    ; The index of the next sendable item, or 0 when there is none left.
    Peek() {
        i := this.cursor
        while (i <= this.items.Length) {
            if (this.items[i].kind = "command")
                return i
            i++
        }
        return 0
    }

    HasNext() {
        return !this.aborted && this.Peek() != 0
    }

    ; The next item to type, or "" when the run is over or has been aborted.
    ; Advances the cursor past it.
    Take() {
        if (this.aborted)
            return ""
        index := this.Peek()
        if (!index)
            return ""
        this.cursor := index + 1
        this.lastIndex := index
        this.sent++
        return this.items[index]
    }

    Abort() {
        this.aborted := true
    }

    Remaining() {
        return CountPending(this.items, this.cursor)
    }
}


; ── Window ownership ──────────────────────────────────────────────────────────

; IsOwnWindow(hwnd, ownPid, getPid) -> true when hwnd belongs to this process.
;
; The foreground-window tracker records whatever window is active so that
; clicking a button in the GUI can re-activate the real target before typing.
; It compared against the GUI's handle alone, which was almost right until this
; script grew a dialog: a MsgBox is active, is not the GUI, and so was recorded
; as the target to type into — and by the time anything typed, it was gone.
; Comparing process ids covers the GUI, every dialog, and the file picker.
;
; getPid is injected so the rule can be tested without a window manager.
IsOwnWindow(hwnd, ownPid, getPid) {
    if (!hwnd)
        return true
    pid := getPid(hwnd)
    if (!pid)
        return true
    return pid = ownPid
}
