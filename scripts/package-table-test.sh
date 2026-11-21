#!/bin/sh
# check: package-lib.sh: the table of folders of each format says what the packaging definitions install
# The table of scripts/package-lib.sh says where each package format puts the programs, the
# configuration, the state and the service definition, and every check of the package test reads it.
# The definitions that make the packages (the deb builder, the rpm spec, the Alpine APKBUILD, the
# FreeBSD packing list and rc script, the service files) cannot read it, so this test finds each
# folder of the table in them. A folder that changed in one place and not the other fails here and
# not in a package test on a distribution. Runs on the host, no Docker (make package-table-test).
# What program.conf sets (name, program, programs) is unknown to ShellCheck, which cannot follow it.
# shellcheck disable=SC2154
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
failed=0

# $1 file, $2 text, $3 what it proves. The text must be in the file, as is.
holds() {
    if grep -qF -e "$2" "$1"; then
        printf 'ok   %s\n' "$3"
    else
        printf 'FAIL %s: %s does not hold "%s"\n' "$3" "$1" "$2"
        failed=$((failed + 1))
    fi
}

# Prints a fact of the table: $1 format, $2 program, $3 the variable.
table() {
    FORMAT="$1" PROGRAM="$2" VERSION=v1.2.3 PACKAGE_DATE=20261112 sh -c \
        '. scripts/package-lib.sh; eval "printf %s \"\$$1\""' sh "$3"
}

# Only the server keeps state of its own so far: the client's definitions name no state folder.
for program_name in server client; do
    defs="programs/$program_name"
    # The facts of the program, read the way the library reads them.
    # shellcheck source=/dev/null
    . "$defs/program.conf"
    folders="$(grep -v -e '^#' -e '^$' "$defs/config-folders")"

    for format in deb rpm apk pkg; do
        bindir="$(table "$format" "$program_name" bindir)"
        confdir="$(table "$format" "$program_name" confdir)"
        datadir="$(table "$format" "$program_name" datadir)"
        servicedir="$(table "$format" "$program_name" servicedir)"
        usrdir="$(table "$format" "$program_name" usrdir)"
        label="$format $program_name"
        case "$format" in
            deb)
                holds scripts/package-deb.sh "\$root${bindir}/\$built" "$label: programs in $bindir"
                holds scripts/package-deb.sh "\$root$servicedir/\$program.service" "$label: service definition in $servicedir"
                holds "$defs/deb/postrm" "rm -rf $confdir" "$label: purge removes $confdir"
                if [ "$program_name" = server ]; then
                    holds "$defs/systemd/$program.service" "$datadir" "$label: the unit names the state folder $datadir"
                fi
                ;;
            rpm)
                for each in $programs; do holds "$defs/rpm/$name.spec" "$bindir/$each" "$label: $each in $bindir"; done
                holds "$defs/rpm/$name.spec" "$servicedir/$program.service" "$label: service definition in $servicedir"
                holds "$defs/rpm/$name.spec" "%dir $confdir" "$label: configuration folder $confdir"
                for folder in $folders; do holds "$defs/rpm/$name.spec" "%dir $confdir/$folder" "$label: $confdir/$folder"; done
                ;;
            apk)
                for each in $programs; do holds "$defs/alpine/APKBUILD" "\$pkgdir$bindir/$each" "$label: $each in $bindir"; done
                holds "$defs/alpine/APKBUILD" "\$pkgdir$servicedir/$program" "$label: service definition in $servicedir"
                for folder in $folders; do holds "$defs/alpine/APKBUILD" "\$pkgdir$confdir/$folder" "$label: $confdir/$folder"; done
                holds "$defs/openrc/$program.initd" "command=$bindir/$program" "$label: the service runs $bindir/$program"
                if [ "$program_name" = server ]; then
                    holds "$defs/openrc/$program.initd" "$datadir" "$label: the service definition names the state folder $datadir"
                fi
                ;;
            pkg)
                plist="$(FORMAT=pkg PROGRAM="$program_name" VERSION=v1.2.3 PACKAGE_DATE=20261112 sh -c \
                    '. scripts/package-lib.sh; package_freebsd_plist')"
                for each in $programs; do
                    printf '%s\n' "$plist" | grep -qxF "${bindir#"$usrdir"/}/$each" ||
                        { printf 'FAIL %s: the packing list lacks %s\n' "$label" "${bindir#"$usrdir"/}/$each"; failed=$((failed + 1)); continue; }
                    printf 'ok   %s: %s in %s\n' "$label" "$each" "$bindir"
                done
                printf '%s\n' "$plist" | grep -qxF "${servicedir#"$usrdir"/}/$program" ||
                    { printf 'FAIL %s: the packing list lacks the service definition\n' "$label"; failed=$((failed + 1)); }
                printf '%s\n' "$plist" | grep -qxF "@dir ${confdir#"$usrdir"/}" ||
                    { printf 'FAIL %s: the packing list lacks %s\n' "$label" "$confdir"; failed=$((failed + 1)); }
                holds "$defs/freebsd/manifest.in" "prefix: \"$usrdir\"" "$label: the package prefix is $usrdir"
                holds "$defs/freebsd/$program.rc" "program=$bindir/$program" "$label: the rc script runs $bindir/$program"
                if [ "$program_name" = server ]; then
                    holds "$defs/freebsd/$program.rc" "statedir=$datadir" "$label: the rc script keeps its state in $datadir"
                fi
                ;;
            *) echo "FAIL the format $format has no case in this test"; failed=$((failed + 1)) ;;
        esac
    done
done

if [ "$failed" -ne 0 ]; then
    echo "$failed table check(s) failed"
    exit 1
fi
echo "ok   every folder of the table is in the packaging definitions"
