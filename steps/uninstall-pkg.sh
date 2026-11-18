# Remove the packages:
pkg delete splicefs-server splicefs-client

# Delete the settings of the services from /etc/rc.conf, which removing a package leaves alone:
sysrc -x splicefsd_enable
sysrc -x splicefs_enable

# Remove the packages they needed that nothing else needs now:
pkg autoremove

# Delete the data and the configuration folder, then the user and its group:
rm -rf /var/db/splicefs /usr/local/etc/splicefs
pw userdel splicefs

# Remove the repository and the signing key, with the setup script from step 1:
sh ~/splicefs-setup.sh --remove
