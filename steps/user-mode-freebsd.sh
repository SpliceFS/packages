sysctl vfs.usermount=1
echo 'vfs.usermount=1' >> /etc/sysctl.conf
sysrc kld_list+=fusefs && kldload fusefs
pw groupmod operator -m alice
printf '[fuse_users=10]\nadd path fuse mode 0660 group operator\n' >> /etc/devfs.rules
sysrc devfs_system_ruleset=fuse_users && service devfs restart
