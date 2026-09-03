#!/usr/bin/env bash
# ====================================================================
# ENVIRONMENT BOOTSTRAP FOR MSYS2 (UCRT64 / MINGW64 / etc.)
# --------------------------------------------------------------------
# Author : Angel Vera Herrera
# Version: 251107
# --------------------------------------------------------------------
# ====================================================================

set -Eeuo pipefail

log_i(){ printf '[INFO] %s\n' "$*"; }
log_w(){ printf '[WARN] %s\n' "$*"; }
log_e(){ printf '[ERROR] %s\n' "$*"; }
# The trailing `|| true` is load-bearing. Under `set -e` a function returns the status of its last command, and
# with no tty the [[ ]] test is false -> return 1 -> the sourcing shell aborts silently, before `exec bash`. That
# made the bootstrap unusable from any script or CI, with no diagnostic whatsoever.
# Pauses only when a human is there to press Enter, and not even then if the caller says otherwise.
#
# Two independent conditions, because "is there a tty" and "does anyone want to be stopped" are different questions.
# A scheduled task or a CI job has no tty and is covered by the first; a wrapper script that DOES have a tty but
# wants to run unattended sets DEV_ENV_NO_PAUSE=1 and is covered by the second. Any value other than 0 or empty
# counts, so =1, =yes and =true all work.
#
# The trailing `return 0` is not decorative: this script runs under `set -e`, the [[ ]] test is the last command, and
# a false test would otherwise make the function return 1 and take the whole shell down -- which is exactly what
# happened every time the bootstrap was sourced without a tty.
pause_if_interactive() {
  [[ -n "${DEV_ENV_NO_PAUSE:-}" && "${DEV_ENV_NO_PAUSE}" != "0" ]] && return 0
  [[ -t 0 && -t 1 ]] && { echo; read -r -p "[PAUSE] Press Enter to continue..." _; }
  return 0
}
die() { log_e "$*"; pause_if_interactive; exit 1; }

# THESE FUNCTIONS RETURN THROUGH DP_REPLY, NOT THROUGH STDOUT, and that is a performance decision
# rather than a style one.
#
# Every $( ) is a subshell. On MSYS2 there is no real fork -- it is emulated on top of Windows
# process creation -- so a command substitution costs on the order of nine milliseconds instead of
# the microseconds it costs on Linux. The .env loop ran four of them per variable, and
# expand_env_vars_recursive ran up to ten more inside itself, so twenty-eight variables came to
# roughly a hundred and thirty forks.
#
# Measured on a generated drive, best of three runs each:
#
#   130 command substitutions calling a shell function      1176 ms
#   the same work through parameter expansion                  16 ms
#   the shape this loop actually had (28 x 5)                1264 ms
#
# and the bootstrap's own overhead over a plain login shell was 1490 ms. So the forks were
# essentially all of it -- not bash-completion, which costs 11 ms, and not the vcpkg tool directory
# scan, which costs 17 ms. Both were measured before being ruled out.
#
# DP_REPLY rather than the conventional REPLY: a bare `read` clobbers REPLY, and this file both
# reads the .env line by line and calls `read` in pause_if_interactive. A dedicated name cannot be
# caught out by that later.
expand_env_vars_once() {
  local s="$1" name val

  # Expand ${NAME}
  while [[ "$s" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
    name="${BASH_REMATCH[1]}"
    val="${!name-}"
    s="${s//\$\{$name\}/$val}"
  done

  # Optional: expand $NAME (enable if you want it)
  while [[ "$s" =~ \$([A-Za-z_][A-Za-z0-9_]*) ]]; do
    name="${BASH_REMATCH[1]}"
    val="${!name-}"
    s="${s//\$$name/$val}"
  done

  DP_REPLY="$s"
}


expand_env_vars_recursive() {
  local s="$1" prev="" iter=0

  # Iterate until stable or max iterations (prevents infinite loops)
  #
  # iter=$((iter + 1)) and NOT ((iter++)), which is a latent bug this file carried for a long time.
  # An arithmetic command returns the truth value of its expression, so ((iter++)) evaluates to the
  # value BEFORE the increment -- zero on the first pass -- and therefore returns status 1. Under
  # the `set -Eeuo pipefail` at the top of this file that aborts the shell.
  #
  # It never showed because the caller used to invoke this function inside $( ), and `set -e` kills
  # a SUBSHELL without touching its parent: the subshell died at the end of the first iteration,
  # printed what it had, and the caller carried on unaware. So this loop never actually iterated --
  # it expanded once and stopped. Removing the command substitution for performance is what exposed
  # it, with bash reporting the abort as
  #     pop_scope: head of shell_variables is not a temporary environment scope
  # because the shell was exiting from inside a function while `VAR=x source` had a temporary
  # environment scope on the stack.
  #
  # An assignment always returns 0, so the loop now runs to its own termination condition. The
  # behaviour barely changes in practice, because expand_env_vars_once already loops internally
  # until no ${...} remains -- but "barely" is not "does not", and a value needing two passes was
  # silently getting one.
  while [[ "$s" != "$prev" && $iter -lt 10 ]]; do
    prev="$s"
    expand_env_vars_once "$s"
    s="$DP_REPLY"
    iter=$((iter + 1))
  done

  DP_REPLY="$s"
}

# ---------------------------------------------------------------
# Resolve script directory
# ---------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
log_i "Bootstrap dir: ${SCRIPT_DIR}"

# ---------------------------------------------------------------
# Auto-detect <prefix>-env-variables.env
# ---------------------------------------------------------------
shopt -s nullglob
env_files=("${SCRIPT_DIR}"/../*_env_variables.env)

if (( ${#env_files[@]} == 0 )); then
  die "No *_env_variables.env found in: ${SCRIPT_DIR}"
elif (( ${#env_files[@]} > 1 )); then
  log_e "Multiple *-env-variables.env found in: ${SCRIPT_DIR}"
  for f in "${env_files[@]}"; do log_e "  - $(basename "$f")"; done
  die "Ensure only one environment prefix is present."
fi

ENV_FILE="${env_files[0]}"
PREFIX="$(basename "$ENV_FILE" "_env_variables.env")"
log_i "Detected prefix: ${PREFIX}"
log_i "Env file       : ${ENV_FILE}"

[[ -f "$ENV_FILE" ]] || die "Env file not found: ${ENV_FILE}"

# ---------------------------------------------------------------
# Helpers: sanitize and path conversions
# ---------------------------------------------------------------
strip_cr()      { DP_REPLY="${1%$'\r'}"; }
norm_slashes()  { DP_REPLY="${1//\\//}"; }
looks_win_path(){ [[ "$1" =~ ^[A-Za-z]:($|/) ]]; }

to_posix() {
  # Pure parameter expansion, and cygpath is not called at all any more.
  #
  # The only shape that reaches here is a drive-letter path, because looks_win_path gates the call,
  # and "X:/foo" -> "/x/foo" is exact for that shape -- there is nothing cygpath knows about it that
  # bash does not. Calling out was one more emulated fork per value, for a substitution costing
  # nothing. cygpath is still the right tool for the shapes bash cannot do, UNC paths and mount
  # prefixes, and none of them can appear in a drive-letter value.
  #
  # ${1:0:1} is the letter, ${1:2} everything past the colon, and ${d,} lower-cases the letter to
  # match cygpath's canonical form. MSYS2 resolves /C/ and /c/ alike, so that is consistency.
  local d="${1:0:1}"
  DP_REPLY="/${d,}${1:2}"
}

export_env_kv() {
  # @brief Export key=value. If value is Windows drive path -> convert to POSIX in-place.
  #
  # Four command substitutions became four plain calls. See the note above expand_env_vars_once for
  # what that was costing and how it was measured.
  local k="$1" v="$2"

  strip_cr "$v";     v="$DP_REPLY"
  norm_slashes "$v"; v="$DP_REPLY"

  if looks_win_path "$v"; then
    to_posix "$v";   v="$DP_REPLY"
  fi

  expand_env_vars_recursive "$v"; v="$DP_REPLY"
  export "$k=$v"
}

# ---------------------------------------------------------------
# Parse env file: KEY=VALUE -> export (POSIX in-place, no *_POSIX)
# ---------------------------------------------------------------
log_i "Loading variables from .env (POSIX in-place)..."

while IFS= read -r raw || [[ -n "$raw" ]]; do
  strip_cr "$raw"; raw="$DP_REPLY"
  [[ -z "$raw" ]] && continue
  [[ "$raw" =~ ^[[:space:]]*# ]] && continue
  [[ "$raw" != *"="* ]] && { log_w "Skipping invalid line (no '='): $raw"; continue; }

  key="${raw%%=*}"
  val="${raw#*=}"

  # Trim key spaces
  key="${key#"${key%%[![:space:]]*}"}"
  key="${key%"${key##*[![:space:]]}"}"

  # Strip optional surrounding quotes in value
  if [[ "$val" =~ ^\".*\"$ ]]; then val="${val:1:-1}"; fi
  if [[ "$val" =~ ^\'.*\'$ ]]; then val="${val:1:-1}"; fi

  # Validate key
  if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    log_w "Skipping invalid key: '$key'"
    pause_if_interactive
    continue
  fi

  export_env_kv "$key" "$val"
  printf '[ENV] %s=%q\n' "$key" "${!key}"
  
done < "$ENV_FILE"

# ---------------------------------------------------------------
# vcpkg tool directories
# ---------------------------------------------------------------
# vcpkg does not gather executables in one place. Every port that ships tools gets its own
# installed/<triplet>/tools/<port>/ directory, so gst-launch-1.0, ffprobe, glib-compile-schemas and the rest each sit
# in a directory of their own and NONE of them reaches PATH. Before this, gst-inspect-1.0 could only be run by
# spelling out its full path, while vcpkg, gcc and cmake resolved fine -- which made it look like a gstreamer problem
# rather than a missing convention.
#
# SCANNED AT LAUNCH, not written into the .env at generation time: the set grows every time a port with tools is
# installed, so a list baked in once would be stale after the next dependency step.
#
# TWO LEVELS DEEP, and that is measured rather than assumed. Most ports put their executables straight into
# tools/<port>/ -- gstreamer, ffmpeg, glib, curl, pkgconf -- while Qt6, icu, hwloc and libiconv put theirs one level
# further down in tools/<port>/bin/. A directory holding no .exe is skipped, so nothing empty joins PATH.
#
# The paths need no conversion here: export_env_kv() has already turned every drive-letter value into its POSIX form,
# which matters because a colon inside a PATH component is the separator -- "R:/vcpkg" in a POSIX PATH is not one
# component but the two useless ones "R" and "/vcpkg".
#
# Inserted immediately AHEAD OF BASE_PATH, where this environment's own components belong. That does mean a vcpkg
# tool wins over an MSYS2 one of the same name: tools/curl/curl.exe ahead of /usr/bin/curl, tools/pkgconf ahead of the
# MSYS2 pkgconf. That is the intent -- projects on this drive link against these builds, so they should run them too.
add_vcpkg_tool_dirs() {
  local root="${VCPKG_ROOT:-}"
  local triplet="${VCPKG_DEFAULT_TRIPLET:-}"
  [[ -n "$root" && -n "$triplet" ]] || return 0

  local tools_root="${root}/installed/${triplet}/tools"
  if [[ ! -d "$tools_root" ]]; then
    log_i "No vcpkg tools directory yet: ${tools_root}"
    return 0
  fi

  local dirs="" d
  local -a exes
  # nullglob so a level that matches nothing contributes nothing instead of the literal pattern.
  shopt -s nullglob
  for d in "$tools_root"/*/ "$tools_root"/*/*/; do
    exes=("$d"*.exe)
    (( ${#exes[@]} > 0 )) && dirs="${dirs:+$dirs:}${d%/}"
  done
  shopt -u nullglob

  if [[ -z "$dirs" ]]; then
    log_i "No vcpkg tool executables found under: ${tools_root}"
    return 0
  fi

  # Spliced rather than prepended to the whole of PATH, so the order the .env established -- VCPKG_BIN, VCPKG_ROOT,
  # then the configured custom entries -- survives. A PATH that does not end in BASE_PATH has been hand-edited, and
  # prepending is then the safe fallback.
  if [[ -n "${BASE_PATH:-}" && "$PATH" == *"$BASE_PATH" ]]; then
    PATH="${PATH%"$BASE_PATH"}${dirs}:${BASE_PATH}"
  else
    PATH="${dirs}:${PATH}"
  fi
  export PATH

  local count
  count="$(printf '%s' "$dirs" | tr ':' '\n' | grep -c . || true)"
  log_i "vcpkg tool directories on PATH: ${count}"
  return 0
}

add_vcpkg_tool_dirs


# ---------------------------------------------------------------
# Required variables
# ---------------------------------------------------------------
[[ -n "${DEVSYSTEM_NAME:-}" ]] || die "DEVSYSTEM_NAME not set in env file"

# Case folding and sanitising in bash rather than through printf | tr. Each of these was two
# processes -- six emulated forks for three assignments -- and ${v^^}, ${v,,} and a pattern
# substitution do exactly the same job. tr -c 'A-Z0-9_' '_' replaces every character OUTSIDE that
# set, which is what the negated character class below does.
DEVSYSTEM_NAME_UPPER="${DEVSYSTEM_NAME^^}"
DEVSYSTEM_NAME_TOKEN="${DEVSYSTEM_NAME_UPPER//[^A-Z0-9_]/_}"
MSYS2_ENV_LOWER="${MSYS2_ENV:-ucrt64}"
MSYS2_ENV_LOWER="${MSYS2_ENV_LOWER,,}"

log_i "DEVSYSTEM_NAME  : ${DEVSYSTEM_NAME_UPPER}"
log_i "MSYS2_ENV : ${MSYS2_ENV_LOWER}"
log_i "Loaded env file: ${ENV_FILE}"

# ---------------------------------------------------------------
# Enter MSYS2 environment 
# ---------------------------------------------------------------
if ! command -v shell >/dev/null 2>&1; then
  die "'shell' helper not found. Are you running inside MSYS2 bash?"
fi

# ---------------------------------------------------------------
# Title + prompt (dynamic)
# ---------------------------------------------------------------
printf "\033]0;%s\007" "${DEVSYSTEM_NAME_UPPER}"
# 92 and 95 are BRIGHT green and BRIGHT magenta. They used to be "1;32" and "1;35", which ask for bold
# AND the normal colour, and that is not the same request. The Windows console mostly rendered bold as a
# brighter colour, so the two looked identical there; mintty renders it as a real bold weight, and a
# synthesised bold at prompt size looks smeared. Asking for the bright colour directly says what was
# actually wanted and does not depend on the terminal's BoldAsFont setting to look right.
PS1="\[\033]0;${DEVSYSTEM_NAME_UPPER}\007\]\[\033[92m\][${DEVSYSTEM_NAME_UPPER}]\$\[\033[0m\] \[\033[95m\]\w\[\033[0m\]\n\$ "
export PS1

# ---------------------------------------------------------------
# Devdrive variable: <DEVSYSTEM_NAME>_DEVDRIVE (preferred)
# Example DEVSYSTEM_NAME=GStreamer -> GSTREAMER_DEVDRIVE
# ---------------------------------------------------------------
DEVDRIVE_VAL="${DEVDRIVE_LETTER:-}"

if [[ -z "$DEVDRIVE_VAL" ]]; then
  log_w "DEVDRIVE_LETTER not set; using HOME."
  pause_if_interactive
  DEVDRIVE_VAL="$HOME"
fi

strip_cr "$DEVDRIVE_VAL";     DEVDRIVE_VAL="$DP_REPLY"
norm_slashes "$DEVDRIVE_VAL"; DEVDRIVE_VAL="$DP_REPLY"
# If it is still a Windows-like path, convert; otherwise keep it
if looks_win_path "$DEVDRIVE_VAL"; then
  to_posix "$DEVDRIVE_VAL";   DEVDRIVE_VAL="$DP_REPLY"
fi
DEVDRIVE_VAL="${DEVDRIVE_VAL%/}"

export DEVDRIVE_ROOT="$DEVDRIVE_VAL"

LOGS_ROOT="${DEVDRIVE_ROOT}/logs"
ENV_LOG_DIR="${LOGS_ROOT}/env"
mkdir -p "${ENV_LOG_DIR}"

log_i "Devdrive root: ${DEVDRIVE_ROOT}"
log_i "Logs root    : ${LOGS_ROOT}"
log_i "Env logs     : ${ENV_LOG_DIR}"

# ---------------------------------------------------------------
# Persistent history
# ---------------------------------------------------------------
shopt -s histappend
export HISTFILE="${ENV_LOG_DIR}/bash_history"
export HISTSIZE=50000
export HISTFILESIZE=200000
export HISTCONTROL=ignoredups:erasedups
export HISTIGNORE="ls:cd:pwd:clear:history*"
export HISTTIMEFORMAT="%F %T "
export PROMPT_COMMAND='history -a; history -n; '"${PROMPT_COMMAND-}"

# The arrow-key history search used to be here, guarded on [[ $- == *i* ]], and the guard was never true: this
# file is sourced by the `bash -lc` shell in the launcher, where $- is "hBc". Measured, not assumed. Worse, a bind
# would not have survived anyway -- the launcher then calls `exec bash`, and only exported VARIABLES cross an exec.
# It now lives in <prefix>_env_launcher_bashrc.sh, which the final interactive shell reads as its rcfile.

log_i "Persistent history: ${HISTFILE}"

# ---------------------------------------------------------------
# Change to devdrive root
# ---------------------------------------------------------------
if [[ -d "$DEVDRIVE_ROOT" ]]; then
  cd "$DEVDRIVE_ROOT"
fi

log_i "$DEVSYSTEM_NAME_UPPER environment ready!"

pause_if_interactive
clear

# ---------------------------------------------------------------
# Cleanup: remove bootstrap temporaries (don’t leak into env)
# ---------------------------------------------------------------
unset MSYS2_SHELL SHELL_ARGS WD X_BOOTSTRAP_POSIX X_MSYS2_ENV X_MSYS2_SHELL
unset PyCharm ORIGINAL_PATH ORIGINAL_TEMP ORIGINAL_TMP

