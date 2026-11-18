#!/bin/sh
# Fails when a script sources a file that does not exist, and names the script, the line and the
# file. Run from the top folder of the repository, by scripts/check.sh; needs git and awk.
#
# Why here and not in the scripts: a shell cannot always be trusted to stop on a missing
# library. On macOS, /bin/sh (bash 3.2) can end a script with status 0 after a failed
# ". library" under set -e and an EXIT trap, even with ". library || exit 1"; dash and bash 5
# stop. Guarding every line would repeat each path, and ShellCheck does not follow
# "command ." at all, so the sourcing lines stay plain and the files they name are proven to
# exist here, once, from the text of the repository.
#
# A script that tests a path with -f before it sources the path says by itself what a missing
# file means, so that path may be missing. The paths a script is handed at run time (its first
# argument, and the two named in the awk program below) and the paths outside the repository
# (system files) are not read.
set -eu

# What can stand before the "." of a sourcing line: the start of a line, the end of a command,
# an opening parenthesis or brace, a quote, or then, do, else.
quote="'"
sourcing="(^|[;&|({${quote}]|[[:space:]](then|do|else))[[:space:]]*[.][[:space:]]+"
sourcing="${sourcing}(\"[^\"]*\"|${quote}[^${quote}]*${quote}|[^[:space:];|&)${quote}\"]+)"

# The variables a path can hold, written out. root and here are worked out by the awk program.
defs=""
for conf in programs/*/program.conf; do
    if [ -f "$conf" ]; then defs="$defs ${conf%/program.conf}"; fi
done
formats=""
if [ -f packaging/test-systems ]; then
    while read -r format _; do
        case "$format" in
            "" | "#"*) continue ;;
            *) ;;
        esac
        case " $formats " in
            *" $format "*) ;;
            *) formats="$formats $format" ;;
        esac
    done < packaging/test-systems
fi

# Reads "file:line:text" lines and writes "file:line<TAB>path as written<TAB>file it can name",
# one line for each file a sourcing line can name, or "?" when no file can be told.
# shellcheck disable=SC2016 # the dollar signs are for awk and for the paths it reads
paths() {
    awk -v sourcing="$sourcing" -v defs="$defs" -v formats="$formats" '
        BEGIN {
            OFS = "\t"
            values["defs"] = defs
            values["format"] = formats
            split("defs format", names, " ")
            runtime["$in/check-lib.sh"] = runtime["$OS_RELEASE"] = 1
        }
        # Writes out the first use of $name in each of the paths, once for every value.
        function expand(name, count,    next_count, i, k, n, found, value) {
            next_count = 0
            for (i = 1; i <= count; i++) {
                if (!match(list[i], "[$]" name "([^A-Za-z0-9_]|$)") || values[name] == "") {
                    kept[++next_count] = list[i]
                    continue
                }
                found = RSTART
                n = split(values[name], value, " ")
                for (k = 1; k <= n; k++) {
                    kept[++next_count] = substr(list[i], 1, found - 1) value[k] substr(list[i], found + length(name) + 1)
                }
            }
            for (i = 1; i <= next_count; i++) list[i] = kept[i]
            return next_count
        }
        {
            file = $0
            sub(/:.*/, "", file)
            line = substr($0, length(file) + 2)
            number = line
            sub(/:.*/, "", number)
            text = substr(line, length(number) + 2)
            if (text ~ /^[[:space:]]*#/) next
            here = file
            if (!sub(/\/[^\/]*$/, "", here)) here = "."
            while (match(text, sourcing)) {
                found = substr(text, RSTART, RLENGTH)
                text = substr(text, RSTART + RLENGTH)
                sub(/^.*[.][[:space:]]+/, "", found)
                written = found
                gsub(/^"|"$/, "", found)
                if (found ~ /^\// || found ~ /^[$]1(\/|$)/ || (found in runtime)) continue
                gsub(/[$]root\//, "", found)
                gsub(/[$]here/, here, found)
                list[1] = found
                count = 1
                for (j = 1; j in names; j++) count = expand(names[j], count)
                for (i = 1; i <= count; i++) {
                    print file ":" number, written, (list[i] ~ /[$]/ ? "?" : list[i])
                }
            }
        }'
}

tab="$(printf '\t')"
status=0
# git grep reads the files in one pass: those git does not ignore, tracked or not, so that a new
# script is read before it is added. It exits 1 when nothing matches.
hits="$(git grep --no-index --exclude-standard -I -n --no-color -E -e "$sourcing" || [ $? -eq 1 ])"
list="$(printf '%s\n' "$hits" | paths)"
while IFS="$tab" read -r where written named; do
    [ -n "$where" ] || continue
    if [ "$named" = "?" ]; then
        echo "$where: cannot tell which file $written is; name it in scripts/sourced-files.sh"
        status=1
    elif [ ! -f "$named" ] && ! grep -F -q -e "-f $written" "${where%%:*}"; then
        echo "$where: sources $named, which does not exist"
        status=1
    fi
done <<EOF
$list
EOF
[ "$status" -eq 0 ] || exit 1
echo "every sourced file exists"
