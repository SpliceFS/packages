# SpliceFS packages

The package site for SpliceFS: the install page, the install script and the public signing
keys. It is served at https://packages.splicefs.org.

## Install

```
curl -fsSL https://packages.splicefs.org/install.sh -o /tmp/splicefs-install.sh &&
  sudo sh /tmp/splicefs-install.sh server
```

Use `client` or `both` instead of `server` for the other packages. The script is safe to run
again. Manual steps for each system are on the page.

## Verify the install script

The SHA-256 of the published script for each release is listed in this repository's releases.
To check a download before running it:

```
sha256sum /tmp/splicefs-install.sh
```

Compare the output with the hash in the release.

The OpenPGP key that signs the apt and rpm packages has this fingerprint:

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
