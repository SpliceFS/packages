# In a second terminal: mount the cluster in your folder, see it, read it, unmount it.
config=~/.config/splicefs/client
splicefsctl --config "$config" mount example:/ ~/files
splicefsctl --config "$config" status
ls ~/files
splicefsctl --config "$config" umount ~/files
