.PHONY: site check lint sign publish publish-check e2e-prepare e2e clean

site:
	sh scripts/build-site.sh

# Nothing that must stay private may be tracked: no compiled program (it carries the folder
# names of the machine it was built on), no file over 1 MiB, no name of a private machine,
# account or place. The ignore rules help; this check is what stops a mistake.
.PHONY: tracked-files
tracked-files:
	scripts/tracked-files.sh

check: site tracked-files
	sh scripts/check.sh

# Static analysis of every shell file. The built script is analyzed, not the template,
# because the template still holds the key placeholders.
lint: site
	shellcheck --shell=sh dist/site/setup.sh steps/*.sh scripts/*.sh tests/*.sh

# Signs the built script with the key file named by SIGNING_KEY_FILE and proves the signature
# with the public key in keys/ only. Needs gpg.
sign: site
	sh scripts/sign-site.sh

# Uploads the signed site files. Depends on sign so an unsigned site is never published; the
# upload variables are described at the top of scripts/publish.sh.
publish: sign
	sh scripts/publish.sh send

# Proves the upload credentials and host key work by listing the remote root, changing nothing.
publish-check:
	sh scripts/publish.sh check

# Builds both sibling repositories with one set of throwaway keys and assembles the site the
# end to end test serves. Separate from e2e because the build takes minutes and the test
# can be repeated against the same site.
e2e-prepare:
	sh tests/prepare.sh

# Runs the setup script in a container of every system in tests/systems, against the site
# from e2e-prepare, served over local HTTP. Needs docker.
e2e:
	sh tests/run.sh

# Runs the setup script as root in a virtual machine of every FreeBSD release in
# packaging/freebsd/images, which has no Linux container. The machine runs under QEMU inside
# LINUX_IMAGE; this needs Docker, curl and xz, nothing else. FREEBSD=15.1 limits the run to
# one release. Where the machine has to be emulated (any computer but Linux on amd64) a run
# takes many minutes.
LINUX_IMAGE ?= golang:1.27
FREEBSD ?=
.PHONY: e2e-freebsd
e2e-freebsd:
	LINUX_IMAGE=$(LINUX_IMAGE) FREEBSD=$(FREEBSD) tests/freebsd.sh

clean:
	rm -rf dist
