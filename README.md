# SpliceFS packages

[![CI](https://github.com/SpliceFS/packages/actions/workflows/ci.yml/badge.svg)](https://github.com/SpliceFS/packages/actions/workflows/ci.yml)
[![Install tests](https://github.com/SpliceFS/packages/actions/workflows/install-tests.yml/badge.svg)](https://github.com/SpliceFS/packages/actions/workflows/install-tests.yml)
[![Security](https://github.com/SpliceFS/packages/actions/workflows/security.yml/badge.svg)](https://github.com/SpliceFS/packages/actions/workflows/security.yml)
[![Quality gate](https://sonarcloud.io/api/project_badges/measure?project=SpliceFS_packages&metric=alert_status)](https://sonarcloud.io/summary/overall?id=SpliceFS_packages)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/SpliceFS/packages/badge)](https://scorecard.dev/viewer/?uri=github.com/SpliceFS/packages)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/16609/badge)](https://www.bestpractices.dev/projects/16609)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

The package site for SpliceFS: the setup script, the public signing keys, the package
repositories, and a page that sends a person to the website. It is served at
https://packages.splicefs.org.

The install instructions are at https://splicefs.org/install/.

## Signing key

The OpenPGP key that signs the apt and rpm packages has this fingerprint. It is the second place
to check the key the setup script puts on a system:

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
make help     # every target, with what it does and the variables it needs
make check    # builds, then runs every check
make lint     # ShellCheck on every shell file
```

A target that works on one program takes `PROGRAM=<program>`, a folder of `programs/`. The comments
in the `Makefile` describe every variable.

The tests need Docker and the packages that `make packages` left in `dist/<program>`. `make packages`
records the version it built in `dist/<program>/version`, and the tests read it from there, so they
are not given the version again. A `VERSION` given to a test that is not the recorded one is an error.
`make package-test` does not run `package-order-test` and `apk-resign-test`: CI runs the first once
for a change and the second in the Alpine jobs.

### Package and test a program in CI

The workflow `package-and-test.yml` does all of the above for one program, from the CI run of the
repository that releases it: it builds the packages and the signed repositories on amd64 and
arm64 runners, runs the package, service, repository and upgrade tests of every format, builds
the FreeBSD packages in a FreeBSD machine of each release in `packaging/freebsd/releases`
(`make package-freebsd`, which needs the hardware virtualization of an amd64 runner), and ends
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
It calls the two halves of the workflow itself, `build-packages.yml` and then `check-packages.yml`, so
that the lifecycle test starts when both programs are built and does not wait for their tests.
`packages-ref` (default `main`) is the ref of this repository the jobs use; keep it the same as the
ref of the `uses` line.

A run reads the newest package of a program on the package site once (`scripts/published-newest.sh`,
which prints a version such as `0.5.34-1`) and gives it to `make packages` as `UPGRADE_FROM`. The
version record in `dist/<program>/version` keeps it, and the upgrade and lifecycle tests download that
package from the site and start from it, so a package published while the run is going never turns
the upgrade into a downgrade. A release on GitHub carries no packages: what people have installed is
what the site serves. Without `UPGRADE_FROM` (a build by hand) the tests ask the site when they run,
and a program with no package on the site yet has nothing to upgrade from, so the upgrade test says so
and skips.

`make check` needs `python3`. It also uses `dash` and `bash` when they are installed.

## Layout

- `site/`: the page that sends a person to the install instructions of the website (`index.html`).
- `steps/`: the uninstall commands (`uninstall-<family>.sh`) and the commands of a user who runs the
  client as themselves (`user-mode-*.sh`). The lifecycle test and the user mode test run them.
- `keys/`: the public signing keys.
- `scripts/`: `build-site.sh`, `sign-site.sh`, `publish.sh` and `check.sh`, `setup-remove-test.sh`
  (setup and removal in a fake root, for every family), and the scripts that
  build, test and publish packages (`package-*.sh`, `service-test*.sh`, `repo-*.sh`,
  `signing-keys.sh`, `upgrade-test*.sh`, `upgrade-diff.sh`), and `release-bin.sh`, which proves and
  unpacks the release archives of a program.
- `programs/<program>/`: the package definitions of one program (deb, rpm, Alpine, systemd, OpenRC)
  and its `program.conf`, which says what the program is: package name, service program,
  programs, documents, and the repository its releases are published in (`release_repo`, which
  the workflows read the newest release from). `BIN` is a folder of compiled programs,
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
