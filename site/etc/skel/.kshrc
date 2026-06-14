# .kshrc -- velo homely interactive ksh rc (sourced via $ENV).

case "$-" in
*i*) : ;;
*) return 0 2>/dev/null || exit 0 ;;
esac

export LANG=en_US.UTF-8
export LC_CTYPE=en_US.UTF-8

set -o emacs
HISTFILE=$HOME/.ksh_history
HISTSIZE=8192

PS1='\u@\h:\w\$ '

alias ll='ls -lh'
alias la='ls -lha'
alias ..='cd ..'
alias grep='grep --color=auto 2>/dev/null || grep'