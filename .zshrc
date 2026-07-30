# ---- Options ----
setopt autocd extendedglob notify
setopt hist_ignore_dups hist_ignore_space share_history

# ---- Completions ----
autoload -Uz compinit
compinit
zstyle ':completion:*' menu select
bindkey '^[[Z' reverse-menu-complete

# ---- History ----
HISTSIZE=10000
SAVEHIST=10000
HISTFILE="$HOME/.zsh_history"

# ---- Source aliases ----
[ -f "$HOME/.config/aliases" ] && . "$HOME/.config/aliases"

# ---- Zoxide (smart cd) ----
eval "$(zoxide init zsh)"


