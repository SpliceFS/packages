#!/bin/sh
# check: changed-groups.sh: the test groups the changed files of a pull request need, and the groups the workflows ask for
# Test of scripts/changed-groups.sh (part of make check): the test groups that the changed paths
# of a pull request need, read from the real .github/test-groups, and that every group a workflow
# asks for is a group of that file and the other way round. A misspelt group in the if of a job
# would skip that job on every pull request without a word. Runs on the host.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/changed-groups.sh"
failed=0
everything='["apk","deb","freebsd","install","rpm"]'
formats='["apk","deb","freebsd","rpm"]'

# $1 case name, $2 the output wanted, $3 the changed paths, one per line.
groups() {
    got="$(printf '%s' "$3" | sh "$script")" || { got="exit status $?"; }
    if [ "$got" = "$2" ]; then
        printf 'ok   %s\n' "$1"
    else
        printf 'FAIL %s: wanted %s got %s\n' "$1" "$2" "$got"
        failed=$((failed + 1))
    fi
}

groups "no changed path needs no group" '[]' ''
groups "documents only: the checks alone" '[]' 'README.md
CONTRIBUTING.md
CHANGELOG.md
SECURITY.md
LICENSE
.github/PULL_REQUEST_TEMPLATE.md
'
groups "the install page only: the checks alone" '[]' 'site/index.html
'
groups "the files make check alone reads" '[]' '.gitignore
.shellcheckrc
sonar-project.properties
.github/dependabot.yml
'
groups "a document in a folder with a space" '[]' 'notes dir/plan.md
'
groups "the install tests only" '["install"]' 'tests/run.sh
'
groups "the install tests and a document" '["install"]' 'tests/systems
README.md
'
groups "the setup script is tested by the install tests alone, which build no package" '["install"]' 'setup.sh.in
'
groups "the workflow of the install tests" '["install"]' '.github/workflows/install-tests.yml
'
groups "a deb only change" '["deb"]' 'programs/server/deb/control
scripts/package-deb.sh
scripts/repo-test-deb.sh
'
groups "an rpm only change" '["rpm"]' 'programs/client/rpm/splicefs-client.spec
scripts/repo-rpm.sh
'
groups "an Alpine only change" '["apk"]' 'programs/server/alpine/APKBUILD
scripts/apk-resign.sh
'
groups "a FreeBSD only change" '["freebsd"]' 'programs/server/freebsd/manifest.in
packaging/freebsd/releases
'
groups "a unit of systemd is in the deb and rpm packages" '["deb","rpm"]' 'programs/server/systemd/splicefsd.service
'
groups "a deb change and an rpm change" '["deb","rpm"]' 'scripts/package-deb.sh
scripts/package-rpm.sh
'
groups "the test systems are the ones of the Linux formats" '["apk","deb","rpm"]' 'packaging/test-systems
'
groups "a document of a program is packaged" "$formats" 'programs/server/README.md
'
groups "a script every format uses" "$formats" 'scripts/package-lib.sh
'
groups "the Makefile" "$formats" 'Makefile
'
groups "a workflow" "$formats" '.github/workflows/ci.yml
'
groups "an action" "$formats" '.github/actions/release-keys/action.yml
'
groups "the list of test groups itself" "$formats" '.github/test-groups
'
groups "a manual step every format runs" "$formats" 'steps/apt.sh
'
groups "a published key, which proves the release archives" "$formats" 'keys/splicefs.asc
'
groups "an unknown top level file needs everything" "$everything" 'notes.txt
'
groups "an unknown folder needs everything" "$everything" 'newdir/file.sh
'
groups "an unknown path next to a document still needs everything" "$everything" 'README.md
newdir/file
'
groups "a last line without a newline is read" "$formats" 'README.md
Makefile'

got="$(sh "$script" all)" || got="exit status $?"
if [ "$got" = "$everything" ]; then
    printf 'ok   all: every group, for the runs that are not pull requests\n'
else
    printf 'FAIL all: wanted %s got %s\n' "$everything" "$got"
    failed=$((failed + 1))
fi

if sh "$script" every </dev/null >/dev/null 2>&1; then
    printf 'FAIL an unknown argument is refused\n'
    failed=$((failed + 1))
else
    printf 'ok   an unknown argument is refused\n'
fi

# The groups the workflows ask for, from the if of each job, against the groups of the file.
# The Linux formats are read through the formats output of changes.yml, which names them in a jq filter.
asked="$({
    grep -ho "outputs.groups), '[^']*')" "$root"/.github/workflows/*.yml | sed "s/.*'\(.*\)'.*/\1/"
    sed -n 's/.*select(IN(\([^)]*\))).*/\1/p' "$root/.github/workflows/changes.yml" | tr -d '" ' | tr ',' '\n'
} | LC_ALL=C sort -u | tr '\n' ' ')"
known="$(sh "$script" all | tr -d '[]"' | tr ',' ' ') "
if [ "$asked" = "$known" ]; then
    printf 'ok   the workflows ask for exactly the groups of .github/test-groups\n'
else
    printf 'FAIL the workflows ask for "%s", .github/test-groups has "%s"\n' "$asked" "$known"
    failed=$((failed + 1))
fi

[ "$failed" -eq 0 ] || { echo "$failed check(s) failed"; exit 1; }
echo "changed-groups checks done"
