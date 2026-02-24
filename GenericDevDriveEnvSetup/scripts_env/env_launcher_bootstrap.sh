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
pause_if_interactive() { [[ -t 0 && -t 1 ]] && { echo; read -r -p "[PAUSE] Press Enter to continue..." _; }; }
die() { log_e "$*"; pause_if_interactive; exit 1; }

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

  printf '%s' "$s"
}


expand_env_vars_recursive() {
  local s="$1" prev="" iter=0

  # Iterate until stable or max iterations (prevents infinite loops)
  while [[ "$s" != "$prev" && $iter -lt 10 ]]; do
    prev="$s"
    s="$(expand_env_vars_once "$s")"
    ((iter++))
  done

  printf '%s' "$s"
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
env_files=("${SCRIPT_DIR}"/*_env_variables.env)

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
strip_cr()      { printf '%s' "${1%$'\r'}"; }
norm_slashes()  { printf '%s' "${1//\\//}"; }
looks_win_path(){ [[ "$1" =~ ^[A-Za-z]:($|/) ]]; }

to_posix() {
  local v="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$v" 2>/dev/null || printf '%s' "$v"
  else
    printf '%s' "$v"
  fi
}

export_env_kv() {
  # @brief Export key=value. If value is Windows drive path -> convert to POSIX in-place.
  local k="$1" v="$2"

  v="$(strip_cr "$v")"
  v="$(norm_slashes "$v")"

  if looks_win_path "$v"; then
    v="$(to_posix "$v")"
  fi
  
  v="$(expand_env_vars_recursive "$v")"
  export "$k=$v"
}

# ---------------------------------------------------------------
# Parse env file: KEY=VALUE -> export (POSIX in-place, no *_POSIX)
# ---------------------------------------------------------------
log_i "Loading variables from .env (POSIX in-place)..."

while IFS= read -r raw || [[ -n "$raw" ]]; do
  raw="$(strip_cr "$raw")"
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
# Required variables
# ---------------------------------------------------------------
[[ -n "${DEVSYSTEM_NAME:-}" ]] || die "DEVSYSTEM_NAME not set in env file"

DEVSYSTEM_NAME_UPPER="$(printf '%s' "$DEVSYSTEM_NAME" | tr '[:lower:]' '[:upper:]')"
DEVSYSTEM_NAME_TOKEN="$(printf '%s' "$DEVSYSTEM_NAME_UPPER" | tr -c 'A-Z0-9_' '_')"
MSYS2_ENV_LOWER="$(printf '%s' "${MSYS2_ENV:-ucrt64}" | tr '[:upper:]' '[:lower:]')"

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
PS1="\[\033]0;${DEVSYSTEM_NAME_UPPER}\007\]\[\033[1;32m\][${DEVSYSTEM_NAME_UPPER}]\$\[\033[0m\] \[\033[1;35m\]\w\[\033[0m\]\n\$ "
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

DEVDRIVE_VAL="$(strip_cr "$DEVDRIVE_VAL")"
DEVDRIVE_VAL="$(norm_slashes "$DEVDRIVE_VAL")"
# If it is still a Windows-like path, convert; otherwise keep it
if looks_win_path "$DEVDRIVE_VAL"; then
  DEVDRIVE_VAL="$(to_posix "$DEVDRIVE_VAL")"
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

# Enable prefix search with arrow keys (only in interactive shells with readline)
if [[ $- == *i* ]] && [[ -t 0 ]] && [[ -t 1 ]]; then
  bind '"\e[A": history-search-backward' 2>/dev/null || true
  bind '"\e[B": history-search-forward' 2>/dev/null || true
fi

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

