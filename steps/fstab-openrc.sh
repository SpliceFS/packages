echo 'example:/ /mnt/files splicefs _netdev,nofail 0 0' >> /etc/fstab
rc-update add fuse boot && rc-service fuse start
rc-update add netmount default && rc-service netmount start
