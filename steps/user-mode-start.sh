# Your own folders, in your home directory: your cluster and its password.
config="${XDG_CONFIG_HOME:-$HOME/.config}/splicefs/client"
mkdir -p "$config/clusters.d" "$config/secrets" ~/files

# Your cluster. The file name is the cluster name.
cat > "$config/clusters.d/example.yaml" <<'EOF'
url: "https://east.example.com/api"
user: alice
password_file: secrets/example
EOF
(umask 077; cat > "$config/secrets/example")   # type the password, then Ctrl-D

# Start the client as yourself. It stays in the foreground: give it a terminal of its own.
splicefs
