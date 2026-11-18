# Contributing to SpliceFS packages

This repository holds the package site (the setup script, the public keys, and a page that sends a
person to the install instructions on the website) and the packaging of the programs. Every
change is reviewed as code that runs as root.

## Before you start

Open an issue first for anything larger than a correction, so the approach can be agreed
before work is spent on it.

## Development setup

```sh
make site     # writes dist/site
make check    # builds, then runs every check
make lint     # ShellCheck on the built script, the steps and the build scripts
```

`make check` needs `python3`. It also uses `dash` and `bash` when they are installed.
`make lint` needs `shellcheck`.

## Branches and pull requests

There is one long-lived branch, `main`. It is protected: no direct pushes, no force pushes, no
deletion, and the checks must pass before a merge.

Every change is a pull request into `main` from its own branch. Name the branch
`feature/<name>`, `bug/<name>`, or anything else that describes the change.

### Change log

The description of a pull request must have a section `## Change log` with one line for each
thing a user would notice:

```
## Change log

- The setup script tells which repository file it wrote.
```

A change that nothing changes for users has one entry that starts with `Internal:`. The entries
become the notes of the release that the merge gets, so the check fails without them. If you leave
the section out in a branch of this repository, an entry is drafted from the change and written
into the description, where you can change it. Nobody edits `CHANGELOG.md` for a change, and no
file holds a version.

### Keeping the branch current

A branch must sit on the tip of `main`. When `main` moves, the bot rebuilds every open pull
request on the new tip, so expect force-pushes to your branch. Run
`git pull --rebase` (or reset to the remote branch) before you add commits. If the rebuild hits
a conflict, the bot leaves the branch as it is and says so in a comment. Merge `main` into
the branch locally, resolve the conflict there, and push.

### Merging

A pull request merges with one merge commit. Squash and fast-forward merges are off.

## Standards

### The setup script

- POSIX `sh` only. The script runs under dash, BusyBox ash and bash.
- Idempotent: run again at any point, it repairs what is broken and changes nothing that
  works. A change that breaks this does not merge.
- Never weaken a signature check, and never add an option that skips one.
- The script installs no package. It prints the commands that do.
- No temporary files in folders other users can write to.
- ShellCheck reports nothing. A finding is fixed, or disabled on that line with the reason.

### The page of the package site

- It only sends a person to https://splicefs.org/install/: a refresh at once, a canonical link and
  a plain link, no style, no script. `make check` enforces it. The install instructions are
  written on the website, not here.

### Tests

- Every change to the script or the steps comes with a check in `scripts/check.sh` or in the
  install tests that would fail without it.

### Commits and pull requests

- One purpose per commit. The message says what changed and why.
- A pull request targets `main`. CI must pass: the checks, ShellCheck and the
  SonarQube quality gate.

## What CI checks

| Workflow | What it does |
| --- | --- |
| CI | builds the site and runs every check in `scripts/check.sh` |
| Rules | on pull requests: checks the `## Change log` section of the description |
| Main | on every push to `main`: rebuilds the open pull requests on the new tip |
| Tag | on every push to `main` and every release of a program: puts the next version number on it as a tag and makes the release |
| Security | ShellCheck on all shell files, dependency review on pull requests |
| SonarQube | quality and security rating on SonarQube Cloud |
| Install tests | runs the setup script on every supported system, on x86-64 and arm64, weekly as well |
| Release | on a number tag: signs the script and publishes the site |
| Publish programs | on a number tag: builds, tests and publishes the packages of every program in `programs/` |
| Scorecard | OpenSSF Scorecard, published weekly and on every push |

## Versioning and releases

A version is a whole number: 1, 2, 3. There is no major, minor or patch, and nothing is promised
about compatibility between two numbers: every change is just a change. No file holds the number.

Every merge into `main` is a version. Right after the merge, the Tag workflow puts the next number
(the highest number tag plus one) on the merge commit as a tag, which starts the build, and makes
a GitHub release for it. The notes of the release are the `## Change log` entries of the pull
requests merged since the previous number, then a line ("Release of server v1.2.3.") for every
release of the server or the client published since the previous number was cut, read from their
own releases. The cut of a number is the time its tagging started; it is the last line of its
notes, in a comment that GitHub does not show, so a release published while a number is being
made is in the next number and no release is in two. Nobody
creates tags or release branches by hand: only the release bot can create a tag, and a tag never
changes. A release of the server or the client also gets a number, even when the tip of `main`
has one already.

The Release workflow runs the checks, signs `setup.sh` with the signing subkey and publishes the
site over rsync. `setup.sh.asc` is `setup.sh` clearsigned: the script and its signature in one
file, so no second file has to match it. The GitHub release of the tag is made with the tag, not
by this workflow. The keys live in the `publish`
environment, which only tags can use.

The Publish programs workflow starts on the same tag. For each program in `programs/` it takes the
latest GitHub release of the program. A release that is not published yet is published as revision
0 of its packages. A published release gets the next revision only when the packaging differs from
the newest published revision; otherwise nothing is published and the summary of the run says so.
Both workflows check first that the tag is a whole number and its commit is on `main`. A person can
run Publish programs by hand, started on a tag.

The Upload check workflow, started by hand, lists the remote site folder to prove the upload
credentials work without publishing.

## License

By contributing you agree that your contribution is licensed under the [MIT license](LICENSE).
