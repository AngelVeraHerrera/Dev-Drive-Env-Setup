#!/usr/bin/env bash
# ====================================================================
# ENVIRONMENT BOOTSTRAP FOR MSYS2 (UCRT64 / MINGW64 / etc.)
# --------------------------------------------------------------------
# Author : Angel Vera Herrera
# Version: 261020
# --------------------------------------------------------------------
# ====================================================================

set -Eeuo pipefail

log_i(){ printf '[INFO] %s\n' "$*"; }
log_w(){ printf '[WARN] %s\n' "$*"; }
log_e(){ printf '[ERROR] %s\n' "$*"; }
# Pauses only with a tty and DEV_ENV_NO_PAUSE unset/0. The trailing `return 0` matters: under `set -e` a false test as
# the last command would return 1 and kill the sourcing shell.
pause_if_interactive() {
  [[ -n "${DEV_ENV_NO_PAUSE:-}" && "${DEV_ENV_NO_PAUSE}" != "0" ]] && return 0
  [[ -t 0 && -t 1 ]] && { echo; read -r -p "[PAUSE] Press Enter to continue..." _; }
  return 0
}
die() { log_e "$*"; pause_if_interactive; exit 1; }

# These helpers return through DP_REPLY, not stdout: every $( ) is an emulated fork on MSYS2 (~9 ms), and the .env loop
# used ~130 of them (1.2 s of the bootstrap's 1.5 s). DP_REPLY, not REPLY, which `read` clobbers.
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

  # Iterate until stable, at most 10 passes. iter=$((iter + 1)), not ((iter++)): the latter returns status 1 on the
  # first pass and aborts under `set -e`.
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
# Helpers: sanitize and path conversions
# ---------------------------------------------------------------
strip_cr()      { DP_REPLY="${1%$'\r'}"; }
norm_slashes()  { DP_REPLY="${1//\\//}"; }
looks_win_path(){ [[ "$1" =~ ^[A-Za-z]:($|/) ]]; }

to_posix() {
  # Pure parameter expansion ("X:/foo" -> "/x/foo"), no cygpath fork: only drive-letter paths reach here.
  local d="${1:0:1}"
  DP_REPLY="/${d,}${1:2}"
}

export_env_kv() {
  # @brief Export key=value, converting a Windows drive path to POSIX in place.
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
# The env file: the one the launcher names
# ---------------------------------------------------------------
# The env file is the one the launcher names in DP_ENVFILE; sourced otherwise, <stem>_env_launcher_bootstrap.sh loads
# <stem>_env_variables.env from the folder above. Placed after the helpers so a Windows-style DP_ENVFILE is converted.
if [[ -n "${DP_ENVFILE:-}" ]]; then
  strip_cr "$DP_ENVFILE";  ENV_FILE="$DP_REPLY"
  norm_slashes "$ENV_FILE"; ENV_FILE="$DP_REPLY"
  if looks_win_path "$ENV_FILE"; then to_posix "$ENV_FILE"; ENV_FILE="$DP_REPLY"; fi
else
  self="${BASH_SOURCE[0]##*/}"
  [[ "$self" == *_env_launcher_bootstrap.sh ]] ||
    die "Cannot tell which environment to load: no DP_ENVFILE, and '${self}' is not named <stem>_env_launcher_bootstrap.sh."
  ENV_FILE="${SCRIPT_DIR}/../${self%_env_launcher_bootstrap.sh}_env_variables.env"
  unset self
fi
unset DP_ENVFILE

log_i "Env file     : ${ENV_FILE}"
[[ -f "$ENV_FILE" ]] || die "Env file not found: ${ENV_FILE}"

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
# Every installed/<triplet>/tools/<port>/ (and tools/<port>/bin/, Qt6, icu...) holding an .exe goes on PATH, scanned
# at launch since the set grows with each port. Paths are already POSIX (a ':' would split them). Inserted ahead of
# BASE_PATH: projects link against these builds, so they run these tools too.
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

# The env file must say which toolchain it is, and the shell must be that subsystem: mixing runtimes fails later as a
# missing entry point.
[[ -n "${DEVSYSTEM_TOOLCHAIN_ID:-}" ]] || die "DEVSYSTEM_TOOLCHAIN_ID not set in env file (step 2 of the generator writes it)"
[[ -n "${MSYS2_ENV:-}" ]]              || die "MSYS2_ENV not set in env file (step 2 of the generator writes it)"
[[ "${MSYSTEM:-}" == "${MSYS2_ENV^^}" ]] ||
  die "This shell is ${MSYSTEM:-not an MSYS2 subsystem}, but the env file is for ${MSYS2_ENV^^}. Start it from its own launcher."

# Case folding in bash, not printf | tr (forks).
DEVSYSTEM_NAME_UPPER="${DEVSYSTEM_NAME^^}"
DEVSYSTEM_NAME_TOKEN="${DEVSYSTEM_NAME_UPPER//[^A-Z0-9_]/_}"
MSYS2_ENV_LOWER="${MSYS2_ENV,,}"
# The session's label everywhere a person looks: the window title and the prompt. "DEGORASSLR clang64", so two
# windows of one drive cannot be told apart only by what breaks in them.
DEVSYSTEM_LABEL="${DEVSYSTEM_NAME_UPPER} ${DEVSYSTEM_TOOLCHAIN_ID}"

log_i "DEVSYSTEM_NAME  : ${DEVSYSTEM_NAME_UPPER}"
log_i "Toolchain       : ${DEVSYSTEM_TOOLCHAIN_ID}"
log_i "MSYS2_ENV       : ${MSYS2_ENV_LOWER}"
log_i "Loaded env file : ${ENV_FILE}"

# ---------------------------------------------------------------
# Enter MSYS2 environment 
# ---------------------------------------------------------------
if ! command -v shell >/dev/null 2>&1; then
  die "'shell' helper not found. Are you running inside MSYS2 bash?"
fi

# ---------------------------------------------------------------
# Title + prompt (dynamic)
# ---------------------------------------------------------------
printf "\033]0;%s\007" "${DEVSYSTEM_LABEL}"
# 92/95 are bright green/magenta: bold would render as a real bold weight in mintty.
PS1="\[\033]0;${DEVSYSTEM_LABEL}\007\]\[\033[92m\][${DEVSYSTEM_LABEL}]\$\[\033[0m\] \[\033[95m\]\w\[\033[0m\]\n\$ "
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

# The arrow-key history search lives in <stem>_env_launcher_bashrc.sh: this shell is not interactive.

log_i "Persistent history: ${HISTFILE}"

# ---------------------------------------------------------------
# Change to devdrive root
# ---------------------------------------------------------------
if [[ -d "$DEVDRIVE_ROOT" ]]; then
  cd "$DEVDRIVE_ROOT"
fi

log_i "$DEVSYSTEM_LABEL environment ready!"

pause_if_interactive
clear

# ---------------------------------------------------------------
# Cleanup: remove bootstrap temporaries (don’t leak into env)
# ---------------------------------------------------------------
unset MSYS2_SHELL SHELL_ARGS WD X_BOOTSTRAP_POSIX X_MSYS2_ENV X_MSYS2_SHELL
unset PyCharm ORIGINAL_PATH ORIGINAL_TEMP ORIGINAL_TMP

