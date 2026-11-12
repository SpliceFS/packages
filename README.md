# SpliceFS packages

[![CI](https://github.com/SpliceFS/packages/actions/workflows/ci.yml/badge.svg)](https://github.com/SpliceFS/packages/actions/workflows/ci.yml)
[![Security](https://github.com/SpliceFS/packages/actions/workflows/security.yml/badge.svg)](https://github.com/SpliceFS/packages/actions/workflows/security.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/SpliceFS/packages/badge)](https://scorecard.dev/viewer/?uri=github.com/SpliceFS/packages)
[![Quality gate](https://sonarcloud.io/api/project_badges/measure?project=SpliceFS_packages&metric=alert_status)](https://sonarcloud.io/summary/overall?id=SpliceFS_packages)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

The package site for SpliceFS: the install page, the install script and the public signing
keys. It is served at https://packages.splicefs.org.

## Install

```
curl --proto '=https' --tlsv1.2 -fsSL https://packages.splicefs.org/install.sh -o ~/splicefs-install.sh &&
  sudo sh ~/splicefs-install.sh server
```

Use `client` or `both` instead of `server` for the other packages. The script is safe to run
again. Manual steps for each system are on the page.

## Verify the install script

The SHA-256 of the published script for each release is listed in this repository's releases.
To check a download before running it:

```
sha256sum ~/splicefs-install.sh
```

Compare the output with the hash in the release.

The OpenPGP key that signs the apt and rpm packages has this fingerprint. It is the second place to check the key the script installs:

```
93F2 C425 AA5A C125 B6C2  D10A 47FB E2B8 21A4 E69F
```

The public keys are in `keys/` (`splicefs.asc` for apt and rpm, `splicefs.rsa.pub` for
Alpine) and at https://packages.splicefs.org/keys/.

## Build and check

```
make site     # writes dist/site
make check    # builds, then runs every check
```

`make check` needs `python3`. It also uses `node`, `dash` and `bash` when they are installed.

## Layout

- `site/`: the install page (`index.html`).
- `steps/`: the manual repository setup for each package manager, shown on the page.
- `keys/`: the public signing keys.
- `scripts/`: `build-site.sh` and `check.sh`.
- `install.sh.in`: the install script template, with the keys and base URL filled in at build.
- `dist/`: build output, not committed.

## License

MIT. See `LICENSE`.
