# Remove the packages, and the packages they needed that nothing else needs now. Leave out the one you did not install:
sudo zypper remove --clean-deps splicefs-server splicefs-client

# Delete the data and the configuration folder, then the user and its group:
sudo rm -rf /var/lib/splicefs /etc/splicefs
sudo userdel splicefs

# Remove the repository and the signing key, with the setup script from step 1:
sudo sh ~/splicefs-setup.sh --remove
