# Add the SpliceFS signing key:
wget -q https://packages.splicefs.org/keys/splicefs.rsa.pub -O /etc/apk/keys/splicefs.rsa.pub

# Add the repositories:
mkdir -p /etc/apk/repositories.d
printf '%s\n' https://packages.splicefs.org/server/alpine https://packages.splicefs.org/client/alpine \
  > /etc/apk/repositories.d/splicefs.list
apk update
