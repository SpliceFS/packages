# Add the SpliceFS signing key:
sudo install -m 0755 -d /etc/pki/rpm-gpg
sudo curl -fsSL https://packages.splicefs.org/keys/splicefs.asc -o /etc/pki/rpm-gpg/RPM-GPG-KEY-splicefs
sudo chmod a+r /etc/pki/rpm-gpg/RPM-GPG-KEY-splicefs
sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-splicefs

# Add the repository:
sudo tee /etc/zypp/repos.d/splicefs.repo >/dev/null <<'EOF'
[splicefs-server]
name=SpliceFS server
baseurl=https://packages.splicefs.org/server/rpm/$basearch
enabled=1
autorefresh=1
gpgcheck=1
repo_gpgcheck=1
pkg_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-splicefs

[splicefs-client]
name=SpliceFS client
baseurl=https://packages.splicefs.org/client/rpm/$basearch
enabled=1
autorefresh=1
gpgcheck=1
repo_gpgcheck=1
pkg_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-splicefs
EOF

sudo zypper --non-interactive refresh splicefs-server splicefs-client
