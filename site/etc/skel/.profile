# .profile -- velo skel (copied into each new user's home by useradd).
# POSIX sh / ksh login shell rc.

PATH=$HOME/bin:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:/usr/X11R6/bin
export PATH

umask 077

export ENV=$HOME/.kshrc
export PAGER=less
export EDITOR=vi
export LANG=en_US.UTF-8
export LC_CTYPE=en_US.UTF-8