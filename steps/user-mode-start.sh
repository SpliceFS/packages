# Your own folders, all in your home directory: settings, the password and the cache.
config=~/.config/splicefs/client
mkdir -p "$config/conf.d" "$config/clusters.d" "$config/secrets" ~/files
printf 'cache:\n  dir: %s/.cache/splicefs\n' "$HOME" > "$config/conf.d/10-cache.yaml"

# Your cluster. The file name is the cluster name.
cat > "$config/clusters.d/example.yaml" <<'EOF'
url: "https://east.example.com/api"
user: alice
password_file: secrets/example
EOF
(umask 077; cat > "$config/secrets/example")   # type the password, then Ctrl-D

# Start the client as yourself. It stays in the foreground: give it a terminal of its own.
splicefs --config "$config"
