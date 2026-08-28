# ====================================================================
# INTERACTIVE SHELL SETUP FOR THE GENERATED ENVIRONMENT
# --------------------------------------------------------------------
# Author : Angel Vera Herrera
# --------------------------------------------------------------------
# ====================================================================
#
# WHY THIS FILE EXISTS, and why the bootstrap cannot do its job.
#
# The launcher chain is:
#
#     cmd -> msys2_shell.cmd -> bash -lc '. <bootstrap>; exec bash'
#                                         ^^^^^^^^^^^^   ^^^^^^^^^
#                                    non-interactive     the shell
#                                    LOGIN shell         you type in
#
# `exec` REPLACES the process, and only EXPORTED VARIABLES cross that
# boundary. Shell functions, key bindings and completions do not. So
# anything the bootstrap sets that is not an exported variable is gone
# before the first prompt appears -- measured, not assumed.
#
# Two things were silently lost that way:
#
#   * bash-completion. /etc/profile.d/bash_completion.sh guards itself
#     on `[ "x${PS1-}" != x ]`, and the only shell in the chain that
#     reads /etc/profile is the `bash -lc` one, which is non-interactive
#     and has no PS1. The final `exec bash` is NOT a login shell, so it
#     never reads /etc/profile at all. Result: 52 completion scripts
#     installed and none of them loaded -- TAB fell back to bare
#     filename completion.
#
#   * The arrow-key history search. The bootstrap guards its `bind`
#     calls on `[[ $- == *i* ]]`, and in the shell that sources it
#     $- is "hBc". The guard is correct; the shell is simply the wrong
#     one. The binds never ran.
#
# So the final shell is given this as its rcfile. It is deployed beside
# the bootstrap by step 1, which copies every scripts_env/*.sh with the
# environment prefix.
#
# ~/.bashrc IS STILL SOURCED, first, and that is deliberate: --rcfile
# replaces it rather than adding to it, and silently dropping whatever
# the developer keeps there would be a rude thing for a launcher to do.
# Note $HOME is the Windows profile and is SHARED by every MSYS2
# environment on the machine, which is exactly why this file does not
# write to it.
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
# Sourced directly rather than through /etc/profile.d, because that
# wrapper re-checks PS1 and BASH_COMPLETION_VERSINFO and is meant for a
# login shell. Here the conditions are already known: this file is only
# ever read by an interactive bash.
#
# MSYS2_ROOT is exported by the bootstrap, so the path follows the drive
# rather than being hard-coded; the /usr fallback covers a shell started
# some other way.
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
# Type the start of a command and Up walks only the history entries
# that begin with it, instead of every entry in order. Moved here from
# the bootstrap, where the interactive guard was correct and never true.
if [[ $- == *i* ]]; then
    bind '"\e[A": history-search-backward' 2>/dev/null || true
    bind '"\e[B": history-search-forward'  2>/dev/null || true
fi

# --------------------------------------------------------------------
# 4. Tidy up
# --------------------------------------------------------------------
# The launcher exports this only to hand this file's path across the
# exec. Leaving it set would leak an implementation detail into every
# shell and every child process.
unset DP_RCFILE
