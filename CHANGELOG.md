# Changelog

Every merge into `main` is a release with its own version. This file has one heading per version,
newest first, and says what that version changed for the people who install SpliceFS from packages:
the setup script and the page at packages.splicefs.org.

The change log of all parts of SpliceFS, side by side: https://splicefs.org/changelog/

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
