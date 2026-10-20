# ====================================================================
# INTERACTIVE SHELL SETUP FOR THE GENERATED ENVIRONMENT
# --------------------------------------------------------------------
# Author : Angel Vera Herrera
# --------------------------------------------------------------------
# ====================================================================
#
# rcfile of the interactive shell. The launcher runs
#     cmd -> msys2_shell.cmd -> bash -lc '. <bootstrap>; exec bash'
# and `exec` keeps only exported variables: completions and key bindings
# set by the bootstrap are lost, and the final shell is not a login shell
# (no /etc/profile, so no bash-completion). This file restores both.
# ~/.bashrc is still sourced first ($HOME is shared by every MSYS2).
# ====================================================================

# --------------------------------------------------------------------
# 1. Whatever the developer already had
# --------------------------------------------------------------------
if [ -r "${HOME}/.bashrc" ]; then
    # shellcheck disable=SC1091
    . "${HOME}/.bashrc"
fi

# --------------------------------------------------------------------
# 2. bash-completion
# --------------------------------------------------------------------
# Sourced directly (the profile.d wrapper is for login shells); MSYS2_ROOT follows the drive, /usr as fallback.
if [ -z "${BASH_COMPLETION_VERSINFO-}" ] && shopt -q progcomp; then
    for _dp_bc in "${MSYS2_ROOT:-}/usr/share/bash-completion/bash_completion" \
                  "/usr/share/bash-completion/bash_completion"; do
        if [ -r "$_dp_bc" ]; then
            # shellcheck disable=SC1090
            . "$_dp_bc"
            break
        fi
    done
    unset _dp_bc
fi

# --------------------------------------------------------------------
# 3. Prefix search on the arrow keys
# --------------------------------------------------------------------
# Up/Down search the history for entries starting with what is typed.
if [[ $- == *i* ]]; then
    bind '"\e[A": history-search-backward' 2>/dev/null || true
    bind '"\e[B": history-search-forward'  2>/dev/null || true
fi

# --------------------------------------------------------------------
# 4. Tidy up
# --------------------------------------------------------------------
# Exported only to cross the exec; do not leak it.
unset DP_RCFILE
