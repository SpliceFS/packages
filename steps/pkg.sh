# Add the SpliceFS signing key:
mkdir -p /usr/local/etc/pkg/keys
fetch -o /usr/local/etc/pkg/keys/splicefs.rsa.pub https://packages.splicefs.org/keys/splicefs.rsa.pub

# Add the repositories:
mkdir -p /usr/local/etc/pkg/repos
cat > /usr/local/etc/pkg/repos/splicefs.conf <<'EOF'
splicefs-server: {
  url: "https://packages.splicefs.org/server/freebsd/${ABI}",
  mirror_type: "none",
  signature_type: "pubkey",
  pubkey: "/usr/local/etc/pkg/keys/splicefs.rsa.pub",
  enabled: yes
}
splicefs-client: {
  url: "https://packages.splicefs.org/client/freebsd/${ABI}",
  mirror_type: "none",
  signature_type: "pubkey",
  pubkey: "/usr/local/etc/pkg/keys/splicefs.rsa.pub",
  enabled: yes
}
EOF

# Update the package index, then install the server, the client, or both:
pkg update
pkg install splicefs-server    # the server
pkg install splicefs-client    # the client
