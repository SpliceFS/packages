.PHONY: site check lint e2e-prepare e2e clean

site:
	sh scripts/build-site.sh

check: site
	sh scripts/check.sh

# Static analysis of every shell file. The built script is analyzed, not the template,
# because the template still holds the key placeholders.
lint: site
	shellcheck --shell=sh dist/site/install.sh steps/*.sh scripts/*.sh tests/*.sh

# Builds both sibling repositories with one set of throwaway keys and assembles the site the
# end to end test serves. Separate from e2e because the build takes minutes and the test
# can be repeated against the same site.
e2e-prepare:
	sh tests/prepare.sh

# Runs the install script in a container of every system in tests/systems, against the site
# from e2e-prepare, served over local HTTP. Needs docker.
e2e:
	sh tests/run.sh

clean:
	rm -rf dist
