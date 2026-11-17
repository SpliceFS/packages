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
		programs/*/service-check.sh

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
# packaging/freebsd/images, which has no Linux container. The machine runs under QEMU inside
# LINUX_IMAGE; this needs Docker, curl and xz, nothing else. FREEBSD=15.1 limits the run to
# one release. Where the machine has to be emulated (any computer but Linux on amd64) a run
# takes many minutes.
LINUX_IMAGE ?= golang:1.27
FREEBSD ?=
.PHONY: e2e-freebsd
e2e-freebsd:
	LINUX_IMAGE=$(LINUX_IMAGE) FREEBSD=$(FREEBSD) tests/freebsd.sh

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
# The packages are written to dist/PROGRAM: deb, rpm, and Alpine packages in alpine/<cpu>. SIGNING_DIR
# names a folder with the real signing keys (scripts/signing-keys.sh says which); without it throwaway
# keys are generated, and a package signed with them must never be published.
#
# The tools are in our images (ghcr.io/splicefs) and nothing of ours is: the repository is mounted
# into the image when a part runs, as the caller's own user, so that every file a part writes
# belongs to the caller and not to root. Every package format is built by its own distribution's
# tools in its own image, so a package built here is the package CI builds.
GO_IMAGE ?= ghcr.io/splicefs/go:v1
RPM_IMAGE ?= ghcr.io/splicefs/rpm-build:v1
APK_IMAGE ?= ghcr.io/splicefs/apk-build:v1
PROGRAM ?=
BIN ?=
SRC ?=
VERSION ?=
# Alpine versions cannot carry a commit, so a build with uncommitted changes carries the date of
# its commit: here, of the commit of SRC.
PACKAGE_DATE ?= $(shell git -C "$(SRC)" log -1 --format=%cd --date=format:%Y%m%d 2>/dev/null || date +%Y%m%d)
PACKAGE_OUT = dist/$(PROGRAM)
# What the package scripts read, with the folders where the image sees BIN and SRC.
PACKAGE_VARS = PROGRAM=$(PROGRAM) VERSION=$(VERSION) PACKAGE_DATE=$(PACKAGE_DATE) BIN=/in/bin SRC=/in/src
# The signing keys, read only, for the steps that sign or check with them.
KEYS_MOUNT := -v "$(CURDIR)/dist/keys":/keys:ro
RUN_OPTS :=
DOCKER_RUN = docker run --rm --user "$(shell id -u):$(shell id -g)" $(RUN_OPTS) -v "$(CURDIR)":/repo -w /repo \
	-v "$(abspath $(BIN))":/in/bin:ro -v "$(abspath $(SRC))":/in/src:ro

.PHONY: packages package-deb package-rpm package-apk package-inputs keys

# The packages of every format. Each format is a target of its own.
packages: package-deb package-rpm package-apk

# Stops at once, with the name of what is missing, before any image starts. Docker would make a
# folder that does not exist as root.
package-inputs:
	@: $(foreach v,PROGRAM BIN SRC VERSION,$(if $($(v)),,$(error $(v) is not set; see the comment above PROGRAM)))
	@for d in "$(BIN)" "$(SRC)" programs/"$(PROGRAM)"; do \
		[ -d "$$d" ] || { echo "FAIL: $$d is not a folder"; exit 1; }; \
	done
	mkdir -p "$(PACKAGE_OUT)"

package-deb: package-inputs
	scripts/part.sh package-deb $(DOCKER_RUN) $(GO_IMAGE) env $(PACKAGE_VARS) sh scripts/package-deb.sh /repo/$(PACKAGE_OUT)

package-rpm: package-inputs
	scripts/part.sh package-rpm $(DOCKER_RUN) $(RPM_IMAGE) env $(PACKAGE_VARS) sh scripts/package-rpm.sh /repo/$(PACKAGE_OUT)

package-apk: RUN_OPTS = $(KEYS_MOUNT)
package-apk: package-inputs keys
	scripts/part.sh package-apk $(DOCKER_RUN) $(APK_IMAGE) env $(PACKAGE_VARS) sh scripts/package-apk.sh /repo/$(PACKAGE_OUT)

# Decides which keys everything is signed with and puts them in ./dist/keys.
keys:
	LINUX_IMAGE=$(GO_IMAGE) scripts/signing-keys.sh

# --- The tests of the packages of a program -----------------------------------------------------
# They test what make packages left in dist/PROGRAM, on the server images listed in
# packaging/test-systems, and take the PROGRAM and the VERSION that make packages was given (SRC
# as well when the version carries the date of its commit). They need Docker.
#   ONLY      limits a run to one format (ONLY=deb) or to one image, as written in
#             packaging/test-systems.
#   PLATFORM  linux/amd64 or linux/arm64 tests that CPU type by emulation; empty tests this
#             machine's own.
ONLY ?=
PLATFORM ?=
TEST_VARS = PROGRAM=$(PROGRAM) VERSION=$(VERSION) PACKAGE_DATE=$(PACKAGE_DATE) PLATFORM=$(PLATFORM) ONLY=$(ONLY)

.PHONY: built-packages test-inputs package-order-test package-test

# Stops at once, with the name of what is missing, before any image starts.
built-packages:
	@: $(if $(PROGRAM),,$(error PROGRAM is not set; see the comment above PROGRAM))
	@ls "dist/$(PROGRAM)"/*.deb "dist/$(PROGRAM)"/*.rpm "dist/$(PROGRAM)"/alpine/*/*.apk >/dev/null 2>&1 || \
		{ echo "FAIL: no packages in dist/$(PROGRAM): run make packages first"; exit 1; }

test-inputs: built-packages
	@: $(if $(VERSION),,$(error VERSION is not set; it is the version make packages was given))

# Checks in a Debian, a Rocky Linux and an Alpine system that the versions of the packages sort
# the way a release needs (a pre-release before its release) and that apk accepts them. It is a
# prerequisite of package-test, not of check, because it needs Docker.
package-order-test:
	scripts/package-order-test.sh

# Installs and removes the package in a clean, booted server of every system listed in
# packaging/test-systems and reports each system's result.
package-test: test-inputs package-order-test
	$(TEST_VARS) scripts/package-test.sh

# Proves the service, not only the files: in a container per system that is booted as a server,
# with that system's own service manager as process 1, installs the package and checks that the
# service starts by itself, runs as its own user, does its job (what that means is in
# programs/PROGRAM/service-check.sh), restarts, comes back after a reboot and stops when the
# package is removed.
.PHONY: service-test
service-test: test-inputs
	$(TEST_VARS) scripts/service-test.sh

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
repo-test: test-inputs
	@[ -d "dist/$(PROGRAM)/repo" ] || { echo "FAIL: no repository in dist/$(PROGRAM)/repo: run make repo first"; exit 1; }
	$(TEST_VARS) scripts/package-test.sh repo

clean:
	rm -rf dist
