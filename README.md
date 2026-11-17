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

## After the install

Installing a Linux package installs the service and does not start it or turn it on. Start it,
and have it start at boot, with the service manager of the system. The server's service is
`splicefsd` and the client's is `splicefs`.

systemd (Debian, Ubuntu, Rocky Linux, Amazon Linux, openSUSE):

```
sudo systemctl enable --now splicefsd    # the server
sudo systemctl enable --now splicefs     # the client
```

OpenRC (Alpine), as root:

```
rc-update add splicefsd default && rc-service splicefsd start    # the server
rc-update add splicefs default && rc-service splicefs start      # the client
```

An upgrade restarts a service that was running and leaves a stopped one stopped; it never turns
a service on or off. Removing the package stops the service and turns it off; its data and the
`splicefs` user stay. In a container without a running service manager the package only
installs its files.

## Verify the setup script

The script checks itself before it changes anything: it downloads the published `setup.sh` and
compares it with its own file. If they differ, the copy is incomplete, was changed, or is not the
latest, and the script stops and tells you how to get the latest one.

The script is also published as one signed file, `setup.sh.asc`. It holds the script and its
signature together, so there is nothing to pair up. Download it and the public key, and look at
the key:

```
curl -fsSLo ~/splicefs-setup.sh.asc https://packages.splicefs.org/setup.sh.asc
curl -fsSLo ~/splicefs.asc https://packages.splicefs.org/keys/splicefs.asc
gpg --show-keys --fingerprint ~/splicefs.asc
gpg --import ~/splicefs.asc
```

The fingerprint printed by `--show-keys` must be the one below. Then verify the file and write
the script it holds:

```
gpg --verify ~/splicefs-setup.sh.asc &&
  gpg --output ~/splicefs-setup.sh --decrypt ~/splicefs-setup.sh.asc
```

`gpg --verify` must report a good signature from that key. The second command runs only after
that, writes the verified script to `~/splicefs-setup.sh` and checks the signature once more.
Run the script as in step 1: `sudo sh ~/splicefs-setup.sh`.

The OpenPGP key that signs the apt and rpm packages has this fingerprint. It is the second place to check the key the script puts on your system:

```
93F2 C425 AA5A C125 B6C2  D10A 47FB E2B8 21A4 E69F
```

The SHA-256 of the published `setup.sh` for each release is listed in this repository's releases.
To check a plain download against it:

```
sha256sum ~/splicefs-setup.sh
```

The public keys are in `keys/` (`splicefs.asc` for apt and rpm, `splicefs.rsa.pub` for
Alpine and FreeBSD) and at https://packages.splicefs.org/keys/.

## Build and check

```
make site     # writes dist/site
make check    # builds, then runs every check
make e2e-prepare  # builds ../server and ../client with throwaway keys into dist/e2e
make e2e      # runs the setup script in a container of every supported system
make e2e-freebsd  # runs the setup script in a FreeBSD machine of every supported release (FREEBSD=15.1 for one)
make packages PROGRAM=server BIN=<programs> SRC=<source> VERSION=v1.2.3   # builds deb, rpm and apk into dist/server (PROGRAM=client for the client)
make package-test PROGRAM=server   # installs and removes each package on every server image (ONLY=deb or ONLY=<image> for one)
make service-test PROGRAM=server   # proves the service installs idle, starts when told, answers, restarts, upgrades and stops, on every image
make upgrade-test PROGRAM=server  # installs the newest published release, then upgrades to the packages in dist (only when the packaging changed)
make repo PROGRAM=server           # builds the signed apt, rpm and Alpine repositories into dist/server/repo
make repo-test PROGRAM=server      # installs from them with signature checks on
make package-order-test                           # checks that the package versions sort right in dpkg, rpm and apk
```

The tests need Docker and the packages that `make packages` left in `dist/<program>`. `make packages`
records the version it built in `dist/<program>/version`, and the tests read it from there, so they
are not given the version again. A `VERSION` given to a test that is not the recorded one is an error.

### Package and test a program in CI

The workflow `package-and-test.yml` does all of the above for one program, from the CI run of the
repository that releases it: it builds the packages and the signed repositories on amd64 and
arm64 runners, runs the package, service, repository and upgrade tests of every format, and ends
in one job, `Result`, that fails unless all passed. The caller builds its programs, uploads its
`dist/bin` as an artifact, and calls:

```yaml
  packages:
    name: Packages
    needs: build
    uses: SpliceFS/packages/.github/workflows/package-and-test.yml@main
    with:
      program: server
      bin-artifact: bin
```

The source tree and the version are the caller's own, at the commit under test. Without
`bin-artifact` the workflow tests the newest release of the program instead (`scripts/release-bin.sh`
proves its archives with the signature and `SHA256SUMS` and unpacks them into the `BIN` layout);
the CI of this repository does that for both programs, so a packaging change is tested on its own.
`packages-ref` (default `main`) is the ref of this repository the jobs use; keep it the same as the
ref of the `uses` line.

`make check` needs `python3`. It also uses `node`, `dash` and `bash` when they are installed.

## Layout

- `site/`: the install page (`index.html`).
- `steps/`: the manual repository setup and the install commands for each package manager,
  shown on the page.
- `keys/`: the public signing keys.
- `scripts/`: `build-site.sh`, `sign-site.sh`, `publish.sh` and `check.sh`, and the scripts that
  build, test and publish packages (`package-*.sh`, `service-test*.sh`, `repo-*.sh`,
  `signing-keys.sh`, `upgrade-test*.sh`, `upgrade-diff.sh`), and `release-bin.sh`, which proves and
  unpacks the release archives of a program.
- `programs/<program>/`: the package definitions of one program (deb, rpm, Alpine, systemd, OpenRC)
  and its `program.conf`, which says what the program is: package name, service program,
  programs, documents, and the repository its releases are published in (`release_repo`, which
  the upgrade test downloads the newest release from). `BIN` is a folder of compiled programs,
  one folder `<os>-<arch>` each, and `SRC` the program's source tree at that version, which holds
  the documents the packages ship.
  A program that installs links names them in `programs/<program>/links`, one `<link> <target>`
  a line, a package test hook in `programs/<program>/package-test-extra.sh`, and what a working
  service means in `programs/<program>/service-check.sh`.
- `packaging/test-systems`: the server images the packages are tested on.
- `packaging/service/<manager>/`: what installing, upgrading and removing do to the service under
  systemd and OpenRC, once for every program and package format. The install scripts of a
  program name a step on a line of its own (`@service:after-files@`) and the build fills it in.
- `setup.sh.in`: the setup script template, with the keys and base URL filled in at build.
- `dist/`: build output, not committed.

## License

MIT. See `LICENSE`.
