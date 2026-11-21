# shellcheck shell=sh
# What the test configurations of the programs (programs/PROGRAM/test-config.sh) share, so that each
# fact is written once: the share and the user the server serves, which the client mounts and logs
# in with, and the folders a test configuration makes, which the test takes away again. Sourced inside
# a system the packages are installed in, from the root of the repository, after scripts/package-lib.sh.
# shellcheck disable=SC2034 # the test configurations that source this file read the names

share_name=media
share_file=hello.txt
share_text=hello
user_name=alice
user_password=secret
# The folder the documentation mounts a share at (mount -t splicefs east:/media /mnt/media): the test's own,
# so the test configuration of the client takes it away again.
mount_target=/mnt/media
# The default listener of the server, which a cluster url of the client names (docs/configuration.md).
server_port=8480
server_api_path=/api

# The file that lists the folders write_test_config made, for the program of the test. It is in the
# folder the package test keeps its own files in, which the removal of the package leaves alone and the
# comparison of the snapshots leaves out.
made_folders_file() {
    echo "${PACKAGE_TEST_OUT:?PACKAGE_TEST_OUT is not set}/made-folders.${PROGRAM:?PROGRAM is not set}"
}

# Prints the folder $1 and every folder above it that does not exist yet, the deepest first, which is
# the order they are taken away in.
missing_folders() {
    folder="$1"
    while [ ! -d "$folder" ]; do
        echo "$folder"
        folder="$(dirname "$folder")"
    done
}

# Makes the folder $1 and notes which folders that made. Appended, so that a second call, which finds the
# folders there, does not forget what the first one made.
make_test_folder() {
    missing_folders "$1" >>"$(made_folders_file)"
    mkdir -p "$1"
}

# Takes away the folders make_test_folder made, the deepest first. A folder that was there stays, and so
# does anything in a folder above that the test did not put there: rmdir refuses a folder that is not empty.
remove_made_folders() {
    made_file="$(made_folders_file)"
    [ -f "$made_file" ] || return 0
    while IFS= read -r made; do
        [ ! -d "$made" ] || rmdir "$made" || return 1
    done <"$made_file"
}
