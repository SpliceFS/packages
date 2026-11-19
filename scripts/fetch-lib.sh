# shellcheck shell=sh
# How the scripts that read the package site download a file (scripts/published-lib.sh and the
# install tests, scripts/published-site-lib.sh). The download insists on HTTPS, also after a
# redirect, so that a redirect can never hand over a file from a plain address.

# Downloads the address $1 into the file $2. It is written under another name first, so an
# interrupted download is never mistaken for the file. Status 1 when the download failed.
fetch_site_file() {
    if ! curl -fsSL --proto =https --proto-redir =https --retry 3 -o "$2.part" "$1" ||
        ! mv "$2.part" "$2"; then
        rm -f "$2.part"
        return 1
    fi
}
