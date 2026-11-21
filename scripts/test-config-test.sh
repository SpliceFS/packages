#!/bin/sh
# check: programs/server/test-config.sh: the test configuration is written where the documentation says, and found when it is not
# Test of the test configuration of the server (programs/server/test-config.sh), which the package
# test writes in a system the package is installed in before it starts the service. Here the system
# is a folder, with stand-ins for the two commands that need the real system (splicefsdctl and
# chown), so the test needs no Docker and no root (part of make check). The user is made two ways,
# by the release that is installed: with splicefsdctl user add, which names the file by the user's
# id, or, before that command existed, as a file named by the user name. Every case runs for each.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failed=0

mkdir "$work/bin"
cat >"$work/bin/splicefsdctl" <<'STAND_IN'
#!/bin/sh
# Stands in for the splicefsdctl of the release that STAND_IN_RELEASE names: before-user-add (the
# command is unknown, so its --help fails), with-user-add, or broken-user-add (--help works, the
# command itself fails). The one line it is given stands in for the salt of the hash, as the
# real one prints it.
read_hash() {
    read -r password
    printf '$argon2id$v=19$stand-in-for-%s\n' "$password"
}
case "$*" in
    hash-password) read_hash ;;
    "user add --help") [ "$STAND_IN_RELEASE" != before-user-add ] ;;
    "user add "*)
        echo "splicefsdctl $*" >>"$STAND_IN_DIR/calls"
        [ "$STAND_IN_RELEASE" = with-user-add ] || exit 1
        shift 2
        # The one form of the command line that the test configuration may use.
        [ "$1" = --state ] && [ "$3" = --share ] || exit 2
        hash="$(read_hash)"
        id=0193f5c2-7d1e-7b2a-9c4d-5e6f7a8b9c0d
        printf 'name: %s\npassword_hash: %s\nshares: [%s]\ndisabled: false\n' "$5" "$hash" "$4" \
            >"$2/shared/users/$id.yaml"
        echo "$id"
        ;;
    *) exit 2 ;;
esac
STAND_IN
cat >"$work/bin/chown" <<'STAND_IN'
#!/bin/sh
echo "chown $*" >>"$STAND_IN_DIR/calls"
STAND_IN
chmod 755 "$work/bin/splicefsdctl" "$work/bin/chown"

# Runs the functions named by the arguments as the package test runs them in a system, with the
# folders of the system moved under $system, for the release $release. Prints what they print.
in_fake_system() {
    PATH="$work/bin:$PATH" STAND_IN_DIR="$system" STAND_IN_RELEASE="$release" PROGRAM=server \
        VERSION=v1.2.3 PACKAGE_DATE=20261112 SYSTEM="$system" sh -c '
        . scripts/package-lib.sh
        . programs/server/test-config.sh
        confdir="$SYSTEM/etc/splicefs/server"
        datadir="$SYSTEM/var/lib/splicefs/server"
        share_dir="$SYSTEM/srv/media"
        for each in "$@"; do "$each"; done' sh "$@" 2>&1
}

# $1 what is checked, then the command that must succeed.
expect() {
    name="$1"
    shift
    if "$@"; then
        printf 'ok   %s (%s)\n' "$name" "$release"
    else
        printf 'FAIL %s (%s)\n' "$name" "$release"
        failed=$((failed + 1))
    fi
}
has_line() { grep -qxF -e "$1" "$2"; }
# The function $1 fails in the fake system, and its message holds the text $2.
fails_saying() {
    # The status of in_fake_system is the answer, so set -e being off inside it changes nothing.
    # shellcheck disable=SC2310
    if said="$(in_fake_system "$1")"; then return 1; fi
    case "$said" in *"$2"*) return 0 ;; *) return 1 ;; esac
}
# Prints the user files of the state folder that name the user alice, none when there is none.
files_of_alice() { grep -lxF "name: alice" "$state/shared/users/"*.yaml || :; }

# The cases of every release: the share, the check of the configuration, and the removal.
cases_of_every_release() {
    expect "the share is a file of shares.d, named for the share, with the folder" \
        has_line "path: $system/srv/media" "$conf/shares.d/media.yaml"
    expect "the share folder holds the file the readers will see" has_line hello "$system/srv/media/hello.txt"
    expect "the settings folder gets no file: nothing in it is needed" sh -c "[ -z \"\$(ls -A '$conf/conf.d')\" ]"
    # The server must be able to write below shared/ (its keys and its node file), and to read the user.
    expect "the state folders it made belong to the service user" \
        has_line "chown -R splicefs $state/shared" "$system/calls"

    expect "a written configuration passes its check" in_fake_system check_test_config >/dev/null
    rm "$conf/shares.d/media.yaml"
    expect "a missing share file is found and named" fails_saying check_test_config "shares.d/media.yaml is missing"
    in_fake_system write_test_config >/dev/null
    rm "$state/shared/users/"*.yaml
    expect "a missing user file is found and named" fails_saying check_test_config "is the user alice"

    in_fake_system remove_test_data >/dev/null
    expect "the test data it made outside the package's folders is removed" sh -c "[ ! -e '$system/srv/media' ]"
}

# The user of a release that has no user add: a file named by the user name, with the hash.
cases_before_user_add() {
    # The dollar signs of the hash are the text of the file, so the quotes are single on purpose.
    # shellcheck disable=SC2016
    expect "the user is a file of the state folder named for the user, with the hash of the password" \
        has_line 'password_hash: "$argon2id$v=19$stand-in-for-secret"' "$state/shared/users/alice.yaml"
    expect "the user may use the share" has_line "shares: [media]" "$state/shared/users/alice.yaml"
    expect "user add is not run, the release has none" sh -c "! grep -q 'user add' '$system/calls'"
}

# The user of a release with user add: a file named by an id, found by the name inside it.
cases_with_user_add() {
    file="$(files_of_alice)"
    expect "the user is one file of the state folder" sh -c "[ -n '$file' ] && [ \$(echo '$file' | wc -l) -eq 1 ]"
    expect "no file is named by the user name" sh -c "[ ! -e '$state/shared/users/alice.yaml' ]"
    # The dollar signs of the hash are the text of the file, so the quotes are single on purpose.
    # shellcheck disable=SC2016
    expect "the user has the hash of the password" has_line 'password_hash: $argon2id$v=19$stand-in-for-secret' "$file"
    expect "the user may use the share" has_line "shares: [media]" "$file"
    expect "user add is given the state folder and the share" \
        has_line "splicefsdctl user add --state $state --share media alice" "$system/calls"
}

# A user add that fails stops the writing, with its name.
cases_broken_user_add() {
    expect "a failed user add is found and named" fails_saying write_test_config "splicefsdctl user add failed"
}

# Writes the configuration in the system of the release $1, then runs the cases of that release.
run_release() {
    release="$1"
    system="$work/$release"
    conf="$system/etc/splicefs/server"
    state="$system/var/lib/splicefs/server"
    mkdir -p "$conf/conf.d" "$conf/shares.d"
    case "$release" in
        broken-user-add) cases_broken_user_add ;;
        *)
            # The status of in_fake_system is the answer, so set -e being off inside it changes nothing.
            # shellcheck disable=SC2310
            in_fake_system write_test_config >"$work/out" || { cat "$work/out"; failed=$((failed + 1)); }
            "cases_$(echo "$release" | tr - _)"
            cases_of_every_release
            ;;
    esac
}

run_release before-user-add
run_release with-user-add
run_release broken-user-add

if [ "$failed" -ne 0 ]; then
    echo "$failed test-config case(s) failed"
    exit 1
fi
echo "test-config: all cases as expected"
