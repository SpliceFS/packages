# SpliceFS packages

[![CI](https://github.com/SpliceFS/packages/actions/workflows/ci.yml/badge.svg)](https://github.com/SpliceFS/packages/actions/workflows/ci.yml)
[![Install tests](https://github.com/SpliceFS/packages/actions/workflows/install-tests.yml/badge.svg)](https://github.com/SpliceFS/packages/actions/workflows/install-tests.yml)
[![Security](https://github.com/SpliceFS/packages/actions/workflows/security.yml/badge.svg)](https://github.com/SpliceFS/packages/actions/workflows/security.yml)
[![Quality gate](https://sonarcloud.io/api/project_badges/measure?project=SpliceFS_packages&metric=alert_status)](https://sonarcloud.io/summary/overall?id=SpliceFS_packages)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/SpliceFS/packages/badge)](https://scorecard.dev/viewer/?uri=github.com/SpliceFS/packages)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/16609/badge)](https://www.bestpractices.dev/projects/16609)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

The package site for SpliceFS: the install page, the setup script and the public signing
keys. It is served at https://packages.splicefs.org.

## Install

Step 1: set up the package repository. The script registers the SpliceFS repository and its
signing key. It installs no package and takes no arguments.

```
curl --proto '=https' --tlsv1.2 -fsSL https://packages.splicefs.org/setup.sh -o ~/splicefs-setup.sh &&
  sudo sh ~/splicefs-setup.sh
```

Step 2: install with the system's own package manager. The script prints these commands for
your system when it is done. On Debian and Ubuntu they are:

```
sudo apt-get update
sudo apt-get install splicefs-server    # the server
sudo apt-get install splicefs-client    # the client
```

The commands for dnf, zypper, apk and pkg (FreeBSD) are on the page. The script is safe to run
again. Manual steps for each system are on the page as well.

## Verify the setup script

The script checks itself before it changes anything: it downloads its published SHA-256 hash and
compares it with its own file. If they differ, the copy is incomplete, was changed, or is not the
latest, and the script stops and tells you how to get the latest one.

The SHA-256 of the published script for each release is listed in this repository's releases.
To check a download before running it:

```
sha256sum ~/splicefs-setup.sh
```

Compare the output with the hash in the release.

The script is also signed. Download the signature and verify it with the public key:

```
curl -fsSLo ~/splicefs-setup.sh.asc https://packages.splicefs.org/setup.sh.asc
curl -fsSLo ~/splicefs.asc https://packages.splicefs.org/keys/splicefs.asc
gpg --show-keys --fingerprint ~/splicefs.asc
gpg --import ~/splicefs.asc
gpg --verify ~/splicefs-setup.sh.asc ~/splicefs-setup.sh
```

The fingerprint printed by `--show-keys` must be the one below. `gpg --verify` must report a
good signature from that key.

The OpenPGP key that signs the apt and rpm packages has this fingerprint. It is the second place to check the key the script puts on your system:

```
93F2 C425 AA5A C125 B6C2  D10A 47FB E2B8 21A4 E69F
```

The public keys are in `keys/` (`splicefs.asc` for apt and rpm, `splicefs.rsa.pub` for
Alpine and FreeBSD) and at https://packages.splicefs.org/keys/.

## Build and check

```
make site     # writes dist/site
make check    # builds, then runs every check
make e2e-prepare  # builds ../server and ../client with throwaway keys into dist/e2e/site
make e2e      # runs the setup script in a container of every supported system
make e2e-freebsd  # runs the setup script in a FreeBSD machine of every supported release (FREEBSD=15.1 for one)
```

`make check` needs `python3`. It also uses `node`, `dash` and `bash` when they are installed.

## Layout

- `site/`: the install page (`index.html`).
- `steps/`: the manual repository setup and the install commands for each package manager,
  shown on the page.
- `keys/`: the public signing keys.
- `scripts/`: `build-site.sh`, `sign-site.sh`, `publish.sh` and `check.sh`.
- `setup.sh.in`: the setup script template, with the keys and base URL filled in at build.
- `dist/`: build output, not committed.

## License

MIT. See `LICENSE`.
