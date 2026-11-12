# Contributing to SpliceFS packages

This repository is small on purpose: the install script, the manual steps the page shows,
the page, and the public keys. Every change is reviewed as code that runs as root.

## Before you start

Open an issue first for anything larger than a correction, so the approach can be agreed
before work is spent on it.

## Development setup

```sh
make site     # writes dist/site
make check    # builds, then runs every check
make lint     # ShellCheck on the built script, the manual steps and the build scripts
```

`make check` needs `python3`. It also uses `node`, `dash` and `bash` when they are installed.
`make lint` needs `shellcheck`.

## Branches and pull requests

There is one long-lived branch, `main`. It is protected: no direct pushes, no force pushes, no
deletion, and the checks must pass before a merge.

Every change is a pull request into `main` from its own branch. Name the branch
`feature/<name>`, `bug/<name>`, or anything else that describes the change.

### Change scope

The description of a pull request must contain exactly one line that states the scope of the
change:

```
change_scope: revision
```

| Value | Meaning | Version |
| --- | --- | --- |
| `revision` | a fix or a change that keeps every client and server working together | `X.Y.Z` becomes `X.Y.(Z+1)` |
| `minor` | a new feature, or anything that changes how client and server talk | `X.Y.Z` becomes `X.(Y+1).0` |
| `major` | never merged | a new major version is a new repository named `<name>_v<major>` |

The pull request template has the line. A missing or invalid line fails the check, whatever the
tests say.

### The version

The release bot reads the version of `main`, raises it by the scope, and adds one commit to your
branch that writes it to the file `VERSION`. Do not edit `VERSION` by hand. The one exception is
a pull request from a fork, where the bot cannot push: set `VERSION` to the value the failing
check names.

### Keeping the branch current

A branch must sit on the tip of `main`. When `main` moves, the bot rebuilds every open pull
request on the new tip and sets its version again, so expect force-pushes to your branch. Run
`git pull --rebase` (or reset to the remote branch) before you add commits. If the rebuild hits
a conflict, the bot leaves the branch as it is and says so in a comment. Rebase it by hand and
push.

### Merging

A pull request merges with one merge commit. Squash and fast-forward merges are off.

## Standards

### The install script and the manual steps

- POSIX `sh` only. The script runs under dash, BusyBox ash and bash.
- Idempotent: run again at any point, it repairs what is broken and changes nothing that
  works. A change that breaks this does not merge.
- Never weaken a signature check, and never add an option that skips one.
- The script and the manual steps in `steps/` must leave a system in the same state.
- No temporary files in folders other users can write to.
- ShellCheck reports nothing. A finding is fixed, or disabled on that line with the reason.

### The page

- Self-contained: no external scripts, fonts or images.
- The commands shown are byte for byte the files in `steps/`; `make check` enforces it.

### Tests

- Every change to the script or the steps comes with a check in `scripts/check.sh` or in the
  install tests that would fail without it.

### Commits and pull requests

- One purpose per commit. The message says what changed and why.
- A pull request targets `main`. CI must pass: the checks, ShellCheck, CodeQL and the
  SonarQube quality gate.

## What CI checks

| Workflow | What it does |
| --- | --- |
| CI | builds the site and runs every check in `scripts/check.sh` |
| Rules | on pull requests: checks the `change_scope` line and the `VERSION` file the bot sets |
| Main | on every push to `main`: tags the new version and rebuilds the open pull requests |
| Security | ShellCheck on all shell files, CodeQL on the page's script, dependency review on pull requests |
| SonarQube | quality and security rating on SonarQube Cloud |
| Install tests | runs the install script on every supported system, on x86-64 and arm64, weekly as well |
| Release | on a version tag: signs the script, publishes the site, creates the release |
| Scorecard | OpenSSF Scorecard, published weekly and on every push |

## Versioning and releases

Versions are `0.x.y` for now, with no suffixes. The promise about compatibility:

- Below 1.0.0 nothing is promised, even between a client and a server of the same version.
- From 1.0.0 on, with the same first number, a client works with every server whose second
  number is equal or higher. The third number never matters, barring a bug; a bug that
  affects it is fixed by raising the second number on both sides.

Every merge into `main` is a release. The merge is tagged `v<VERSION>` automatically, which
starts the Release workflow. Nobody creates tags or release branches by hand. One change, one
version.

The Release workflow runs the checks, signs `install.sh` with the signing subkey, publishes the
site over rsync and creates the GitHub release with `install.sh`, `install.sh.sha256` and
`install.sh.asc`. The keys live in the `publish` environment, which only version tags can use.

The Upload check workflow, started by hand, lists the remote site folder to prove the upload
credentials work without publishing.

## License

By contributing you agree that your contribution is licensed under the [MIT license](LICENSE).
