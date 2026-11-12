.PHONY: site check clean

site:
	sh scripts/build-site.sh

check: site
	sh scripts/check.sh

clean:
	rm -rf dist
