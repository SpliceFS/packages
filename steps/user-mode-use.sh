# In a second terminal: mount the cluster in your folder, see it, read it, unmount it.
splicefsctl mount example:/ ~/files
splicefsctl status
ls ~/files
cat ~/files/media/hello.txt   # a file of your cluster
splicefsctl umount ~/files
