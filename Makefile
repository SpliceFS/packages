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
	shellcheck --shell=sh dist/site/setup.sh steps/*.sh scripts/*.sh tests/*.sh \
		programs/*/deb/postinst programs/*/deb/prerm programs/*/deb/postrm \
		programs/*/alpine/*.post-install programs/*/alpine/*.post-upgrade \
		programs/*/alpine/*.pre-deinstall programs/*/alpine/*.pre-install programs/*/package-test-extra.sh \
		programs/*/service-check.sh programs/*/freebsd/check-lib.sh programs/*/freebsd/*.rc \
		packaging/service/*/*

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

# Builds both sibling repositories with one set of throwaway keys. Separate from e2e because
# the build takes minutes and the test can be repeated against the same packages.
e2e-prepare:
	sh tests/prepare.sh

# Runs the setup script in a container of every system in tests/systems, against a site built
# from the packages of e2e-prepare and served over local HTTP. Needs docker.
e2e:
	sh tests/run.sh

# Runs the setup script as root in a virtual machine of every FreeBSD release in
# packaging/freebsd/releases, which has no Linux container. The machine runs under QEMU in the
# prepared image of its release (FREEBSD_IMAGE); this needs Docker and KVM (Linux on amd64), and
# a computer without /dev/kvm stops at once, because an emulated machine takes many times as
# long. FREEBSD=15.1 limits the run to one release.
.PHONY: e2e-freebsd
e2e-freebsd: freebsd-kvm
	LINUX_IMAGE=$(GO_IMAGE) FREEBSD_IMAGE=$(FREEBSD_IMAGE) FREEBSD=$(FREEBSD) tests/freebsd.sh

# --- The packages of a program ------------------------------------------------------------------
# The package definitions of each program are in programs/PROGRAM, with its program.conf. What is
# packaged is not built here:
#   PROGRAM   the program, a folder of programs/ (server).
#   BIN       the folder with the compiled programs, one folder <os>-<arch> for each system, each
#             holding the programs: the dist/bin of the program's build, or the unpacked release
#             archives.
#   SRC       the source tree of the program at this version. Its LICENSE and the documents named
#             in program.conf go into the packages; they change with every version.
#   VERSION   the version of the program, as it was released: v1.2.3 or v1.2.3-rc.1.
#   REVISION  the revision of the packages, 0 (the default) or more. A change to the packaging
#             alone, with the same release of the program, is packaged as the next revision of
#             that release: the way distributions number it (deb 1.2.3-1, rpm release 2, Alpine
#             -r1, FreeBSD 1.2.3_1). Revision 0 is named as the packages published before
#             revisions existed. scripts/package-lib.sh says how each format writes it.
# The packages are written to dist/PROGRAM: deb, rpm, and Alpine packages in alpine/<cpu>. SIGNING_DIR
# names a folder with the real signing keys (scripts/signing-keys.sh says which); without it throwaway
# keys are generated, and a package signed with them must never be published.
#
# The tools are in our images (ghcr.io/splicefs) and nothing of ours is: the repository is mounted
# into the image when a part runs, as the caller's own user, so that every file a part writes
# belongs to the caller and not to root. Every package format is built by its own distribution's
# tools in its own image, so a package built here is the package CI builds.
GO_IMAGE ?= ghcr.io/splicefs/go:v1
# The image of a FreeBSD release, which runs the FreeBSD machine of that release: a FreeBSD disk
# that has been booted once and has pkg set up (amd64 only), with QEMU. @RELEASE@ is where the
# release goes; the releases are listed in packaging/freebsd/releases.
FREEBSD_IMAGE ?= ghcr.io/splicefs/freebsd-@RELEASE@:v2
# Empty runs every release in the list; 15.1, for example, only that one.
FREEBSD ?=
RPM_IMAGE ?= ghcr.io/splicefs/rpm-build:v1
APK_IMAGE ?= ghcr.io/splicefs/apk-build:v1
PROGRAM ?=
BIN ?=
SRC ?=
VERSION ?=
REVISION ?= 0
# Alpine versions cannot carry a commit, so a build with uncommitted changes carries the date of
# its commit: here, of the commit of SRC.
PACKAGE_DATE ?= $(shell git -C "$(SRC)" log -1 --format=%cd --date=format:%Y%m%d 2>/dev/null || date +%Y%m%d)
PACKAGE_OUT = dist/$(PROGRAM)
# What the package scripts read, with the folders where the image sees BIN and SRC.
PACKAGE_VARS = PROGRAM=$(PROGRAM) VERSION=$(VERSION) PACKAGE_DATE=$(PACKAGE_DATE) REVISION=$(REVISION) BIN=/in/bin SRC=/in/src
# What the version record is written from.
RECORD_VARS = PROGRAM=$(PROGRAM) VERSION=$(VERSION) PACKAGE_DATE=$(PACKAGE_DATE) REVISION=$(REVISION)
# The signing keys, read only, for the steps that sign or check with them.
KEYS_MOUNT := -v "$(CURDIR)/dist/keys":/keys:ro
RUN_OPTS :=
DOCKER_RUN = docker run --rm --user "$(shell id -u):$(shell id -g)" $(RUN_OPTS) -v "$(CURDIR)":/repo -w /repo \
	-v "$(abspath $(BIN))":/in/bin:ro -v "$(abspath $(SRC))":/in/src:ro

.PHONY: packages package-deb package-rpm package-apk package-freebsd freebsd-kvm package-inputs keys

# The packages of every format. Each format is a target of its own. When all of them are built, the
# version they were built as is recorded in dist/PROGRAM/version, which is where the tests that
# follow read it (scripts/package-record.sh).
packages: package-deb package-rpm package-apk
	$(RECORD_VARS) sh -c '. scripts/package-record.sh && write_package_record'

# Stops at once, with the name of what is missing, before any image starts. Docker would make a
# folder that does not exist as root. A build removes the record of the version first, so that a
# build that stops half way never leaves a record that describes other packages than the ones in
# dist.
package-inputs:
	@: $(foreach v,PROGRAM BIN SRC VERSION,$(if $($(v)),,$(error $(v) is not set; see the comment above PROGRAM)))
	@for d in "$(BIN)" "$(SRC)" programs/"$(PROGRAM)"; do \
		[ -d "$$d" ] || { echo "FAIL: $$d is not a folder"; exit 1; }; \
	done
	mkdir -p "$(PACKAGE_OUT)"
	rm -f "$(PACKAGE_OUT)/version"

package-deb: package-inputs
	scripts/part.sh package-deb $(DOCKER_RUN) $(GO_IMAGE) env $(PACKAGE_VARS) sh scripts/package-deb.sh /repo/$(PACKAGE_OUT)

package-rpm: package-inputs
	scripts/part.sh package-rpm $(DOCKER_RUN) $(RPM_IMAGE) env $(PACKAGE_VARS) sh scripts/package-rpm.sh /repo/$(PACKAGE_OUT)

package-apk: RUN_OPTS = $(KEYS_MOUNT)
package-apk: package-inputs keys
	scripts/part.sh package-apk $(DOCKER_RUN) $(APK_IMAGE) env $(PACKAGE_VARS) sh scripts/package-apk.sh /repo/$(PACKAGE_OUT)

# FreeBSD cannot run in a container, so the FreeBSD packages are built, installed and checked in a
# virtual machine of each release in packaging/freebsd/releases (scripts/package-freebsd.sh). The
# machine is amd64: it builds the packages for amd64 and arm64, installs the amd64 one and proves
# its service steps (installed idle, turned on and started with the documented commands, an
# upgrade, a removal), and the arm64 package is checked from the file. It also signs the FreeBSD
# repositories (dist/PROGRAM/repo/freebsd) with the keys of make keys. It needs Docker and KVM; a
# computer without /dev/kvm stops at once. FREEBSD=15.1 limits the run to one release. It is not
# part of make packages because of that need. Like the other formats it takes PROGRAM, BIN
# (the freebsd-amd64 and freebsd-arm64 programs of it), SRC (only to date a build that is not a
# release: FreeBSD packages hold no documents) and VERSION, and it records the version the way
# make packages does.
package-freebsd: freebsd-kvm package-inputs keys
	scripts/part.sh package-freebsd env PROGRAM=$(PROGRAM) VERSION=$(VERSION) PACKAGE_DATE=$(PACKAGE_DATE) REVISION=$(REVISION) \
		BIN="$(abspath $(BIN))" KEYS_DIR="$(CURDIR)/dist/keys" LINUX_IMAGE=$(GO_IMAGE) FREEBSD_IMAGE=$(FREEBSD_IMAGE) FREEBSD=$(FREEBSD) \
		sh scripts/package-freebsd.sh $(PACKAGE_OUT)
	$(RECORD_VARS) sh -c '. scripts/package-record.sh && write_package_record'

# First in every target that starts a FreeBSD machine, so that a computer that cannot is found
# before anything is built.
freebsd-kvm:
	scripts/freebsd-require-kvm.sh

# Decides which keys everything is signed with and puts them in ./dist/keys.
keys:
	LINUX_IMAGE=$(GO_IMAGE) scripts/signing-keys.sh

# --- The tests of the packages of a program -----------------------------------------------------
# They test what make packages left in dist/PROGRAM, on the server images listed in
# packaging/test-systems, and read the version from the record make packages wrote there. They
# need Docker.
#   ONLY      limits a run to one format (ONLY=deb) or to one image, as written in
#             packaging/test-systems.
#   PLATFORM  linux/amd64 or linux/arm64 tests that CPU type by emulation; empty tests this
#             machine's own.
#   VERSION   not needed. When given, it must be the recorded version, or the test stops.
ONLY ?=
PLATFORM ?=
TEST_VARS = PROGRAM=$(PROGRAM) VERSION=$(VERSION) PLATFORM=$(PLATFORM) ONLY=$(ONLY)

.PHONY: built-packages package-order-test package-test

# Stops at once, with the name of what is missing, before any image starts.
built-packages:
	@: $(if $(PROGRAM),,$(error PROGRAM is not set; see the comment above PROGRAM))
	@ls "dist/$(PROGRAM)"/*.deb "dist/$(PROGRAM)"/*.rpm "dist/$(PROGRAM)"/alpine/*/*.apk >/dev/null 2>&1 || \
		{ echo "FAIL: no packages in dist/$(PROGRAM): run make packages first"; exit 1; }

# Checks in a Debian, a Rocky Linux and an Alpine system that the versions of the packages sort
# the way a release needs (a pre-release before its release) and that apk accepts them. It is a
# prerequisite of package-test, not of check, because it needs Docker.
package-order-test:
	scripts/package-order-test.sh

# Installs and removes the package in a clean, booted server of every system listed in
# packaging/test-systems and reports each system's result.
package-test: built-packages package-order-test
	$(TEST_VARS) scripts/package-test.sh

# Proves the service, not only the files: in a container per system that is booted as a server,
# with that system's own service manager as process 1, installs the package and checks that it
# is neither enabled nor running, then starts it with the documented commands and checks that it
# runs as its own user, does its job (what that means is in programs/PROGRAM/service-check.sh),
# restarts and comes back after a reboot. An upgrade restarts a running service and leaves a
# stopped one stopped; removing the package stops and disables it; a new install after that is
# idle again.
.PHONY: service-test
service-test: built-packages
	$(TEST_VARS) scripts/service-test.sh

# The part of the upgrade test that decides whether the packaging changed, checked against small
# hand-made package listings. It needs no Docker, so it is part of check.
.PHONY: upgrade-diff-test upgrade-test
upgrade-diff-test:
	scripts/upgrade-diff-test.sh

# Installs the newest published release of the program (downloaded from the releases of the
# repository named by release_repo in programs/PROGRAM/program.conf) in a clean, booted server of
# the first system of each format in packaging/test-systems, writes a configuration line and a data
# file, and installs the packages in dist/PROGRAM over it, the way a user upgrades. It checks that
# both survived, the service user exists, the new version is installed and every file the new
# package lists is there. It runs only for a format whose packaging changed since that release: a
# version that differs only in the programs and the changelog cannot break an upgrade. When the
# packaging changed and the version is the published one, the packages must be a later revision
# (make packages REVISION=N): the test says so when they are not. scripts/next-revision.sh prints
# the revision that follows the highest one published. It needs Docker and the network.
upgrade-test: built-packages
	$(TEST_VARS) scripts/upgrade-test.sh

# Signed package repositories in dist/PROGRAM/repo, made from the packages make packages left in
# dist/PROGRAM (it builds none). Keys come from scripts/signing-keys.sh, which is the one place
# that picks real or throwaway keys. Each format runs in the image of its own distribution's
# tools, with the keys mounted read-only.
REPO_RUN = docker run --rm --user "$(shell id -u):$(shell id -g)" $(KEYS_MOUNT) -v "$(CURDIR)":/repo -w /repo

.PHONY: repo repo-test
repo: built-packages keys
	scripts/part.sh repo-apt $(REPO_RUN) $(GO_IMAGE) sh scripts/repo-apt.sh /repo/dist/$(PROGRAM)
	scripts/part.sh repo-rpm $(REPO_RUN) $(RPM_IMAGE) sh scripts/repo-rpm.sh /repo/dist/$(PROGRAM)
	scripts/part.sh repo-apk $(REPO_RUN) $(APK_IMAGE) sh scripts/repo-apk.sh /repo/dist/$(PROGRAM)

# Installs from the repository on every system in packaging/test-systems with signature checks
# on, and checks that a damaged repository is refused.
repo-test: built-packages
	@[ -d "dist/$(PROGRAM)/repo" ] || { echo "FAIL: no repository in dist/$(PROGRAM)/repo: run make repo first"; exit 1; }
	$(TEST_VARS) scripts/package-test.sh repo

# --- Publishing the repositories of a program ---------------------------------------------------
# The release of a program (the publish-program workflow) publishes what make repo made in
# dist/PROGRAM/repo to the folder of the program on the package site. UPLOAD_KEY_FILE and
# UPLOAD_KNOWN_HOSTS_FILE (see scripts/publish-program.sh) come from the environment, so no secret
# is ever in this file.
.PHONY: program-fetch program-publish program-publish-check program-publish-test freebsd-pack freebsd-unpack

# Downloads what is published into dist/PROGRAM/repo first, so the repositories built next keep
# every older version.
program-fetch:
	scripts/publish-program.sh fetch

# The release builds the FreeBSD packages and publishes in different jobs. freebsd-pack puts what
# the FreeBSD job of one release (FREEBSD=15.1) merged into dist/PROGRAM/repo into one tar, and
# freebsd-unpack puts the tars of every release into the repository the publish job fetched
# (scripts/freebsd-parts.sh). VERSION is the version that make package-freebsd built; unpacking
# needs no version.
freebsd-pack:
	$(RECORD_VARS) scripts/freebsd-parts.sh pack $(PACKAGE_OUT) $(FREEBSD)

freebsd-unpack:
	scripts/freebsd-parts.sh unpack $(PACKAGE_OUT)

# Uploads dist/PROGRAM/repo, packages first, then the index files and their signatures. It
# refuses an incomplete repository and any upload that would delete a published package.
program-publish:
	scripts/publish-program.sh send

# Lists the remote folder of the program and changes nothing: proves that the key and host key work.
program-publish-check:
	scripts/publish-program.sh check

# Proves publish-program.sh against local folders and a throwaway key, with no server. It is part
# of check; this runs it alone.
program-publish-test:
	scripts/publish-program-test.sh

clean:
	rm -rf dist
