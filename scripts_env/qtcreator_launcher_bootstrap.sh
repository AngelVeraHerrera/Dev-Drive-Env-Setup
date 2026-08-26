#!/usr/bin/env bash
# ===================================================================
# QtCreator launcher for DevSystem MSYS2 environments
# Author: Ángel Vera Herrera
# ===================================================================

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
# Pauses only when a human is there to press Enter, and not even then if the caller says otherwise.
#
# Two independent conditions, because "is there a tty" and "does anyone want to be stopped" are different questions.
# A scheduled task or a CI job has no tty and is covered by the first; a wrapper script that DOES have a tty but
# wants to run unattended sets DEV_ENV_NO_PAUSE=1 and is covered by the second. Any value other than 0 or empty
# counts, so =1, =yes and =true all work.
#
# The trailing `return 0` is not decorative: under `set -e` the [[ ]] test is the last command of the function, so a
# false test would make the function return 1 and take the whole shell down -- which is exactly what happened every
# time this was sourced without a tty.
pause_if_interactive() {
  [[ -n "${DEV_ENV_NO_PAUSE:-}" && "${DEV_ENV_NO_PAUSE}" != "0" ]] && return 0
  [[ -t 0 && -t 1 ]] && { echo; read -r -p "[PAUSE] Press Enter to continue..." _; }
  return 0
}
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

# ---------------------------------------------------------------
# Cleanup: remove bootstrap temporaries (don’t leak into env)
# ---------------------------------------------------------------
unset MSYS2_SHELL SHELL_ARGS WD X_BOOTSTRAP_POSIX X_MSYS2_ENV X_MSYS2_SHELL
unset PyCharm ORIGINAL_PATH ORIGINAL_TEMP ORIGINAL_TMP

set -e

echo "[INFO] Starting QtCreator..."

if [[ -z "${DEVDRIVE_LETTER}" ]]; then
    echo "[ERROR] DEVDRIVE_LETTER not defined."
    exit 1
fi
if [[ -z "${MSYS2_ENV}" ]]; then
    echo "[ERROR] MSYS2_ENV not defined."
    exit 1
fi
if [[ -z "${MINGW_ROOT}" ]]; then
    echo "[ERROR] MINGW_ROOT not defined."
    exit 1
fi

DEVDRIVE_ROOT="/${DEVDRIVE_LETTER#/}"
echo "[INFO] DevDrive root : ${DEVDRIVE_ROOT}"
echo "[INFO] MSYS2 env     : ${MSYS2_ENV}"
echo "[INFO] MINGW_ROOT    : ${MINGW_ROOT}"

# -------------------------------------------------------------------
# QtCreator isolated directories (persisted in dev drive)
# -------------------------------------------------------------------

QT_ROOT="${DEVDRIVE_ROOT}/env/qtcreator/${MSYS2_ENV}"

# This is the one that matters on Windows
QT_SETTINGS_PATH="${QT_ROOT}/settings"

# Optional XDG (nice to have; not sufficient alone on Windows)
export XDG_CONFIG_HOME="${QT_ROOT}/xdg_config"
export XDG_DATA_HOME="${QT_ROOT}/xdg_data"
export XDG_CACHE_HOME="${QT_ROOT}/xdg_cache"

mkdir -p "${QT_SETTINGS_PATH}" "${XDG_CONFIG_HOME}" "${XDG_DATA_HOME}" "${XDG_CACHE_HOME}"

echo "[INFO] QtCreator settings : ${QT_SETTINGS_PATH}"

# -------------------------------------------------------------------
# Ensure toolchain binaries are first in PATH
# -------------------------------------------------------------------

# PATH comes from the .env, which already begins with the toolchain and carries VCPKG_BIN, VCPKG_ROOT and every
# custom entry. Overwriting it here stripped all of that and left QtCreator running builds that could not find
# their own DLLs. Only fall back if the .env supplied nothing at all.
if [[ -z "${PATH:-}" ]]; then
  export PATH="${MINGW_ROOT}/bin:/usr/local/bin:/usr/bin:/bin"
fi
echo "[INFO] PATH configured"

# -------------------------------------------------------------------
# Locate QtCreator binary
# -------------------------------------------------------------------

QT_CREATOR_EXE="${MINGW_ROOT}/bin/qtcreator.exe"
if [[ ! -x "${QT_CREATOR_EXE}" ]]; then
    if command -v qtcreator >/dev/null 2>&1; then
        QT_CREATOR_EXE="$(command -v qtcreator)"
    else
        echo "[ERROR] qtcreator not found (neither ${QT_CREATOR_EXE} nor in PATH)."
        exit 1
    fi
fi

echo "[INFO] QtCreator binary: ${QT_CREATOR_EXE}"

# -------------------------------------------------------------------
# Launch QtCreator (FORCE isolated settings)
# -------------------------------------------------------------------

echo "[INFO] Launching QtCreator with isolated user settings..."
setsid "${QT_CREATOR_EXE}" -settingspath "${QT_SETTINGS_PATH}" "$@" >/dev/null 2>&1 < /dev/null &
echo "[INFO] Exiting..."
exit 0