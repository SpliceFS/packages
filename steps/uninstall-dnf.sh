# Remove the packages. Leave out the one you did not install:
sudo dnf remove splicefs-server splicefs-client

# Remove the packages they needed that nothing else needs now:
sudo dnf autoremove

# Delete the data and the configuration folder, then the user and its group:
sudo rm -rf /var/lib/splicefs /etc/splicefs
sudo userdel splicefs

# Remove the repository and the signing key, with the setup script from step 1:
sudo sh ~/splicefs-setup.sh --remove
