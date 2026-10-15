#Requires AutoHotkey v2.0
#SingleInstance Off
#Include ..\lib\core.ahk
#Include original.ahk

; run.ahk — the VM Command Stepper test suite.
;
;   D:\dev-tools\autohotkey\AutoHotkey64.exe tests\run.ahk
;
; Everything here calls lib/core.ahk directly. There is no black-box half and
; there deliberately is not one: the entry point registers F5-F8 as global
; hotkeys and its only output is keystrokes sent to the foreground window, so a
; test that ran it would type into whatever the developer had in front and take
; F5 away from their browser. What that costs is recorded in README.md under
; "What is not covered"; what it buys is a suite that is safe to run.
;
; Sections marked "regression" run the same assertion against tests/original.ahk
; — the pre-cleanup code, transcribed with its I/O lifted out — and require it
; to fail there. A regression test that passes against the unfixed code is
; testing nothing.

Passed := 0
Failed := 0
Skipped := 0

OnError(ReportUncaught)

Main()


; An uncaught error would otherwise raise a dialog nothing here can dismiss.
; Print it and fail loudly instead.
ReportUncaught(err, mode) {
    Say("")
    Say("UNCAUGHT " Type(err) ": " (err is Error ? err.Message : err))
    if (err is Error) {
        Say("  " err.File ":" err.Line)
        if (err.Extra != "")
            Say("  extra: " err.Extra)
    }
    ExitApp 3
}


Main() {
    global Passed, Failed, Skipped

    Say("VM Command Stepper test suite")
    Say("")

    TestTranscriptionFidelity()
    TestParseCommandFile()
    TestVisibleItems()
    TestNavigation()
    TestClampIndex()
    TestReloadPosition()
    TestEscaping()
    TestUntypable()
    TestShellSplitting()
    TestEffectiveCommand()
    TestHazardReason()
    TestScanHazards()
    TestSendAllPrompt()
    TestSendSession()
    TestOwnWindow()
    TestEntryPoint()
    TestExampleFile()

    Say("")
    Say(Passed " passed, " Failed " failed" (Skipped ? ", " Skipped " skipped" : ""))
    ExitApp Failed ? 1 : 0
}


; ── Harness ───────────────────────────────────────────────────────────────────

Say(text) {
    try FileAppend text "`n", "*"
}

Check(condition, description) {
    global Passed, Failed
    if (condition) {
        Passed++
        return true
    }
    Failed++
    Say("  FAIL  " description)
    return false
}

Same(actual, expected, description) {
    global Passed, Failed
    if (Equal(actual, expected)) {
        Passed++
        return true
    }
    Failed++
    Say("  FAIL  " description)
    Say("          expected: " Show(expected))
    Say("          actual:   " Show(actual))
    return false
}

Skip(description) {
    global Skipped
    Skipped++
    Say("  SKIP  " description)
}

; == on two Arrays compares identity, so every array assertion written with it
; passes or fails for the wrong reason. Compare contents instead; strings stay
; case-sensitive, which matters because half of what is compared here is a
; command name that was deliberately lower-cased.
Equal(a, b) {
    if (a is Array && b is Array) {
        if (a.Length != b.Length)
            return false
        Loop a.Length {
            if (!Equal(a[A_Index], b[A_Index]))
                return false
        }
        return true
    }
    if (a is Array || b is Array)
        return false
    return a == b
}

Show(value) {
    if (value is Array) {
        parts := ""
        for item in value
            parts .= (parts = "" ? "" : ", ") Show(item)
        return "[" parts "]"
    }
    ; `1 == true` in AHK, so testing for the boolean first would print every
    ; count of one as "true" and every count of zero as "false" — which is
    ; exactly the kind of misreported failure that wastes an hour.
    if (value is Integer || value is Float || value is String)
        return "<" value ">"
    if (value == true)
        return "true"
    if (value == false)
        return "false"
    return "<" value ">"
}

Section(name) {
    Say(name)
}

; Item text, as a plain array, for comparing a parse result against expectations.
Texts(items) {
    out := []
    for item in items
        out.Push(item.text)
    return out
}

Kinds(items) {
    out := []
    for item in items
        out.Push(item.kind)
    return out
}

Visible(text) {
    return VisibleItems(ParseCommandFile(text))
}

RepoDir() {
    return A_ScriptDir "\.."
}


; ── Transcription fidelity ────────────────────────────────────────────────────

; Every "regression" check below leans on tests/original.ahk actually being the
; original. Confirm that against git rather than trusting the copy.
TestTranscriptionFidelity() {
    Section("tests/original.ahk still matches " ORIGINAL_COMMIT)

    source := FetchOriginalSource(RepoDir(), ORIGINAL_COMMIT)
    if (source = "") {
        Skip("git or commit " ORIGINAL_COMMIT " unavailable — the transcription could not be verified")
        return
    }

    Check(InStr(source, "SendMode `"Event`""), "the fetched file is vm_command_stepper.ahk")
    for snippet in OriginalSnippets()
        Check(InStr(source, snippet), "original still contains: " Trim(snippet))

    ; The two things the transcription claims the original did NOT have.
    Check(!InStr(source, "MsgBox"), "the original had no confirmation dialog anywhere")
    Check(!InStr(source, "Abort"), "the original had no abort path")
}


; ── Parsing ───────────────────────────────────────────────────────────────────

TestParseCommandFile() {
    Section("ParseCommandFile")

    Same(ParseCommandFile("").Length, 0, "empty text yields no items")
    Same(ParseCommandFile("`n").Length, 1, "a lone newline is one blank line, not two")
    Same(ParseCommandFile("a`nb`n").Length, 2, "a trailing newline does not invent a final blank")
    Same(ParseCommandFile("a`nb`n`n").Length, 3, "a blank line before EOF is kept")
    Same(ParseCommandFile("a`r`nb`r`n").Length, 2, "CRLF is handled")

    items := ParseCommandFile("# header`n`nls -l`n   indented`n#trailing")
    Same(Kinds(items), ["comment", "blank", "command", "command", "comment"]
       , "each line is classified")
    Same(Texts(items), ["# header", "", "ls -l", "   indented", "#trailing"]
       , "text is kept exactly, including leading whitespace")

    lineNumbers := []
    for item in items
        lineNumbers.Push(item.line)
    Same(lineNumbers, [1, 2, 3, 4, 5], "line numbers are the file's, not the list's")

    Same(ParseCommandFile("   # spaced comment")[1].kind, "comment"
       , "a comment indented with spaces is still a comment")
    Same(ParseCommandFile("   `t  ")[1].kind, "blank"
       , "a line of only whitespace is blank")
    Same(ParseCommandFile("echo '#not a comment'")[1].kind, "command"
       , "a # that is not the first non-space character does not make a comment")

    ; Regression. The original discarded comments and blanks at load time, so
    ; the section headers that say which lines are typed into nano never
    ; reached the screen.
    runbook := "# --- paste inside nano ---`nnetwork:`n  version: 2"
    Same(Kinds(Visible(runbook)), ["comment", "command", "command"]
       , "regression: the nano header survives the load")
    Same(Original_LoadLines(runbook).Length, 2
       , "regression: the original dropped it, leaving two bare config lines")
    Check(Original_LoadLines(runbook)[1] == "network:"
       , "regression: and the list began with a YAML fragment with no context")

    ; The commands themselves must come through byte for byte, or an indented
    ; YAML line stops being valid YAML.
    Same(Texts(Visible("      addresses:`n        - 192.168.0.1/24"))
       , ["      addresses:", "        - 192.168.0.1/24"]
       , "indentation is preserved")
}

TestVisibleItems() {
    Section("VisibleItems")

    Same(Kinds(Visible("a`n`n# c`n`nb")), ["command", "comment", "command"]
       , "blanks are dropped, comments are kept")
    Same(Visible("").Length, 0, "an empty file has nothing to show")
    Same(Visible("`n`n`n").Length, 0, "a file of blank lines has nothing to show")
    Same(Visible("# only a comment").Length, 1, "a comment-only file still shows the comment")
}


; ── Navigation ────────────────────────────────────────────────────────────────

TestNavigation() {
    Section("NextSendable / PrevSendable")

    items := Visible("# a`nfirst`n# b`nsecond`n# c")
    ; visible: 1 comment, 2 command, 3 comment, 4 command, 5 comment

    Same(FirstSendable(items), 2, "the first sendable line is found past a comment")
    Same(NextSendable(items, 2), 4, "Next steps over the comment between two commands")
    Same(NextSendable(items, 4), 6, "Next past the last command is the past-the-end slot")
    Same(NextSendable(items, 6), 6, "Next stays at the past-the-end slot")
    Same(PrevSendable(items, 4), 2, "Back steps over the comment")
    Same(PrevSendable(items, 2), 0, "Back from the first command reports no earlier one")
    Same(PrevSendable(items, 6), 4, "Back from past-the-end lands on the last command")

    Check(IsSendable(items, 2), "a command row is sendable")
    Check(!IsSendable(items, 1), "a comment row is not sendable")
    Check(!IsSendable(items, 0), "index 0 is not sendable")
    Check(!IsSendable(items, 99), "an index past the end is not sendable")

    commentsOnly := Visible("# a`n# b")
    Same(FirstSendable(commentsOnly), 3, "a file of only comments has nothing to send")
    Same(PrevSendable(commentsOnly, 3), 0, "and nothing to go back to")

    empty := Visible("")
    Same(FirstSendable(empty), 1, "an empty list is immediately past the end")
}

TestClampIndex() {
    Section("ClampIndex")

    items := Visible("# a`nfirst`nsecond")   ; 1 comment, 2 command, 3 command

    Same(ClampIndex(items, 2), 2, "a valid command index is unchanged")
    Same(ClampIndex(items, 1), 2, "a comment index moves forward to the next command")
    Same(ClampIndex(items, 0), 2, "an index before the start becomes the first command")
    Same(ClampIndex(items, -5), 2, "a negative index becomes the first command")
    Same(ClampIndex(items, 4), 4, "the past-the-end slot is allowed")
    Same(ClampIndex(items, 99), 4, "an index past the end is pulled back to it")
    Same(ClampIndex(Visible(""), 7), 1, "an empty list clamps to 1")
}

TestReloadPosition() {
    Section("RestoreIndexAfterReload")

    before := Visible("one`ntwo`nthree`nfour")
    Same(before[3].text, "three", "fixture: position 3 is `"three`"")

    ; Nothing changed: stay put.
    Same(RestoreIndexAfterReload(Visible("one`ntwo`nthree`nfour"), "three", 3), 3
       , "an unchanged file leaves the position alone")

    ; A line inserted above: follow the text, not the number.
    Same(RestoreIndexAfterReload(Visible("zero`none`ntwo`nthree`nfour"), "three", 3), 4
       , "a line inserted above moves the position down with its command")

    ; A line removed above.
    Same(RestoreIndexAfterReload(Visible("one`nthree`nfour"), "three", 3), 2
       , "a line removed above moves the position up with its command")

    ; A comment inserted above still shifts the index, because comments are rows.
    Same(RestoreIndexAfterReload(Visible("# note`none`ntwo`nthree"), "three", 3), 4
       , "an inserted comment shifts the position too")

    ; The command is gone entirely: clamp rather than guess.
    Same(RestoreIndexAfterReload(Visible("one`ntwo`nfour"), "three", 3), 3
       , "a deleted command clamps to the same index")
    Same(RestoreIndexAfterReload(Visible("one"), "three", 3), 2
       , "a much shorter file clamps to past-the-end")

    ; Duplicates: prefer the nearest, because `exit` and `ls -l` repeat.
    dupes := Visible("exit`na`nb`nexit`nc`nd`nexit")
    Same(RestoreIndexAfterReload(dupes, "exit", 4), 4, "an exact match wins")
    Same(RestoreIndexAfterReload(dupes, "exit", 5), 4, "the nearest duplicate is chosen, not the first")
    Same(RestoreIndexAfterReload(dupes, "exit", 7), 7, "the nearest duplicate is chosen, not the first, going the other way")

    ; A comment is never a restore target even if its text matches.
    Same(RestoreIndexAfterReload(Visible("# exit`nexit"), "# exit", 1), 2
       , "a comment is not restored onto")

    Same(RestoreIndexAfterReload(before, "", 3), 3, "no previous text falls back to clamping")

    ; Regression. The original's ReloadCommands ended in CurrentIndex := 1,
    ; unconditionally, so F5 after editing the file mid-run sent you back to the
    ; top and the next Paste retyped commands that had already run.
    state := { Lines: Original_LoadLines("one`ntwo`nthree`nfour"), CurrentIndex: 3 }
    Original_Reload(state, "one`ntwo`nthree`nfour")
    Same(state.CurrentIndex, 1, "regression: the original reset to line 1 even when nothing had changed")
}


; ── Escaping ──────────────────────────────────────────────────────────────────

TestEscaping() {
    Section("EscapeForSend")

    ; The six characters Send treats as syntax. The first review checked this
    ; set by hand and found it complete; this is the check that keeps it so.
    Same(EscapeForSend("{"), "{{}", "an opening brace is escaped")
    Same(EscapeForSend("}"), "{}}", "a closing brace is escaped")
    Same(EscapeForSend("!"), "{!}", "! is escaped, or Send reads it as Alt")
    Same(EscapeForSend("^"), "{^}", "^ is escaped, or Send reads it as Ctrl")
    Same(EscapeForSend("+"), "{+}", "+ is escaped, or Send reads it as Shift")
    Same(EscapeForSend("#"), "{#}", "# is escaped, or Send reads it as Win")

    ; Characters that look special but are only special in a hotkey definition.
    for ch in ["~", "$", "*", "<", ">", "&", "%", "|", "(", ")", "[", "]", "`"", "'"
             , "\", "/", "-", "_", "=", ":", ";", ".", ",", "?", "@", " ", "`t"]
        Same(EscapeForSend(ch), ch, "`"" ch "`" is sent as itself")

    for ch in ["a", "Z", "0", "9"]
        Same(EscapeForSend(ch), ch, "`"" ch "`" is sent as itself")

    ; Every character the escaping must survive, in one real line.
    Same(EscapeLine("echo ${HOME} | tee -a x.log && exit 0")
       , "echo ${{}HOME{}} | tee -a x.log && exit 0"
       , "a line with braces is escaped in place and nothing else changes")
    Same(EscapeLine("rsync -avz a b 2>&1 # note")
       , "rsync -avz a b 2>&1 {#} note"
       , "a # inside a command line is escaped, not treated as a comment")
    Same(EscapeLine(""), "", "an empty line escapes to nothing")
    Same(EscapeLine("%it-admin ALL=(ALL) /usr/bin/apt")
       , "%it-admin ALL=(ALL) /usr/bin/apt"
       , "a sudoers group line needs no escaping")

    ; Parity with the original: this was the one thing the first review checked
    ; and found correct, so the extraction must not have changed it.
    Loop 95 {
        ch := Chr(A_Index + 31)
        Same(EscapeForSend(ch), Original_EscapeForSend(ch)
           , "escaping of Chr(" (A_Index + 31) ") is unchanged from the original")
    }
}


; ── Untypable characters ──────────────────────────────────────────────────────

TestUntypable() {
    Section("ScanUntypable")

    Check(IsTypableChar("a"), "a letter is typable")
    Check(IsTypableChar(" "), "a space is typable")
    Check(IsTypableChar("~"), "a tilde is typable")
    Check(IsTypableChar("`t"), "a tab is a real key and is typable")
    Check(!IsTypableChar(Chr(0x2014)), "an em dash is not typable")
    Check(!IsTypableChar(Chr(0x2019)), "a smart apostrophe is not typable")
    Check(!IsTypableChar(Chr(0xE9)), "an accented letter is not typable")
    Check(!IsTypableChar(Chr(0xFFFD)), "a replacement character is not typable")
    Check(!IsTypableChar(Chr(0x7F)), "DEL is not typable")
    Check(!IsTypableChar(Chr(0x0B)), "a vertical tab is not typable")

    clean := ScanUntypable(Visible("ls -l`necho 'hi there'`n# note"))
    Same(clean.Length, 0, "an ASCII file reports nothing")
    Same(FormatUntypableWarning(clean), "", "and produces no warning")

    ; A smart quote pasted in from a Word document, which is how this happens.
    dirty := ScanUntypable(Visible("ls -l`necho " Chr(0x201C) "hi" Chr(0x201D)))
    Same(dirty.Length, 2, "both curly quotes are reported")
    Same(dirty[1].line, 2, "the warning names the file line, not the list row")
    Same(dirty[1].code, 0x201C, "the offending character is identified")

    ; A comment is never typed, so an em dash in a section header is fine.
    Same(ScanUntypable(Visible("# --- paste " Chr(0x2014) " inside nano ---`nls")).Length, 0
       , "a non-ASCII character in a comment is not a problem")

    warning := FormatUntypableWarning(dirty)
    Check(InStr(warning, "1 line has"), "one bad line is described in the singular")
    Check(InStr(warning, "cannot type"), "the warning says what will go wrong")

    many := []
    Loop 7
        many.Push({ line: A_Index * 10, index: A_Index, text: "x", char: "x", code: 1 })
    long := FormatUntypableWarning(many)
    Check(InStr(long, "7 lines have"), "seven bad lines are described in the plural")
    Check(InStr(long, "and 2 more"), "the list of line numbers is capped at five")
    Check(!InStr(long, "60"), "and the sixth line number is not listed")

    ; Regression: the original had no validation of any kind, so a pasted em
    ; dash was discovered inside the VM.
    Same(Original_LoadLines("echo " Chr(0x2014))[1], "echo " Chr(0x2014)
       , "regression: the original loaded an untypable line with no complaint")
}


; ── Shell segmentation ────────────────────────────────────────────────────────

TestShellSplitting() {
    Section("SplitShellSegments")

    Same(SplitShellSegments("ls -l"), ["ls -l"], "a plain command is one segment")
    Same(SplitShellSegments("a && b"), ["a", "b"], "&& separates")
    Same(SplitShellSegments("a || b"), ["a", "b"], "|| separates")
    Same(SplitShellSegments("a | b"), ["a", "b"], "a pipe separates")
    Same(SplitShellSegments("a `; b"), ["a", "b"], "a semicolon separates")
    Same(SplitShellSegments("a & b"), ["a", "b"], "a background & separates")
    Same(SplitShellSegments("a && b || c | d `; e").Length, 5, "several separators in one line")
    Same(SplitShellSegments(""), [], "an empty line has no segments")
    Same(SplitShellSegments("   "), [], "a whitespace line has no segments")
    Same(SplitShellSegments("a &&"), ["a"], "a trailing separator does not invent an empty segment")

    ; The reason quote awareness is here rather than a regex. This exact line is
    ; in the runbook, and a naive split invents three commands from one.
    quoted := "sudo grep -E `"PermitRootLogin|PubkeyAuthentication|UsePAM`" /etc/ssh/sshd_config"
    Same(SplitShellSegments(quoted).Length, 1, "a pipe inside double quotes does not separate")

    Same(SplitShellSegments("echo 'a;b;c'").Length, 1, "a semicolon inside single quotes does not separate")
    Same(SplitShellSegments("echo `"it's fine`" | wc").Length, 2
       , "an apostrophe inside double quotes does not open a single-quoted run")
    Same(SplitShellSegments("echo 'say `"hi`"' `; ls").Length, 2
       , "a double quote inside single quotes does not open a double-quoted run")
    Same(SplitShellSegments("echo a\|b").Length, 1, "an escaped pipe does not separate")

    Section("SplitWords")

    Same(SplitWords("ls -l /tmp"), ["ls", "-l", "/tmp"], "words split on spaces")
    Same(SplitWords("  ls   -l  "), ["ls", "-l"], "runs of whitespace collapse")
    Same(SplitWords("ssh-keygen -N `"`""), ["ssh-keygen", "-N", ""]
       , "an empty quoted argument is a word, not nothing")
    Same(SplitWords("grep 'a b' c"), ["grep", "a b", "c"], "a quoted argument stays one word")
    Same(SplitWords("echo a\ b"), ["echo", "a b"], "an escaped space does not split")
    Same(SplitWords(""), [], "an empty segment has no words")
}

TestEffectiveCommand() {
    Section("EffectiveCommand")

    Same(EffectiveCommand("ls -l").name, "ls", "the first word is the command")
    Same(EffectiveCommand("sudo nano /etc/hosts").name, "nano", "sudo is stepped over")
    Same(EffectiveCommand("sudo -u bob nano x").name, "nano", "sudo's -u takes an argument")
    Same(EffectiveCommand("sudo -i nano x").name, "nano", "sudo's flags without arguments are stepped over")
    Same(EffectiveCommand("doas vi x").name, "vi", "doas is stepped over too")
    Same(EffectiveCommand("EDITOR=vim visudo").name, "visudo", "a VAR=value prefix is stepped over")
    Same(EffectiveCommand("DEBIAN_FRONTEND=noninteractive sudo apt install x").name, "apt"
       , "an assignment and a sudo together")
    Same(EffectiveCommand("/usr/bin/nano x").name, "nano", "a path is reduced to the program name")
    Same(EffectiveCommand("NANO").name, "nano", "the name is lower-cased")
    Same(EffectiveCommand("sudo").name, "", "sudo with nothing after it has no command")
    Same(EffectiveCommand("").name, "", "an empty segment has no command")

    Same(EffectiveCommand("apt install x -y").args, ["install", "x", "-y"], "arguments are returned")
    Same(EffectiveCommand("sudo apt install x").args, ["install", "x"], "arguments are returned past sudo")

    Check(HasFlag(["install", "-y"], ["-y", "--yes"]), "a flag present is found")
    Check(!HasFlag(["install"], ["-y", "--yes"]), "a flag absent is not found")
    Check(!HasFlag(["--yes-please"], ["--yes"]), "a flag match is exact, not a prefix")

    Same(EffectiveCommand("./configure").name, "configure", "a relative path is reduced to the program name")
    Same(EffectiveCommand("PATH=/x ./configure --prefix=/usr").name, "configure"
       , "an assignment in front of a relative path is stepped over")

    Section("CountOperands / OpensSession")

    Same(CountOperands(["user@host"], []), 1, "a bare target is one operand")
    Same(CountOperands(["-i", "key", "user@host"], ["-i"]), 1, "a switch and its value are not operands")
    Same(CountOperands(["-v", "user@host"], []), 1, "a valueless switch is not an operand")
    Same(CountOperands(["-", "user"], []), 1, "a bare dash is a switch, not an operand")
    Same(CountOperands([], []), 0, "no arguments, no operands")
    Same(CountOperands(["user@host", "ls", "-l"], []), 2, "a remote command adds an operand; its own switches do not")

    Check(OpensSession("ssh", ["user@host"]), "ssh with only a host opens a session")
    Check(!OpensSession("ssh", ["-V"]), "ssh -V does not")
    Check(!OpensSession("ssh", ["user@host", "mkdir -p ~/.ssh"]), "ssh with a remote command does not")
    Check(!OpensSession("ssh", ["-i", "/home/u/.ssh/backup_key", "u@h", "ls"])
        , "ssh with a key and a remote command does not")
    Check(OpensSession("ssh", ["-i", "/home/u/.ssh/backup_key", "u@h"])
        , "ssh with a key and no remote command does")
    Check(OpensSession("su", ["-", "clinician"]), "su - user opens a session")
    Check(!OpensSession("su", ["-c", "id", "clinician"]), "su -c does not")
    Check(OpensSession("python3", []), "a bare interpreter opens a session")
    Check(!OpensSession("python3", ["script.py"]), "an interpreter with a script does not")
    Check(!OpensSession("python3", ["-c", "print(1)"]), "an interpreter with -c does not")
    Check(!OpensSession("ls", []), "an ordinary command never opens a session")
}


; ── Send All hazards ──────────────────────────────────────────────────────────

TestHazardReason() {
    Section("HazardReason")

    ; Safe: returns promptly, prompts for nothing.
    for line in ["ls -l"
               , "ip a | grep `"inet `""
               , "sudo netplan apply"
               , "sudo systemctl restart ssh"
               , "sha256sum patient_data.txt | tee baseline_hash.txt"
               , "mkdir -p /home/u/x && cd /home/u/x"
               , "sudo apt install lynis -y"
               , "sudo apt update"
               , "getent group it-admin"
               , "network:"
               , "  version: 2"
               , "PermitRootLogin no"
               , "0 2 * * * rsync -avz a b >> /home/u/backup.log 2>&1"
               , "for i in 1 2 3; do cp a record_$i.gpg; done"]
        Same(HazardReason(line), "", "safe to fire unattended: " line)

    ; The scenario the first review named: netplan into nano on a 300 ms timer.
    Check(InStr(HazardReason("sudo nano /etc/netplan/50-cloud-init.yaml"), "nano")
        , "nano is flagged")
    Check(InStr(HazardReason("sudo visudo -f /etc/sudoers.d/roles"), "visudo")
        , "visudo is flagged")
    Check(InStr(HazardReason("vim /etc/hosts"), "vim"), "vim is flagged")
    Check(InStr(HazardReason("crontab -e"), "crontab"), "crontab -e is flagged")
    Same(HazardReason("crontab -l"), "", "crontab -l is not")

    Check(InStr(HazardReason("less /var/log/syslog"), "waits"), "a pager is flagged")
    Check(InStr(HazardReason("sudo lynis audit system | less"), "waits")
        , "a pager on the right of a pipe is flagged")

    Check(InStr(HazardReason("sudo passwd prashant7-admin"), "password")
        , "passwd is flagged")
    Check(InStr(HazardReason("ssh-keygen -t ed25519 -C `"a@b`""), "password")
        , "ssh-keygen is flagged")
    Check(InStr(HazardReason("gpg --symmetric --cipher-algo AES256 x.txt"), "password")
        , "gpg is flagged")
    Check(InStr(HazardReason("sudo dpkg-reconfigure --priority=low unattended-upgrades"), "password")
        , "dpkg-reconfigure is flagged")
    Check(InStr(HazardReason("google-authenticator"), "password")
        , "google-authenticator is flagged")

    Check(InStr(HazardReason("ssh user@192.168.0.1"), "another shell")
        , "ssh is flagged — everything after it runs on the other machine")
    Check(InStr(HazardReason("su - clinician"), "another shell"), "su is flagged")
    Check(InStr(HazardReason("python3"), "another shell"), "a bare interpreter is flagged")
    Same(HazardReason("python3 script.py"), "", "an interpreter with a script is not flagged")

    ; apt without -y stops at "Do you want to continue? [Y/n]".
    Check(InStr(HazardReason("sudo apt install fail2ban"), "-y"), "apt install without -y is flagged")
    Same(HazardReason("sudo apt install fail2ban -y"), "", "apt install with -y is not")
    Same(HazardReason("sudo apt install fail2ban --yes"), "", "--yes counts too")
    Same(HazardReason("apt list --upgradable"), "", "a read-only apt subcommand is not flagged")

    ; Heredocs: the following lines are file content, and the shell will not
    ; return to a prompt until the terminator arrives.
    Check(InStr(HazardReason("cat > patient_data.txt << 'EOF'"), "heredoc"), "a quoted heredoc is flagged")
    Check(InStr(HazardReason("cat > x << EOF"), "heredoc"), "a bare heredoc is flagged")
    Check(InStr(HazardReason("cat <<-END"), "heredoc"), "a dash heredoc is flagged")
    Same(HazardReason("echo a << b.txt > c"), "", "a << not at end of line is not a heredoc start")
    Same(HazardReason("a=$((1 << 3))"), "", "a left shift is not a heredoc")

    ; The reason must be specific enough to act on.
    Check(StrLen(HazardReason("sudo nano x")) > 10, "the reason is a sentence, not a flag")
}

TestScanHazards() {
    Section("ScanHazards / CountPending")

    items := Visible("ls -l`n# note`nsudo nano /etc/hosts`nnetwork:`nexit")
    ; visible: 1 ls, 2 comment, 3 nano, 4 network:, 5 exit

    Same(CountPending(items, 1), 4, "comments are not counted as pending")
    Same(CountPending(items, 3), 3, "counting from part-way down")
    Same(CountPending(items, 6), 0, "nothing is pending past the end")
    Same(CountPending(items, 0), 4, "an index before the start counts everything")

    all := ScanHazards(items, 1)
    Same(all.Length, 1, "one hazard in the list")
    Same(all[1].index, 3, "the hazard's list position is reported")
    Same(all[1].line, 3, "and its file line")

    Same(ScanHazards(items, 4).Length, 0, "scanning from past the hazard finds nothing")
    Same(ScanHazards(Visible("# sudo nano x"), 1).Length, 0
       , "a hazardous-looking comment is not a hazard — it is never typed")
}

TestSendAllPrompt() {
    Section("FormatSendAllPrompt")

    Same(FormatSendAllPrompt(0, []), "", "nothing pending means no prompt")

    plain := FormatSendAllPrompt(12, [])
    Check(InStr(plain, "12 commands"), "the prompt names the number of lines")
    Check(InStr(plain, "Esc"), "the prompt names the abort key")
    Check(InStr(plain, "Continue?"), "the prompt asks")

    one := FormatSendAllPrompt(1, [])
    Check(InStr(one, "1 command and"), "one line is described in the singular")

    hazards := [{ index: 3, line: 7, text: "sudo nano /etc/netplan/50-cloud-init.yaml"
                , reason: "opens nano, which never returns on its own" }]
    warned := FormatSendAllPrompt(12, hazards)
    Check(InStr(warned, "line 7"), "the prompt names the file line of the hazard")
    Check(InStr(warned, "nano"), "and the command")
    Check(InStr(warned, "1 line does"), "one hazard is described in the singular")

    many := []
    Loop 9
        many.Push({ index: A_Index, line: A_Index, text: "sudo nano x"
                  , reason: "opens nano, which never returns on its own" })
    capped := FormatSendAllPrompt(30, many)
    Check(InStr(capped, "9 lines do"), "nine hazards are described in the plural")
    Check(InStr(capped, "and 4 more"), "the listing is capped at five")

    long := [{ index: 1, line: 1, reason: "r"
             , text: "openssl req -x509 -newkey rsa:4096 -nodes -keyout medconnect.key -out medconnect.crt -days 365" }]
    Check(InStr(FormatSendAllPrompt(1, long), "..."), "a long line is elided rather than wrapping off the dialog")

    Same(Ellipsis("short", 60), "short", "a short string is not elided")
    Same(Ellipsis("abcdefghij", 6), "abc...", "a long string is elided to the requested width")
    Same(StrLen(Ellipsis("abcdefghij", 6)), 6, "and the width is the width")

    ; Regression: the original went straight from Ctrl+F5 to typing.
    source := FetchOriginalSource(RepoDir(), ORIGINAL_COMMIT)
    if (source = "")
        Skip("regression: could not fetch the original to confirm it had no prompt")
    else
        Check(InStr(source, "^F5::SendAll()") && !InStr(source, "MsgBox")
            , "regression: Ctrl+F5 typed the whole list with nothing asked")
}


; ── The Send All session ──────────────────────────────────────────────────────

TestSendSession() {
    Section("SendSession")

    items := Visible("one`n# note`ntwo`nthree")

    s := SendSession(items, 1)
    Same(s.Remaining(), 3, "three commands to send")
    Check(s.HasNext(), "there is a first one")
    Same(s.Take().text, "one", "the first command")
    Same(s.Take().text, "two", "the comment is stepped over")
    Same(s.Take().text, "three", "the last command")
    Check(!s.HasNext(), "and then there are none")
    Same(s.Take(), "", "Take past the end returns nothing")
    Same(s.sent, 3, "three were sent")

    mid := SendSession(items, 3)
    Same(mid.Remaining(), 2, "a session started part-way down sends the rest")
    Same(mid.Take().text, "two", "starting on a command sends that command")

    onComment := SendSession(items, 2)
    Same(onComment.Take().text, "two", "a session started on a comment starts at the next command")

    empty := SendSession(Visible("# just a note"), 1)
    Check(!empty.HasNext(), "a list with nothing sendable has nothing to send")
    Same(empty.Take(), "", "and Take returns nothing")

    ; Abort.
    a := SendSession(items, 1)
    a.Take()
    a.Abort()
    Check(!a.HasNext(), "an aborted session has no next")
    Same(a.Take(), "", "and Take returns nothing")
    Same(a.sent, 1, "only what was already sent counts as sent")

    ; The session's position is reportable, so the GUI can follow it.
    p := SendSession(items, 1)
    p.Take()
    Same(p.lastIndex, 1, "the session reports where it is")
    p.Take()
    Same(p.lastIndex, 3, "and keeps reporting it")

    ; Regression, and the important one. The original's loop read the shared
    ; CurrentIndex global on every iteration, and its per-character Sleep let a
    ; hotkey thread interrupt and write to it. Pressing Reload during a Send All
    ; set it back to 1 and the loop carried on from the top.
    Section("SendSession: a reload during a run")

    text := "one`ntwo`nthree`nfour`nfive"

    ; Three presses of F5 while it runs.
    state := { Lines: Original_LoadLines(text), CurrentIndex: 1 }
    reloads := 0
    yield := (st, where) => (
        (where = "delay" && ++reloads <= 3) ? Original_Reload(st, text) : ""
    )
    result := Original_SendAll(state, yield)
    Same(result.typed, ["one", "one", "one", "one", "two", "three", "four", "five"]
       , "regression: three Reloads during the original's Send All retyped line 1 "
       . "three extra times before the run got going")

    ; Reload held down, or pressed on every pass. The loop never terminates:
    ; this only stops because the transcription has a cap the original lacks.
    state2 := { Lines: Original_LoadLines(text), CurrentIndex: 1 }
    result2 := Original_SendAll(state2, (st, where) => where = "delay" ? Original_Reload(st, text) : "")
    Check(result2.runaway
        , "regression: reloading on every pass made the original's Send All never "
        . "terminate - it typed past a 200-line cap on a five-line file")

    ; The session is immune, because it iterates its own snapshot.
    live := Visible(text)
    s2 := SendSession(live, 1)
    typed := []
    while (s2.HasNext()) {
        typed.Push(s2.Take().text)
        ; Everything a reload does: replace the shared list and reset the
        ; shared position. The session must not notice.
        live := Visible(text)
        if (typed.Length > 50)
            break
    }
    Same(typed.Length, 5, "a reload during a run does not restart the session")
    Same(typed, ["one", "two", "three", "four", "five"], "and every line is sent once, in order")

    Section("SendSession: a skip during a run")

    state2 := { Lines: Original_LoadLines(text), CurrentIndex: 1 }
    skipped := false
    yield2 := (st, where) => (
        (where = "sending" && !skipped && (skipped := true)) ? st.CurrentIndex++ : ""
    )
    result2 := Original_SendAll(state2, yield2)
    Same(result2.typed, ["one", "three", "four", "five"]
       , "regression: pressing Next during the original's Send All silently skipped a command")

    s3 := SendSession(Visible(text), 1)
    typed3 := []
    while (s3.HasNext())
        typed3.Push(s3.Take().text)
    Same(typed3.Length, 5, "the session sends all five regardless of what else moves")

    Section("SendSession: abort is the only way to stop")

    state3 := { Lines: Original_LoadLines(text), CurrentIndex: 1 }
    result3 := Original_SendAll(state3, (st, where) => "")
    Same(result3.typed.Length, 5
       , "regression: the original had no abort — it typed every remaining line")

    s4 := SendSession(Visible(text), 1)
    typed4 := []
    while (s4.HasNext()) {
        typed4.Push(s4.Take().text)
        if (typed4.Length = 2)
            s4.Abort()
    }
    Same(typed4, ["one", "two"], "aborting after two lines stops after two lines")
}


; ── Window ownership ──────────────────────────────────────────────────────────

TestOwnWindow() {
    Section("IsOwnWindow")

    OWN := 4242
    pids := Map(100, OWN, 200, 9999, 300, OWN, 400, 0)
    lookup := (hwnd) => pids.Has(hwnd) ? pids[hwnd] : 0

    Check(IsOwnWindow(100, OWN, lookup), "the GUI belongs to this process")
    Check(IsOwnWindow(300, OWN, lookup), "so does a dialog this script raised")
    Check(!IsOwnWindow(200, OWN, lookup), "another process's window does not")
    Check(IsOwnWindow(0, OWN, lookup), "no window is treated as our own, so it is not recorded")
    Check(IsOwnWindow(400, OWN, lookup), "a window whose pid cannot be read is not recorded either")

    ; Regression. The original compared against the GUI handle alone, so any
    ; other window belonging to this script — a MsgBox, the file picker — was
    ; recorded as the target to type into. It did not bite until the script grew
    ; a confirmation dialog, at which point dismissing the dialog left the
    ; remembered target pointing at a window that no longer existed.
    GUI_HWND := 100
    Check(!Original_TracksAsForeign(GUI_HWND, GUI_HWND)
        , "regression: the original did skip the GUI itself")
    Check(Original_TracksAsForeign(300, GUI_HWND)
        , "regression: but it recorded this script's own dialog as the target to type into")
    Check(!IsOwnWindow(200, OWN, lookup) && !Original_TracksAsForeign(GUI_HWND, GUI_HWND)
        , "regression: both agree about a genuinely foreign window")
}


; ── The entry point ───────────────────────────────────────────────────────────

; vm_command_stepper.ahk cannot be run from here, so it is checked two other
; ways: AutoHotkey's own /validate parses it without executing it, and the
; source is read to confirm that the decisions really did move out of it and
; that the fixes which have no other witness are present. That second half is
; crude, and it is the honest amount of coverage available for a file whose
; only output is keystrokes.
TestEntryPoint() {
    Section("vm_command_stepper.ahk")

    path := RepoDir() "\vm_command_stepper.ahk"
    if (!FileExist(path)) {
        Skip("vm_command_stepper.ahk is missing")
        return
    }

    ; /validate parses and reports syntax errors on stderr without running the
    ; script. Its exit code is 2 either way, so the output is the signal.
    out := A_Temp "\vmcs-validate-" A_TickCount ".txt"
    RunWait(A_ComSpec ' /c ""' A_AhkPath '" /validate /ErrorStdOut=UTF-8 "' path '"" > "' out '" 2>&1'
          , RepoDir(), "Hide")
    report := ""
    try report := FileRead(out, "UTF-8")
    try FileDelete(out)
    Same(Trim(report), "", "the entry point parses without error")

    source := FileRead(path, "UTF-8")

    Check(InStr(source, "#Include lib\core.ahk"), "the entry point includes the core")

    ; The decisions are gone from the plumbing. If one of these comes back it
    ; means a second copy has appeared, which is how the two implementations
    ; drift apart and how the tests stop covering what runs.
    Check(!InStr(source, "Lines.Push(line)"), "the parse loop is not in the entry point")
    Check(!InStr(source, "EscapeForSend(ch) {"), "the escaping table is not in the entry point")
    Check(!InStr(source, "case `"{`": return"), "nor a copy of its cases")

    ; Fixes with no other witness here.
    Check(InStr(source, "MsgBox(prompt"), "Send All asks before it types")
    Check(InStr(source, "FormatSendAllPrompt("), "and the question is the one this suite checks")
    Check(InStr(source, "Hotkey(ABORT_KEY, AbortSend, `"On S`"")
        , "the abort key is registered for the run, and is exempt from Suspend")
    Check(InStr(source, "Hotkey(ABORT_KEY, AbortSend, `"Off`"")
        , "and released afterwards, so Esc is not taken from the rest of Windows")
    Check(InStr(source, "#SuspendExempt"), "the suspend toggle can un-suspend itself")
    Check(InStr(source, "Pause::ToggleArmed()"), "there is a way to give F5-F8 back")
    Check(InStr(source, "SendSession("), "Send All runs over a snapshot")
    Check(InStr(source, "RestoreIndexAfterReload("), "reload keeps its place")
    Check(InStr(source, "FileRead(CommandsFile, `"UTF-8`")"), "the file is read as UTF-8")
    Check(InStr(source, "catch as err"), "and a read failure is handled")
    Check(InStr(source, "IsOwnWindow("), "the foreign-window tracker compares process ids")
    Check(InStr(source, "RefuseWhileBusy("), "the pointer cannot move during a send")
    Check(InStr(source, "ScanUntypable("), "the file is checked for characters that cannot be typed")

    ; Things the original did that must not have survived.
    Check(!InStr(source, "hwnd != MyGui.Hwnd")
        , "regression: the tracker no longer compares against the GUI handle alone")
    Check(!RegExMatch(source, "m)^\s+CurrentIndex := 1\s*$")
        , "regression: LoadCommands no longer resets the position to 1")
    Check(!InStr(source, "raw := FileRead(CommandsFile)`r`n") && !InStr(source, "raw := FileRead(CommandsFile)`n")
        , "regression: FileRead is no longer called bare")

    ; The 30-line usage banner that duplicated the README is gone; what is left
    ; is a summary and a pointer.
    Check(!InStr(source, "Press F6  -> steps back one line"), "the duplicated usage banner is gone")
    Check(InStr(source, "See README.md"), "and points at the README instead")
}


; ── The shipped example ───────────────────────────────────────────────────────

; commands.example.txt is what a new user sees first, and it is also the only
; corpus here that was not written to pass a test.
TestExampleFile() {
    Section("commands.example.txt")

    path := RepoDir() "\commands.example.txt"
    if (!FileExist(path)) {
        Skip("commands.example.txt is missing")
        return
    }

    text := FileRead(path, "UTF-8")
    items := ParseCommandFile(text)
    visible := VisibleItems(items)

    Check(items.Length > 0, "the example parses to something")
    Check(CountPending(visible, 1) > 0, "and has commands in it")

    Same(ScanUntypable(visible).Length, 0
       , "the example contains nothing this script cannot type")

    Check(ScanHazards(visible, 1).Length > 0
        , "the example includes at least one line Send All should warn about, "
        . "because an example that never trips the warning does not document it")

    ; Every command in the example must survive escaping unchanged in length
    ; terms — i.e. escaping is doing something only where it should.
    for item in visible {
        if (item.kind != "command")
            continue
        escaped := EscapeLine(item.text)
        Check(StrLen(escaped) >= StrLen(item.text)
            , "escaping never shortens a line: " item.text)
    }
}
