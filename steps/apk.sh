# Add the SpliceFS signing key:
apk add curl
curl --proto '=https' --tlsv1.2 -fsSL https://packages.splicefs.org/keys/splicefs.rsa.pub \
  -o /etc/apk/keys/splicefs.rsa.pub

# Add the repositories:
mkdir -p /etc/apk/repositories.d
printf '%s\n' https://packages.splicefs.org/server/alpine https://packages.splicefs.org/client/alpine \
  > /etc/apk/repositories.d/splicefs.list

# Update the package index, then install the server, the client, or both:
apk update
apk add splicefs-server    # the server
apk add splicefs-client    # the client
