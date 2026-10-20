#!/usr/bin/env bash
# ====================================================================
# QT CREATOR, STARTED FROM ONE TOOLCHAIN'S LOADED ENVIRONMENT
# --------------------------------------------------------------------
# Author : Angel Vera Herrera
# Version: 261020
# --------------------------------------------------------------------
# ====================================================================
#
# Sourced by <stem>_qtcreator.bat after the toolchain's bootstrap, in the same bash (its exports and helpers log_i, die
# are available). Receives DP_QTC_EXE, DP_QTC_SETTINGS and DP_QTC_INSTALL_SETTINGS (Windows paths). Converts the env
# file's paths back to Windows form and starts Qt Creator detached.

[[ -n "${DP_QTC_EXE:-}" && -n "${DP_QTC_SETTINGS:-}" && -n "${DP_QTC_INSTALL_SETTINGS:-}" ]] ||
  die "Qt Creator's paths were not handed over: start this from <stem>_qtcreator.bat, not on its own."
[[ -n "${ENV_FILE:-}" && -f "${ENV_FILE}" ]] ||
  die "No environment is loaded: <stem>_env_launcher_bootstrap.sh must be sourced first."

qtc_exe="${DP_QTC_EXE}"
qtc_settings="${DP_QTC_SETTINGS}"
qtc_install="${DP_QTC_INSTALL_SETTINGS}"
[[ -f "$qtc_exe" ]] || die "Qt Creator not found: ${qtc_exe}"

# ---------------------------------------------------------------
# The env file's paths back to Windows form
# ---------------------------------------------------------------
# The bootstrap made drive paths POSIX (R:/vcpkg -> /r/vcpkg); Windows programs need them back. Only single paths are
# converted; lists (BASE_PATH, PATH) contain ':' and are left to MSYS2.
while IFS= read -r raw || [[ -n "$raw" ]]; do
  raw="${raw%$'\r'}"
  [[ -z "$raw" || "$raw" =~ ^[[:space:]]*# || "$raw" != *=* ]] && continue
  key="${raw%%=*}"
  key="${key#"${key%%[![:space:]]*}"}"
  key="${key%"${key##*[![:space:]]}"}"
  [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$key" != "PATH" ]] || continue
  val="${!key-}"
  if [[ "$val" != *:* && "$val" =~ ^/([A-Za-z])(/.*)?$ ]]; then
    letter="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
    export "$key=${letter^^}:${rest:-/}"
  fi
done < "$ENV_FILE"
unset raw key val letter rest

# The hand-offs are this launch's, not the environment's: nothing below Qt Creator should see them.
unset DP_QTC_EXE DP_QTC_SETTINGS DP_QTC_INSTALL_SETTINGS DP_QTC_LAUNCH DP_BOOTSTRAP DP_ENVFILE DEV_ENV_NO_PAUSE

# ---------------------------------------------------------------
# Start Qt Creator, detached
# ---------------------------------------------------------------
# Through setsid, not '&': MSYS2 keeps the forking bash as a stub on the launcher's console while the program runs,
# so the window would stay open. Without setsid (a non-MSYS2 bash) Qt Creator still starts.
log_i "Qt Creator   : ${qtc_exe}"
log_i "Settings     : ${qtc_settings}"
log_i "Kits         : ${qtc_install}"
if command -v setsid >/dev/null 2>&1; then
  setsid "$qtc_exe" -settingspath "$qtc_settings" -installsettingspath "$qtc_install" >/dev/null 2>&1 </dev/null &
else
  log_w "setsid not found: this window stays open while Qt Creator runs."
  "$qtc_exe" -settingspath "$qtc_settings" -installsettingspath "$qtc_install" >/dev/null 2>&1 </dev/null &
fi
disown
log_i "Qt Creator started in the ${DEVSYSTEM_LABEL:-$DEVSYSTEM_TOOLCHAIN_ID} environment."
unset qtc_exe qtc_settings qtc_install
true
