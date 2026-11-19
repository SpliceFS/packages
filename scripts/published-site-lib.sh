# shellcheck shell=sh
# What the install tests (tests/run.sh, tests/freebsd.sh) share about where their setup script and
# packages come from. The word SOURCE (the Makefile) says:
#   built      the packages the branch built (make e2e-prepare), with throwaway keys and a setup
#              script built from the template of the branch.
#   published  the site on the web: its published setup script, its real keys and its published
#              packages. Nothing is built.
# scripts/install-source.sh says which one a run needs. Sourced after scripts/fetch-lib.sh.

# The package site on the web. PACKAGE_SITE is the same hook as in scripts/published-lib.sh.
published_url="${PACKAGE_SITE:-https://packages.splicefs.org}"

# Sets install_source to the word of SOURCE (built when there is none), and ends the caller for
# any other word.
check_install_source() {
    install_source="${SOURCE:-built}"
    case "$install_source" in
        built | published) ;;
        *)
            echo "SOURCE must be built or published, not '$install_source'" >&2
            exit 1
            ;;
    esac
}

# Makes the folder $1 the published site as the install tests use it: the published setup script,
# and the key files of the repository $2. The tests compare the keys the setup script installs
# with these, so a published script that carries other keys than the repository pins fails them.
# The folder is made new. Status 1 when the setup script could not be downloaded.
fetch_published_site() {
    rm -rf "$1"
    mkdir -p "$1/keys"
    fetch_site_file "$published_url/setup.sh" "$1/setup.sh" || return 1
    cp "$2/keys/splicefs.asc" "$2/keys/splicefs.rsa.pub" "$1/keys/"
}
