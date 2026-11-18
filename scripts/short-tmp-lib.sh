# shellcheck shell=sh
# Sourced by the tests that make gpg keys or signatures.
#
# gpg reaches its agent over a socket in the home folder, and the path of a socket is limited to
# about 100 characters. Where the temporary folder is long (macOS gives every user one) a home in
# it is too deep, and gpg waits ten seconds for an agent it cannot reach, once for every home.
# A test that makes keys or signatures keeps its homes in a folder from short_tmp_dir.

# Prints a new folder with a short path, whatever TMPDIR says. Like every mktemp -d folder it is
# private to the user.
short_tmp_dir() {
    mktemp -d /tmp/sfgpg.XXXXXX
}

# Stops the gpg agent of the folder $1 and of every folder in it, then removes it. An agent whose
# home is only removed keeps running until it notices.
remove_short_tmp() {
    for st_home in "$1" "$1"/*/; do
        [ -d "$st_home" ] || continue
        gpgconf --homedir "${st_home%/}" --kill gpg-agent >/dev/null 2>&1 || true
    done
    rm -rf "${1:?}"
}
