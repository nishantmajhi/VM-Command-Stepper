# VM Command Stepper

Types a runbook into a VM console, one line at a time, under your control.

You have a list of shell commands — an install guide, a hardening checklist, a
set of setup steps — and a VirtualBox window to run them in. Copy-paste does not
work reliably into that window, and pasting the whole block at once is how you
find out that step 7 needed a different IP address. This types one line, stops,
and waits for you.

It is an [AutoHotkey v2](https://www.autohotkey.com/) script. There is no build
step and nothing to install beyond AutoHotkey itself.

## Why typing, and why one line at a time

**Why typing.** VirtualBox's console expects keystrokes that look like they came
from a keyboard driver. AutoHotkey's `SendText` and `SendInput` inject Unicode
packets instead, and that window drops or scrambles them. This script uses
`Send` in `Event` mode, which goes through `keybd_event` — the same path a real
key press takes — with a small randomised delay between characters so the guest
keeps up.

That choice has a consequence worth knowing before you paste anything into your
command file: **only printable ASCII can be typed.** Event mode goes through
your active keyboard layout, so an em dash, a smart quote or an accented letter
either arrives as the wrong character or not at all. The script checks for this
when it loads the file and names the offending lines in the status bar rather
than letting you discover it inside the VM.

**Why one line at a time.** Because the interesting failures are one line deep.
You see the command in the preview box before it goes anywhere, you press a key,
it is typed but *not* run, and you press Enter yourself when you have read it.

## Requirements

- Windows
- [AutoHotkey v2.0](https://www.autohotkey.com/)

## Getting started

1. Copy `commands.example.txt` to `commands.txt` and put your own commands in
   it, one per line. (`commands.txt` is gitignored on purpose — see
   `SECRETS-TODO.md` for why.)
2. Run `vm_command_stepper.ahk`. If there is no `commands.txt` next to it, it
   asks you to pick a file.
3. Click into your VM's terminal so **it** has keyboard focus.
4. Press `F7` to type the current line. Read it. Press Enter yourself.

The window stays on top and shows the whole list, which line is current, and a
preview of exactly what will be typed.

## The command file

One command per line. Two kinds of line are not commands:

- **Lines starting with `#` are comments.** They appear in the list, with the
  number column left blank to mark them as context rather than something waiting
  to be typed — but they are never typed, and Paste and Next step over them. They are how you mark which lines are commands and which
  are the contents of a file you are typing into an editor. That distinction is
  the difference between running `network:` as a command and pasting it into
  nano, and the list is the only place you can see it.
- **Blank lines are dropped.** They separate sections in the file and would
  otherwise fill the list with empty rows.

  The consequence: **a blank line inside a heredoc or an editor paste is not
  reproduced.** If the file you are typing needs an empty line in the middle,
  this will not produce one. Write that file with `printf` or a heredoc that
  does not need the blank instead.

Leading whitespace on a command **is** preserved, because a line of YAML is
mostly its indentation.

The file is read as UTF-8. A file that is not valid UTF-8 decodes to replacement
characters, which the untypable-character check then reports — so a
wrongly-encoded file is named on screen rather than discovered in the VM.

## Hotkeys

These are global: they work whichever window has focus, so you never have to
click back into this one.

| Hotkey | Action |
|---|---|
| `F7` | **Paste** — types the current command *without* pressing Enter, then moves to the next one |
| `F8` | **Next** — moves on without typing |
| `F6` | **Back** — steps back one command, to retype it |
| `F5` | **Reload** — re-reads the file from disk, keeping your place |
| `Ctrl+F5` | **Send All** — types every remaining command *and* presses Enter after each. Asks first. |
| `Esc` | **Stop** — only while a Send All is running; at any other time Esc is not touched |
| `Pause` | **Suspend / resume** the five keys above |

You can also **click** a row to move the pointer there, or **double-click** it
to move there and type immediately.

`Pause` matters more than it looks. While this script runs, `F5` no longer
refreshes your browser and `F6`–`F8` do nothing anywhere else on the system.
Press `Pause` to give them back; press it again to take them. The tray tooltip
says which state you are in.

Reload keeps your place by remembering the text of the current command and
finding it again in the reloaded file — so inserting a line above where you are
working does not send you back to the top. If that command has gone from the
file entirely, the position is clamped to the nearest valid one.

## Send All, and why it asks

`Send All` types each remaining line, presses Enter, waits a fixed 300 ms, and
moves on. It has no idea whether the previous command finished.

For `mkdir`, `systemctl restart` and `grep`, that is fine. For anything else it
is not, and the failure is not subtle: `sudo nano /etc/netplan/50-cloud-init.yaml`
followed by the YAML to put in it, fired on a 300 ms timer, types a network
configuration into whatever nano managed to draw — or into a `sudo` password
prompt, if that is what is on screen instead.

So Send All asks first, and the question is specific. It names how many commands
it is about to type, and it lists the lines that do not fit the pattern with the
reason for each:

- a line that opens an editor or a pager — `nano`, `vi`, `visudo`, `less`,
  `crontab -e`, `top`
- a line that prompts for a password or a passphrase — `passwd`, `ssh-keygen`,
  `gpg`, `dpkg-reconfigure`
- a line that hands the terminal to another shell, so everything after it runs
  somewhere else — `ssh user@host`, `su - someone`, a bare `python3`
- a line that starts a heredoc, so the lines after it are file content
- `apt install` without `-y`, which stops at `Do you want to continue?`

The detection is deliberately argument-aware, because the distinction is real:
`ssh -V` returns, `ssh user@host` opens a session, and
`ssh user@host "mkdir -p ~/.ssh"` runs one command and comes back. Only the
middle one is flagged.

`Esc` stops a run. It is registered when the run starts and released when it
ends, so it belongs to whatever you are using for the rest of the time. Stopping
mid-line leaves that line half-typed but **not** run — no Enter is sent after an
abort — and the status bar says so, because a half-typed command sitting at a
prompt is something you want to look at before carrying on.

## Configuration

Four constants at the top of `vm_command_stepper.ahk`:

```ahk
CharDelayMin := 3   ; ms, lower bound of the random per-character delay
CharDelayMax := 25  ; ms, upper bound — raise both (e.g. 15-60) if the
                    ; VM console drops or garbles characters
SendAllDelay := 300 ; ms to wait after each Enter during Send All
ABORT_KEY := "Esc"  ; the key that stops a Send All
```

The per-character delay is random within those bounds rather than fixed.

## How it is put together

```
vm_command_stepper.ahk   the plumbing: the file, the GUI, the hotkeys, the keystrokes
lib/core.ahk             every decision, with no side effects
tests/run.ahk            the suite
tests/original.ahk       the pre-cleanup code, for the regression checks
commands.example.txt     a starting point
commands.txt             yours; gitignored
```

`lib/core.ahk` does not send a keystroke, read a file, touch a window or draw a
control. It takes strings and returns values. That is what makes it testable,
and it is where the two things that went wrong in this script live: what counts
as a line worth keeping, and whether a batch of lines is safe to fire unattended.

## Tests

```sh
D:\dev-tools\autohotkey\AutoHotkey64.exe tests\run.ahk
```

425 checks, no framework, no dependencies. It prints a line per section and a
count at the end, and exits non-zero on a failure. It sends no keystrokes,
registers no hotkeys, and touches nothing outside `%TEMP%`, so it is safe to run
while you are working.

Some of those checks are regressions, and they work by asserting what the
*original* code did wrong. The original cannot simply be run from a test — it
registers F5–F8 globally at load and its only output is keystrokes aimed at the
foreground window — so `tests/original.ahk` holds the three functions whose
decisions changed, copied with their I/O lifted out, and the suite checks against
git that the copy still matches commit `74238bf`.

### What is not covered

The GUI and the keystrokes. Nothing here presses `F7` and watches a character
arrive in a VM, and nothing clicks a button. The suite parses the entry point
with AutoHotkey's own `/validate` and reads its source to confirm the decisions
really did move out of it, which is the honest amount of coverage available for
a file whose only output is input to something else.

## License

Free for personal, non-commercial use. You may use, study and modify this
software for yourself, but you may not use it commercially, and you may not
share or publish it, in its original form or modified. See [LICENSE](LICENSE)
for the full terms.
