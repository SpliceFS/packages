# shellcheck shell=sh
# The messages a package prints when it is installed, upgraded or removed (pkg only: deb, rpm and apk
# print none), checked against the text in the package's own manifest. The one source of that text is the
# manifest of the package file that was installed or removed (+MANIFEST in the package, which pkg create
# wrote as JSON), so the check cannot drift from what the package says. Sourced by
# scripts/package-test-steps.sh after scripts/package-lib.sh, which provides fail and $format.
# shellcheck disable=SC2154

# Prints the text of the message of the type $2 (install, upgrade or remove) in the manifest of the
# package file $1, one line each with the white space around it taken off and no empty line, and ends
# with status 1 when the manifest has no such message. The manifest lists its messages as objects with
# the strings "message" and "type"; the reader does not depend on their order or on the white space
# between them, and unescapes the JSON string escapes (\n, \t, \", \\ and \/).
package_message() {
    tar -xOf "$1" +MANIFEST | awk -v want="$2" '
        { doc = doc $0 "\n" }
        # Reads the string whose opening quote is at pos, leaves pos after its closing quote.
        function read_string(   out, c) {
            pos++
            out = ""
            while (pos <= n) {
                c = substr(doc, pos, 1)
                if (c == "\"") { pos++; return out }
                if (c == "\\") {
                    pos++
                    c = substr(doc, pos, 1)
                    if (c == "n") c = "\n"
                    else if (c == "t") c = "\t"
                    else if (c == "r") c = ""
                }
                out = out c
                pos++
            }
            return out
        }
        # Reads the object whose opening brace is at pos and prints its lines when its type is the one wanted.
        function read_message(   key, value, text, kind, lines, i, line) {
            kind = "always"
            pos++
            while (pos <= n && substr(doc, pos, 1) != "}") {
                if (substr(doc, pos, 1) != "\"") { pos++; continue }
                key = read_string()
                while (pos <= n && substr(doc, pos, 1) != "\"") pos++
                value = read_string()
                if (key == "message") text = value
                else if (key == "type") kind = value
            }
            pos++
            if (kind != want) return
            lines = split(text, parts, "\n")
            for (i = 1; i <= lines; i++) {
                line = parts[i]
                gsub(/^[ \t]+|[ \t]+$/, "", line)
                if (line != "") { print line; found = 1 }
            }
        }
        END {
            n = length(doc)
            pos = index(doc, "\"messages\"")
            if (pos == 0) exit 1
            while (pos <= n && substr(doc, pos, 1) != "[") pos++
            pos++
            while (pos <= n && substr(doc, pos, 1) != "]") {
                if (substr(doc, pos, 1) == "{") read_message()
                else pos++
            }
            exit found ? 0 : 1
        }'
}

# Checks that what the package printed, which is in the file $2, holds the message of the type $1 of
# the manifest of the package file $3: every line of it, and the command that message names, which
# message_command of the adapter of the format says (it is the command the steps run or the documented
# one). Formats that print no messages have nothing to check.
check_package_message() {
    [ "$format" = pkg ] || return 0
    expected="$own/message-$1"
    package_message "$3" "$1" >"$expected" || fail "the manifest of $3 holds no $1 message"
    while IFS= read -r line; do
        grep -qF -e "$line" "$2" || fail "what the package printed does not hold the line of its $1 message: $line"
    done <"$expected"
    command_named="$(message_command "$1")"
    grep -qF -e "$command_named" "$expected" || fail "the $1 message in the manifest of $3 does not name the command: $command_named"
    echo "ok: the package printed its $1 message, as its manifest says"
}
