# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project follows
[Semantic Versioning](https://semver.org).

## [Unreleased]

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
