# Add the SpliceFS signing key:
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl --proto '=https' --tlsv1.2 -fsSL https://packages.splicefs.org/keys/splicefs.asc -o /etc/apt/keyrings/splicefs.asc
sudo chmod a+r /etc/apt/keyrings/splicefs.asc

# Add the repository to apt sources:
sudo tee /etc/apt/sources.list.d/splicefs.sources >/dev/null <<'EOF'
Types: deb
URIs: https://packages.splicefs.org/server/apt https://packages.splicefs.org/client/apt
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/splicefs.asc
EOF

# Update the package index, then install the server, the client, or both:
sudo apt-get update
sudo apt-get install splicefs-server    # the server
sudo apt-get install splicefs-client    # the client
