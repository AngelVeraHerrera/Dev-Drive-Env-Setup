@echo off
chcp 65001 >nul
setlocal EnableExtensions DisableDelayedExpansion

REM ===================================================================
REM ENVIRONMENT STARTER FOR MSYS2
REM Launcher only: loads the environment its own name says, through the bootstrap .sh
REM Author: Ángel Vera Herrera
REM Version: 261020
REM ===================================================================

REM Detect script directory, and the env directory above it spelled out in full
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
for %%I in ("%SCRIPT_DIR%\..") do set "ENV_DIR=%%~fI"

REM ---------------------------------------------------------------
REM Which environment: the one this file is named after
REM ---------------------------------------------------------------
REM Deployed per toolchain as <stem>_env_launcher.bat; everything is named from that stem:
REM     <env dir>\<stem>_env_variables.env
REM     <this dir>\<stem>_env_launcher_bootstrap.sh
REM     <this dir>\<stem>_env_launcher_bashrc.sh
REM 13 is the length of "_env_launcher". No DelayedExpansion: it would eat a "!" in a path.
set "SELF=%~n0"
if /i not "%SELF:~-13%"=="_env_launcher" (
    echo [ERROR] This launcher must be named ^<stem^>_env_launcher.bat, and it is "%SELF%.bat".
    echo         Its name is how it finds its environment file.
    goto :fail
)
set "STEM=%SELF:~0,-13%"

set "ENV_FILE=%ENV_DIR%\%STEM%_env_variables.env"
set "BOOTSTRAP_SCRIPT=%SCRIPT_DIR%\%STEM%_env_launcher_bootstrap.sh"
set "RCFILE_SCRIPT=%SCRIPT_DIR%\%STEM%_env_launcher_bashrc.sh"

if not exist "%ENV_FILE%" (
    echo [ERROR] Environment file not found:
    echo         "%ENV_FILE%"
    echo         This launcher opens the environment "%STEM%"; step 2 of the generator writes its file.
    goto :fail
)

if not exist "%BOOTSTRAP_SCRIPT%" (
    echo [ERROR] Bootstrap script not found:
    echo         "%BOOTSTRAP_SCRIPT%"
    goto :fail
)

REM ---------------------------------------------------------------
REM Read MSYS2_ROOT and MSYS2_ENV from env file
REM ---------------------------------------------------------------
set "MSYS2_ROOT="
set "MSYS2_ENV="
for /f "usebackq tokens=1,* delims==" %%A in ("%ENV_FILE%") do (
    if /i "%%A"=="MSYS2_ROOT" set "MSYS2_ROOT=%%B"
    if /i "%%A"=="MSYS2_ENV"  set "MSYS2_ENV=%%B"
)

if not defined MSYS2_ROOT (
    echo [ERROR] MSYS2_ROOT not defined in env file:
    echo         "%ENV_FILE%"
    goto :fail
)

if not defined MSYS2_ENV (
    echo [ERROR] MSYS2_ENV not defined in env file:
    echo         "%ENV_FILE%"
    goto :fail
)

REM Normalize MSYS2_ROOT to Windows slashes
set "MSYS2_ROOT=%MSYS2_ROOT:/=\%"

set "MSYS2_SHELL=%MSYS2_ROOT%\msys2_shell.cmd"
if not exist "%MSYS2_SHELL%" (
    echo [ERROR] msys2_shell.cmd not found at:
    echo         "%MSYS2_SHELL%"
    goto :fail
)

REM ---------------------------------------------------------------
REM Windows -> POSIX (/n/...) for the paths bash is handed
REM Assumes standard MSYS2 mount: X:\path -> /X/path, which MSYS2 resolves like /x/path
REM ---------------------------------------------------------------
set "BOOTSTRAP_WIN=%BOOTSTRAP_SCRIPT:\=/%"
set "BOOTSTRAP_POSIX=/%BOOTSTRAP_WIN:~0,1%%BOOTSTRAP_WIN:~2%"
set "ENVFILE_WIN=%ENV_FILE:\=/%"
set "ENVFILE_POSIX=/%ENVFILE_WIN:~0,1%%ENVFILE_WIN:~2%"
set "RCFILE_WIN=%RCFILE_SCRIPT:\=/%"
set "RCFILE_POSIX=/%RCFILE_WIN:~0,1%%RCFILE_WIN:~2%"

echo [INFO] Launching MSYS2 environment %STEM% ...
echo [INFO] MSYS2_ROOT:       %MSYS2_ROOT%
echo [INFO] MSYS2_ENV:        %MSYS2_ENV%
echo [INFO] Env file:         %ENV_FILE%
echo [INFO] Bootstrap script: %BOOTSTRAP_SCRIPT%
echo [INFO] POSIX bootstrap:  %BOOTSTRAP_POSIX%
echo.

REM ---------------------------------------------------------------
REM Launch MSYS2
REM ---------------------------------------------------------------
REM The bootstrap and env file travel as exported variables (DP_BOOTSTRAP, DP_ENVFILE): a quote cannot be nested
REM through cmd -> msys2_shell -> bash -lc, and an empty IFS keeps a path with spaces in one word.
set "DP_BOOTSTRAP=%BOOTSTRAP_POSIX%"
set "DP_ENVFILE=%ENVFILE_POSIX%"

REM The rcfile of the interactive shell: `exec` keeps only exported variables, and that shell is not a login shell,
REM so completions and key bindings are set up there (see its header).
set "DP_RCFILE=%RCFILE_POSIX%"

REM The shell runs in mintty, not the Windows console: conhost has no bracketed paste and redraws ~100x slower per
REM character, so pasting was visibly slow. Without -no-start the cmd window closes once mintty is up. To use the
REM console again, add `-defterm -no-start` below.
REM The unset list is every variable this file sets except the DP_* hand-offs: `start` passes them all on.
start "%STEM%" cmd /c ^
""%MSYS2_SHELL%" -%MSYS2_ENV% -here ^
-c "bash -lc 'unset SELF STEM SCRIPT_DIR ENV_DIR ENV_FILE BOOTSTRAP_SCRIPT RCFILE_SCRIPT MSYS2_ROOT MSYS2_ENV BOOTSTRAP_WIN BOOTSTRAP_POSIX ENVFILE_WIN ENVFILE_POSIX RCFILE_WIN RCFILE_POSIX; IFS=; . $DP_BOOTSTRAP; unset DP_BOOTSTRAP; if [ -r $DP_RCFILE ]; then exec bash --rcfile $DP_RCFILE; fi; unset IFS; exec bash'"
exit /b 0

:fail
REM Every refusal ends here. Started from a shortcut, the window would close with the message on it unread, so it
REM waits for a key first -- unless DEV_ENV_NO_PAUSE says otherwise, the bootstrap's own switch, for scripts and tests:
REM set and not 0, no pause.
set "DP_PAUSE=1"
if defined DEV_ENV_NO_PAUSE if not "%DEV_ENV_NO_PAUSE%"=="0" set "DP_PAUSE="
if defined DP_PAUSE (
    echo.
    pause
)
exit /b 1
