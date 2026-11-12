.PHONY: site check lint clean

site:
	sh scripts/build-site.sh

check: site
	sh scripts/check.sh

# Static analysis of every shell file. The built script is analyzed, not the template,
# because the template still holds the key placeholders.
lint: site
	shellcheck --shell=sh dist/site/install.sh steps/*.sh scripts/*.sh

clean:
	rm -rf dist
