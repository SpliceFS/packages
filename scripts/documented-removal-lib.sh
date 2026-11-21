# shellcheck shell=sh
# The documented removal of a system as the test runs it, from the file of steps/ for that system:
# what is left out of it, and why. Sourced from the root of the repository by
# scripts/package-test-steps.sh and by the test of the sysrc lines (scripts/uninstall-sysrc-test.sh).

# The lines of the steps file $1 that delete the rc.conf setting of a service (sysrc -x NAME_enable)
# for the programs that are not in $2 (the programs whose service the test turned on, separated by
# spaces), one per line. Only a line the file has is printed. The steps tell a person to leave out
# the line of a service never turned on, because sysrc -x of an unset variable fails.
services_left_out() {
    for conf in programs/*/program.conf; do
        folder="${conf%/program.conf}"
        case " $2 " in
            *" ${folder##*/} "*) continue ;;
            *) ;;
        esac
        line="sysrc -x $(sed -n 's/^program=//p' "$conf")_enable"
        ! grep -qx "$line" "$1" || echo "$line"
    done
}

# The documented removal reads as the install page shows it, for both programs, and says "Leave out
# the one you did not install": its removal command names the packages in $2 (what the package
# manager still holds, separated by spaces) and the others are left out of it. With none named the
# command is left out whole: a package manager refuses a name it does not hold, and a command with
# no name does nothing. The line that deletes the setting of a service the test did not turn on
# (services_left_out, with the programs in $3) is left out too, as the steps say. The setup script's
# own removal is left out too: it removes the repository this test never set up. The commands of the
# sed are written to $own/removal.sed.
# shellcheck disable=SC2154 # the caller sets own
documented_removal_text() {
    {
        echo '/setup\.sh/d'
        for conf in programs/*/program.conf; do
            other="$(sed -n 's/^name=//p' "$conf")"
            case " $2 " in
                *" $other "*) ;;
                *)
                    if [ -n "$2" ]; then
                        echo "s/ $other\$//"
                        echo "s/ $other / /"
                    else
                        echo "/ $other\$/d"
                        echo "/ $other /d"
                    fi
                    ;;
            esac
        done
        services_left_out "$1" "$3" | while IFS= read -r line; do echo "/^$line\$/d"; done
    } >"$own/removal.sed"
    sed -f "$own/removal.sed" "$1"
}
