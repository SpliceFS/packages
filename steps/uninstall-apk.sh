# Remove the packages, and the packages they needed that nothing else needs now:
apk del splicefs-server splicefs-client

# Delete the data, the logs and the configuration folder, then the user and its group:
rm -rf /var/lib/splicefs /etc/splicefs /var/log/splicefsd.log /var/log/splicefs.log
deluser splicefs

# Remove the repository and the signing key, with the setup script from step 1:
sh ~/splicefs-setup.sh --remove
