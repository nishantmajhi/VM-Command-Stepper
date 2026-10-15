# Code Review — VM Command Stepper

First reviewed 2026-09-04 against git HEAD `74238bf`.
**Remediated 2026-09-18** on branch `cleanup/2026-09-18`. Not pushed.

This file started as a to-do list. It is now a record: what was wrong, what was
fixed, what was left alone and why, and what still needs a human.

## Corrections to the first review

The first review was accurate about everything it raised — both P1s were real
and reproduced against the original code, and its judgement that the remaining
work was "safety rails around a tool whose entire job is to inject keystrokes
into a root shell" was the right frame. Two things need adding rather than
correcting.

**It called `EscapeForSend` correct, and it is.** `{ } ! ^ + #` is the complete
set of characters `Send` treats as syntax; `~ $ * < > &` are special in a hotkey
*definition*, not in a Send string. That was checked by hand in the first pass
and is now checked by 120 assertions, including a character-by-character parity
check against the original across all of printable ASCII. This is the one part
of the script that did not need changing, and the suite exists partly so it
stays that way.

**It missed the worst bug in the file**, which is not on its list at all. See
"Reload during a Send All" below. In fairness it is invisible by reading:
nothing in `SendAll()` looks wrong until you notice that AHK lets a hotkey
thread interrupt at every `Sleep`, and that `SendSlow` sleeps between every
character.

## What was wrong, and what was done

### P1 — Send All had no confirmation and no way to stop

`SendAll()` typed each remaining line, pressed Enter, waited 300 ms and moved
on. `BeginSend()` blocked re-entry, which also meant there was no way to stop it
short of killing the script. With the committed `commands.txt` that sequence
typed a netplan file into a nano session on a 300 ms timer.

Fixed three ways.

*It asks first.* `FormatSendAllPrompt()` builds the text and is pure, so the
counts cannot drift from what is about to happen. It names how many commands
will be typed.

*It says what will go wrong.* `ScanHazards()` reads every remaining line and
reports the ones the fixed pacing cannot handle, with a reason each: editors and
pagers, password and passphrase prompts, commands that hand the terminal to
another shell, heredoc openers, and `apt install` without `-y`. Run against the
real `commands.txt`, it flags exactly the lines that would have caused the
damage the first review described.

The detection is argument-aware, which is not decoration. That file contains
`ssh -V`, `ssh prashant7@192.168.18.196` and
`... | ssh prashant7@... "mkdir -p ~/.ssh && cat >> authorized_keys"` within a
few lines of each other, and only the middle one opens a session. `OpensSession`
counts operands after stripping each command's own value-taking switches.

Run against the real `commands.txt`: **150 commands, 27 flagged.** Seven `nano`
and `visudo` openings, seven `ssh`/`su` sessions, two heredocs, `crontab -e`,
two `sudo passwd`, `google-authenticator`, `dpkg-reconfigure`, two `gpg`
passphrase prompts and two `ssh-keygen`. The `apt install ... -y` lines are
correctly *not* flagged, and neither is `apt update` or `apt list --upgradable`.

One deliberate over-flag: `ssh-keygen -t ed25519 -f .../backup_key -N ""` at
line 151 supplies both the path and an empty passphrase, so it does not prompt —
on a first run. On a second it asks `Overwrite (y/n)?`, which is exactly the
failure mode the warning exists for, so it is left flagged.

*`Esc` stops it.* Registered when the run starts and released when it ends, so
Esc is not taken from the rest of Windows the other 99% of the time, and marked
suspend-exempt so pressing Pause mid-run cannot remove the one key that stops
it. Aborting mid-line sends no Enter — a half-typed line is not a run command —
and the status bar says which line was left half-typed.

### P1 — Reload during a Send All restarted it. Not on the first review's list.

`SendAll()`'s loop read the shared `CurrentIndex` global on every iteration, and
nothing was locked out of writing to it. AHK runs a hotkey press as a thread
that interrupts the current one at its next `Sleep`, and `SendSlow` sleeps
between every character — so F5, F6 and F8 all landed inside a running Send All.

- **F5 was the bad one.** `ReloadCommands()` → `LoadCommands()` ended with
  `CurrentIndex := 1`. The loop's `while CurrentIndex <= Lines.Length` test then
  found itself at the top of the file. Press Reload during a Send All and it
  starts over; hold it, and it never terminates. The regression test drives the
  transcribed original and needs a 200-line cap to stop it running away on a
  five-line list.
- F8 silently skipped a command. F6 resent one.

Fixed by making a Send All iterate its own snapshot. `SendSession` is a cursor
over a copy of the list with an explicit `Abort()`, so nothing outside can move
it. Separately, `RefuseWhileBusy()` now declines Back, Next, Reload and row
clicks while a send is running, and says why.

### P1 — F5–F8 were taken from the whole system with no way to give them back

They were unconditional hotkeys, so for as long as the script ran, F5 no longer
refreshed a browser and F6–F8 were dead everywhere.

The first review offered two fixes: scope them with `#HotIf`, or add a suspend
toggle with a visible indicator. **The suspend toggle was chosen.** `#HotIf`
scoping needs a rule for which window counts, and every rule available here is
wrong: scoping to `ahk_exe VirtualBoxVM.exe` breaks the script for anyone using
it with anything else, and scoping to the remembered target window is worse,
because the tracker remembers whatever you last alt-tabbed to. A toggle changes
nothing for anyone who does not press it.

`Pause` toggles, is marked `#SuspendExempt` so it can turn the others back on,
and sets the tray tooltip so the armed state is visible without the window.

### P2 — Comment lines were discarded at load time

`LoadCommands()` skipped `#` and blank lines, so the section headers in
`commands.txt` — "Section 1: Set up your lab environment", "paste inside nano" —
never reached the GUI. That is exactly the context that says whether the next
line is a command or a line of a file you are typing into an editor.

Comments are now rows. They are never sendable, Paste and Next step over them,
and the `#` column is left blank on a comment so it reads as context rather than
as something waiting to be typed — the column now numbers the commands rather
than the rows.

Demonstrated end to end rather than only asserted. The same seven-line file
loaded into the original shows four rows beginning `ls -l`, `network:`,
`  version: 2` with nothing to say the last two belong inside nano. Loaded into
the fixed script it shows six, with the `# --- paste inside nano ---` header in
place and the selection starting on the first actual command.

Blank lines are still dropped: a runbook is mostly blank-separated sections and
fifty empty rows would bury the commands. The cost — a blank line inside a
heredoc is not reproduced — is documented in the README rather than fixed,
because fixing it properly means a directive syntax, which is a feature and not
a bug fix.

### P2 — `commands.txt` was committed, and is on a GitHub remote

Untracked, gitignored, left on disk, and `commands.example.txt` ships in its
place. **It is still in the history and still in `origin/main`.** The history
was not rewritten, per the archive's standing constraint.

Full detail in `SECRETS-TODO.md`, including what is in it and the three options
for getting it off the remote. Short version: no credentials, but a person's
full name, a login, a home LAN layout, an identifiable university assessment and
a synthetic patient record that does not read as synthetic at a glance.

### P2 — No validation for characters that cannot be typed

`Send` in Event mode goes through the active keyboard layout, so an em dash or a
smart quote pasted in from a document arrives wrong or not at all.
`ScanUntypable()` now checks at load time and names the file lines in the status
bar. Comments are not scanned — they are never typed.

It doubles as an encoding check: the file is now read as UTF-8 rather than the
system codepage, and bytes that are not valid UTF-8 decode to U+FFFD, which is
itself untypable and so gets reported.

### P3 — Reload reset the position to line 1

`LoadCommands()` ended `CurrentIndex := 1` unconditionally, so pressing F5 after
editing the file half way through a run sent you back to the top, and the next
Paste retyped commands that had already run.

Preserving the numeric index instead would be just as wrong, because editing the
file is what moves the numbers. `RestoreIndexAfterReload()` matches on the text
of the current command and prefers the occurrence nearest where it used to be —
`exit` and `ls -l` appear many times in a real runbook — and only clamps when
that command has gone from the file entirely.

### P3 — `FileRead` had no error handling

An unreadable or locked file threw out of `ReloadCommands()` and killed the
script mid-run. It is now in a `try` with a message naming the file.

### P3 — The usage banner duplicated the README; no LICENSE

The 30-line banner is now four lines and a pointer at the README. `LICENSE` is
MIT, matching what the README claimed; change it if that was not the intent.

## Bugs found during the pass that were not on the list

**`TrackForeignWindow` recorded this script's own dialogs as the target to type
into.** It compared the active window against the GUI's handle alone, so any
*other* window belonging to this script — a MsgBox, the file picker — was
remembered as the VM. It did not bite before, because the script had no dialogs.
Adding the Send All confirmation would have made it live: dismiss the dialog and
the remembered target points at a window that no longer exists. It now compares
process ids, which covers the GUI, every dialog and the picker.

This is the one finding in this pass that was created by the fix for another,
and it is worth remembering as a shape: a latent bug that only a
correctly-implemented feature can expose.

**`FocusTarget` typed into the GUI itself.** If the GUI was focused and nothing
had been focused before it, the original did nothing and then typed the command
into its own window. It now declines and says to click into the VM first.

**`ParseCommandFile` and the trailing newline.** Not a bug in the original —
it dropped blank lines, so it could not see one — but a trap in the rewrite:
`StrSplit("")` yields nothing at all, so a file of a single newline became no
lines rather than the one empty line it is. Caught by a test written before the
code.

## Deliberately not done

**No directive syntax for pacing.** The first review's second P1 — "fixed 300 ms
pacing is the wrong model for anything interactive" — is correct, and the
suggestion was a directive prefix marking lines that need a manual continue.
That is a feature, not a fix. What was done instead is to make Send All refuse
to be fired blind: it names the lines the pacing cannot handle before it types
anything. If you find yourself wanting the directives, the place to put them is
`ParseCommandFile`, which already returns a `kind` per line and would need a
fourth value.

**The auto-indent problem was documented, not fixed.** Indentation-sensitive
text typed into an editor with auto-indent on gets extra indentation, and
nothing this script can do changes that. The README says to use a heredoc or
`printf` instead, and `commands.example.txt` demonstrates the heredoc.

**No `#HotIf` scoping.** Reasoning above, under the F5–F8 item.

**The GUI layout, the button labels and the resize behaviour were not touched.**
The archive's standing constraint is business logic only. The three changes with
any visual consequence are all required by the first review's own action
checklist: comment rows appear in the list, the `#` column numbers commands
rather than rows, and Send All raises a confirmation dialog. The status-bar text
changed along with them.

## Tests

`tests/run.ahk`, run with the portable AutoHotkey v2 on `D:`:

```sh
D:\dev-tools\autohotkey\AutoHotkey64.exe tests\run.ahk
```

**425 checks, 0 failed, 0 skipped.** No framework, no dependencies. It sends no
keystrokes, registers no hotkeys, and writes only under `%TEMP%`, so it is safe
to run while you are working — which the thing it tests is not.

The regression checks work by asserting what the original did *wrong*. The
original cannot be run from a test: it registers F5–F8 globally at load, and its
only output is keystrokes aimed at whatever window is in front, so a suite that
ran it would type into the developer's terminal and take F5 off them.
`tests/original.ahk` therefore holds the four functions whose decisions changed,
transcribed with their I/O lifted out — and the suite fetches
`74238bf:vm_command_stepper.ahk` from git and asserts that eleven exact lines
from it are still present, so a transcription that has silently drifted fails
loudly instead of proving nothing.

The entry point is covered two thinner ways: AutoHotkey's own `/validate` parses
it without running it, and its source is read to confirm the decisions really
did move into `lib/core.ahk` and that the fixes with no other witness are there.

## Notes for a future session

**Read this before writing any AutoHotkey here.** A semicolon preceded by a
space is stripped as a comment **even inside a double-quoted string literal**.
`x := "a ; b"` is a syntax error — "Missing ""'" — and the fix is `` "a `; b" ``.
This cost twenty minutes and the error message points at the wrong thing.

**`/validate` returns exit code 2 whether or not the script is valid.** The
signal is whether it wrote anything to stderr, so capture the output and test
that it is empty. `/ErrorStdOut=UTF-8` is needed to get that output at all, and
in this environment it only surfaced through PowerShell — the Bash tool's
redirection swallowed it.

**`1 == true` in AHK.** A test harness that checks `value == true` before
checking for an integer prints every count of one as `true` and every count of
zero as `false`, which turns a failing length assertion into
`expected: true / actual: false`. `tests/run.ahk`'s `Show()` has the fix and a
comment saying why.

**`==` on two Arrays compares identity.** Every array assertion written with it
passes or fails for the wrong reason. `tests/run.ahk` has an `Equal()` that
recurses.

**A GUI script can be smoke-tested from outside without pressing anything.**
`WinWait` on the title, then `ListViewGetContent`, `ControlGetText("Edit1")` and
`ControlGetText("Static1")` read the list, the preview and the status line from
another process. That is how the comment-rows fix was demonstrated against both
the original and the fixed script — four rows against six — without a single
keystroke being sent. It took about forty lines and is worth stealing for any
AHK GUI here.

**The riskiest code paths are still `SendAll()` and `FocusTarget()`.** Both are
now thin: the decisions are in `lib/core.ahk` and the plumbing is a loop and a
`WinActivate`. Treat a change to either as needing a real VM.

## What still needs a human

Nothing here can type into a VM, so the whole point of the program is unverified
by this pass. Five things, about twenty minutes, and step 3 is the one that
matters.

1. **Run it.** `vm_command_stepper.ahk` with your own `commands.txt`. The list
   should show your section headers as rows with a blank number column, and the
   selection should start on the first actual command, not on the first comment.

2. **Press F7 with a VM focused.** One command should be typed and *not* run.
   Press F6 and F7 again: the same command should be retyped. Press F8: the
   pointer should move on without typing, stepping over any comment.

3. **Press Ctrl+F5 and read the dialog, then press No.** Against the real
   `commands.txt` it should say 150 commands and report 27 lines it cannot pace,
   listing the first five. This is the fix for the P1 that could have corrupted
   a network config, and reading the dialog once is the whole confirmation.

   Then press Ctrl+F5 again, say Yes on a short scratch file, and **press Esc
   part way through**. It should stop within a character or two, leave the
   current line half-typed with no Enter after it, and say so.

4. **Press Pause, then press F5 in a browser.** The browser should refresh.
   Press Pause again and F5 should reload the command file instead. The tray
   tooltip should say which state you are in.

5. **Press F5 during a Send All.** It should refuse with a message rather than
   restarting the run. This is the bug the first review missed and it is the
   cheapest of the five to check.

## Licence, 2026-10-02

The author chose one licence for all of their projects: free for personal,
non-commercial use, modifiable for the user's own use, and not to be
distributed, original or modified. No standard licence says that, so `LICENSE`
is a short custom text, the same in every project apart from the year and what
it excludes. The README's licence section says the same. Anything above that
calls the licence an open question, or calls the project MIT, is superseded.

## CI, 2026-10-02

`.github/workflows/ci.yml` installs AutoHotkey 2.0.28 (checked against its
published SHA-256) and runs `tests/run.ahk` from bash on `windows-latest`,
with full history for the transcription check. Nothing has been pushed, so it
has not run on GitHub yet. Every job was run before committing, from a fresh
clone of this branch, the way a runner would run it: Windows jobs here, in
PowerShell 7 or the shell the step names, with only the tools the job sets up
on `PATH`. 425.

From bash because PowerShell does not reliably wait for AutoHotkey, a GUI
program, or report its exit code.
