# Changelog

All notable changes to this project are recorded here. Every merge into `main` is a
release with its own version, so there are no version headings: the
[release page](../../releases) of a version names its change, and this file collects the
notable ones.

## Changes

### Added

- The install script `install.sh` for Debian, Ubuntu, RHEL, Rocky Linux, AlmaLinux, Amazon
  Linux, openSUSE Leap and Alpine, on x86-64 and arm64. It sets up the SpliceFS package
  sources with signature checks on and installs `splicefs-server`, `splicefs-client` or both.
- The manual setup steps for apt, dnf, zypper and apk, and the page that shows them.
- The public keys the packages are checked against.
- Checks, ShellCheck, CodeQL, SonarQube and OpenSSF Scorecard on every push.
- Install tests: the script runs on every supported system against a signed test repository,
  twice to prove a second run changes nothing, and once after damage to prove it repairs it.
- On RHEL-family systems the signing key is imported into the rpm database when the
  repository is added.
- Release workflow: a version tag signs `install.sh` with OpenPGP, publishes the site by rsync
  and creates the GitHub release; `make sign`, `make publish` and `make publish-check`.
- Trunk development: one branch, `main`, and one version per change.
- The script is now `setup.sh`: it only sets up the package repository and takes no
  arguments. The packages are installed with the system's own package manager, with the
  commands the script prints.
- openSUSE Leap 15.6 is no longer supported: its vendor ended its support on 2026-04-30. A
  system is supported only while its own vendor supports it.
