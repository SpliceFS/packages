.PHONY: site check lint sign publish publish-check e2e-prepare e2e clean

site:
	sh scripts/build-site.sh

check: site
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

clean:
	rm -rf dist
