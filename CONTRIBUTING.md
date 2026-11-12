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

## Branches

SpliceFS uses the gitflow branching model.

- `main` holds released code only. Every commit on it is a release and carries a version tag.
- `develop` is where work comes together. It is the default branch, and pull requests target it.
- `feature/<name>` branches start from `develop` and merge back into it by pull request.
- `release/<version>` branches start from `develop` when a release is prepared. They take only
  fixes and the changelog, and merge into `main` and back into `develop`.
- `hotfix/<version>` branches start from `main` for urgent fixes and merge into `main` and
  `develop`.

`main` and `develop` are protected: no direct pushes, no force pushes, no deletion, and CI
must pass before a merge.

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
- A pull request targets `develop`. CI must pass: the checks, ShellCheck, CodeQL and the
  SonarQube quality gate.

## What CI checks

| Workflow | What it does |
| --- | --- |
| CI | builds the site and runs every check in `scripts/check.sh` |
| Security | ShellCheck on all shell files, CodeQL on the page's script, dependency review on pull requests |
| SonarQube | quality and security rating on SonarQube Cloud |
| Scorecard | OpenSSF Scorecard, published weekly and on every push |

## Versioning and releases

SpliceFS follows [Semantic Versioning](https://semver.org). The site is published from
`main`, which only receives release merges; the hash of each published install script is
recorded in this repository's releases.

## License

By contributing you agree that your contribution is licensed under the [MIT license](LICENSE).
