#!/usr/bin/env bash
# ===================================================================
# QtCreator launcher for DevSystem MSYS2 environments
# Author: Ángel Vera Herrera
# ===================================================================

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

BASE_PATH_FALLBACK="/usr/local/bin:/usr/bin:/bin"
export PATH="${MINGW_ROOT}/bin:${BASE_PATH:-$BASE_PATH_FALLBACK}"
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
"${QT_CREATOR_EXE}" \
    -settingspath "${QT_SETTINGS_PATH}" \
    "$@" &
disown
exit 0