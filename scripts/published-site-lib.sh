# shellcheck shell=sh
# What the install tests (tests/run.sh, tests/freebsd.sh) share: they run the setup script and the
# packages of the site on the web, with its published setup script, its real keys and its
# published packages. Nothing is built. Sourced after scripts/fetch-lib.sh.

# The package site on the web. PACKAGE_SITE is the same hook as in scripts/published-lib.sh.
published_url="${PACKAGE_SITE:-https://packages.splicefs.org}"

# Makes the folder $1 the published site as the install tests use it: the published setup script,
# and the key files of the repository $2. The tests compare the keys the setup script installs
# with these, so a published script that carries other keys than the repository pins fails them.
# The folder is made new. Ends the caller when the setup script cannot be downloaded: a run
# without it says nothing about the site.
# A function in an || list has set -e off, and nothing here depends on it.
# shellcheck disable=SC2310
fetch_published_site() {
    rm -rf "$1"
    mkdir -p "$1/keys"
    fetch_site_file "$published_url/setup.sh" "$1/setup.sh" || {
        echo "could not download $published_url/setup.sh" >&2
        exit 1
    }
    cp "$2/keys/splicefs.asc" "$2/keys/splicefs.rsa.pub" "$1/keys/"
}
