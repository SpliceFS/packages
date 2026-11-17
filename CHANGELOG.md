# Changelog

Every merge into `main` is a release with its own version. This file has one heading per version,
newest first, and says what that version changed for the people who install SpliceFS from packages:
the setup script and the page at packages.splicefs.org.

The change log of all parts of SpliceFS, side by side: https://splicefs.org/changelog/

## [0.4.15] - 2026-11-17

- Installing a SpliceFS package no longer starts or turns on its service; start it with the system's
  service manager (see "After the install"). An upgrade restarts only a running service, and
  removing a package stops and turns off its service.

## [0.4.14] - 2026-11-17

- `sh setup.sh --remove` removes the SpliceFS repository and signing key that setup.sh added; remove
  the packages first with the commands it prints.

## [0.4.13] - 2026-11-17

- Internal: FreeBSD packages of both programs are built and checked here on prepared machine images;
  the FreeBSD install test no longer downloads FreeBSD.

## [0.4.12] - 2026-11-17

- Internal: a reusable workflow packages and tests a program from its built programs; this
  repository tests its packaging on the newest releases.

## [0.4.11] - 2026-11-17

- Internal: the package, service, repository and upgrade tests of both programs run in this
  repository.

## [0.4.10] - 2026-11-17

- Internal: this repository can build the client packages from built programs.

## [0.4.9] - 2026-11-17

- Internal: this repository can build the server packages from built programs.

## [0.4.8] - 2026-11-15

- The setup script's signature is now in the same file as the script, `setup.sh.asc`. Verify it with
  `gpg --verify` and write the verified script with `gpg --decrypt`. The separate `setup.sh.sha256`
  file is gone.

## [0.4.7] - 2026-11-15

- Internal: the setup script test no longer depends on the clock. Nothing changes for users.

## [0.4.6] - 2026-11-14

- Internal: the end-to-end test's web server always uses a port of its own. Nothing changes for
  users.

## [0.4.5] - 2026-11-14

- Internal: contributors are told to merge `main` down to fix a branch the bot cannot rebuild.
  Nothing changes for users.

## [0.4.4] - 2026-11-14

- Internal: a failed release, merge or scheduled check opens an issue that emails the owner. Nothing
  changes for users.

## [0.4.3] - 2026-11-14

- Internal: a release uploads the package files before the index files that name them, and stops at
  the first failed step. Nothing changes for users.

## [0.4.2] - 2026-11-14

- Internal: a release refuses a tag that is not on main or does not match `VERSION`. Nothing changes
  for users.

## [0.4.1] - 2026-11-14

- Internal: the setup script is now tested on FreeBSD on every change, in a virtual machine of each
  supported release. Nothing changes for users.

## [0.4.0] - 2026-11-13

- The setup script checks itself before it changes anything: it downloads its published SHA-256 hash
  and compares it with its own file. A copy that is incomplete, was changed or is not the latest
  stops and prints how to get the latest one.
- The script must be run from a file, because a script that is piped into a shell has no file to
  check. The FreeBSD command on the packages page now downloads the script first, like the Linux
  ones.
- The check uses `curl`, `wget`, `fetch` or, on Debian and Ubuntu, the downloader that is part of
  apt, so no extra tool is needed.

## [0.3.1] - 2026-11-13

- The packages page links to the change log at `splicefs.org/changelog`, which shows what each
  version of the server, the client and the packages changed.
- Documentation: the change log of this repository now has one entry per version, back to 0.1.0.

## [0.3.0] - 2026-11-13

- FreeBSD is supported. The setup script writes the RSA public key and a `pkg` repository file for
  the server and client repositories, then prints `pkg update` and `pkg install`.
- The packages page shows the same for FreeBSD, with `fetch` in place of curl.
- Tried by hand on FreeBSD 15.1 (arm64), where `pkg install` installed `splicefs-server` and
  `splicefs-client` with the signature check on.

## [0.2.3] - 2026-11-12

- Internal: stricter checks of the files committed to the repository. Nothing changes for users.

## [0.2.2] - 2026-11-12

- Internal: stricter checks of the shell scripts. Nothing changes for users.

## [0.2.1] - 2026-11-12

- openSUSE Leap 15.6 is no longer supported, because its vendor ended its support on 2026-04-30. A
  system is supported only while its own vendor supports it.

## [0.2.0] - 2026-11-12

- The script is now `setup.sh` instead of `install.sh`. It takes no arguments, registers the
  SpliceFS package repository and its signing key, and installs nothing.
- At the end it prints the commands to run next: refresh the package index, then install
  `splicefs-server` or `splicefs-client` with the system's own package manager.
- The packages page shows these two steps. Each release publishes `setup.sh`, `setup.sh.sha256` and
  `setup.sh.asc`.

## [0.1.0] - 2026-11-12

- First release. The install script `install.sh` sets up the SpliceFS package sources with signature
  checks on and installs `splicefs-server`, `splicefs-client` or both.
- Supported: Debian, Ubuntu, RHEL, Rocky Linux, AlmaLinux, Amazon Linux, openSUSE Leap and Alpine,
  on x86-64 and arm64.
- The page shows the manual setup steps for `apt`, `dnf`, `zypper` and `apk`.
- The public keys the packages are checked against are published, and every key download uses HTTPS.
