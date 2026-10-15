# Untracked from this repository — and still in its history

Written 2026-09-18 during the cleanup pass. Nothing here is a credential in the
password-or-API-key sense, which is why this file is short. It is here because
the file it describes is on a GitHub remote and the exposure has a live
consequence that only you can decide what to do about.

## What was untracked

`commands.txt`. It has been removed from the index and added to `.gitignore`.
**It is still on disk and unchanged** — it is your runbook and you use it. What
changed is that future commits will not carry it, and `commands.example.txt`
now ships in its place.

## What it contains

It is described in its own header as extracted from
`ICT221_Assessment_Task_3_Report_guide.md`, and it is a complete hardening
runbook for a lab VM. In it:

- A person's full name, in two places — `Reviewed by:` in a sample record and a
  byline comment inside a shell script the runbook writes.
- A login name, and two derived accounts built from it.
- Your LAN layout, hardcoded: a `/24`, a specific host address, a gateway, a
  second host used as a backup target, and the nameservers. Private range, so
  this is small — but it is your home network.
- An identifiable university unit code and assessment number.
- A fabricated patient record with a name, date of birth, Medicare number,
  diagnosis and prescription, labelled `Confidential - Patient Health
  Information`. It is synthetic. It does not read as synthetic at a glance,
  which is the problem with it sitting in a public repository.
- The full shape of that machine's SSH configuration: which authentication
  methods were enabled, where the backup key lives, what the audit rules watch.
  None of it is secret on its own, and together it is a map.

There are no passwords, no private keys and no API tokens in the file. Nothing
in it was used, connected to, or tested against.

## The live part

The remote is:

    https://github.com/nishantmajhi/VM-Command-Stepper.git

`commands.txt` is present in `origin/main`, in both commits — `347bac6`
(2026-08-13) and `74238bf` (2026-08-20). Whether that repository is public was
not checked from here, and nothing was fetched beyond what git already had.

So untracking it stops the next commit from carrying it. It does **not** remove
it from what is already published.

## What was deliberately not done

The history was not rewritten. Per the standing constraint in the archive's
`CLAUDE.md` that is irreversible, affects every clone, and is your decision. If
you want it gone from the remote, the options are, roughly in order of how
drastic they are:

1. Make the repository private, if it is not already. Fastest, and enough if
   the concern is search engines rather than anyone who already cloned it.
2. Delete the repository and re-create it from this local branch, which has no
   `commands.txt` in its index. You lose the two commits of history; there is
   very little in them.
3. `git filter-repo --path commands.txt --invert-paths` and force-push. Removes
   it from every commit. Everyone with a clone has to re-clone, and GitHub may
   keep the old objects reachable by SHA until you ask support to garbage
   collect them.

One note on the name: the GitHub account is `nishantmajhi`, the commit author
is `manishmajhi79@gmail.com`, and the name inside `commands.txt` is someone
else's. If that file came from shared coursework, the person named in it may
not know it is published, which is worth a moment's thought before choosing
between the three options above.
