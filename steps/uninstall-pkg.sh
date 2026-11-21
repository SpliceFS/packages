# Remove the packages. Leave out the one you did not install:
pkg delete splicefs-server splicefs-client

# Delete the settings of the services from /etc/rc.conf, which removing a package leaves alone.
# Leave out the line of a service you never turned on:
sysrc -x splicefsd_enable
sysrc -x splicefs_enable

# Remove the packages they needed that nothing else needs now:
pkg autoremove

# Delete the data, the logs and the configuration folder, then the user and its group:
rm -rf /var/db/splicefs /usr/local/etc/splicefs /var/log/splicefsd.log /var/log/splicefs.log
pw userdel splicefs

# Remove the repository and the signing key, with the setup script from step 1:
sh ~/splicefs-setup.sh --remove
