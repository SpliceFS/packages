#!/bin/sh
# Ends with an error that names every variable of the environment that is empty or not set.
# The jobs of a release call it first, with the secrets they hold as variables, so that a secret
# that was never added to the publish environment is said at once, by name, and not as a failure
# of gpg or ssh later. Prints only names, never a value. Usage: require-env.sh NAME ...
set -eu

[ "$#" -gt 0 ] || { echo "usage: require-env.sh NAME ..." >&2; exit 2; }
missing=0
for var in "$@"; do
    # The name is ours, so eval reads one variable and nothing else.
    eval "value=\"\${$var:-}\""
    if [ -z "$value" ]; then
        echo "::error::$var is empty or not set; add it to the environment publish of this repository"
        missing=$((missing + 1))
    fi
done
[ "$missing" -eq 0 ]
