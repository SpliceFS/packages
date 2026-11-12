# Security policy

This repository holds the SpliceFS install script, which runs as root on other people's
systems, and the public keys that packages are checked against. Problems here are treated
as urgent.

## Reporting a vulnerability

Do not open a public issue for a security problem.

Report it privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**. Include what you ran, on which system, and what happened.

You can expect an acknowledgement within five working days. Once a fix is published, the
advisory is published and the reporter is credited unless they ask not to be.

## Scope

In scope: anything that lets the install script or the manual steps install a package that
is not signed by the SpliceFS key, run code other than the published script, or leave a
system less protected than it was (weakened signature checks, wrong file permissions).

Problems in the programs themselves are reported in the
[server](https://github.com/SpliceFS/server) and
[client](https://github.com/SpliceFS/client) repositories.

## Checking what you run

The published script's SHA-256 and the fingerprint of the signing key are in
[README.md](README.md#verify-the-install-script).
