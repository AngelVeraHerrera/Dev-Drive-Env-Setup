@echo off
chcp 65001 >nul
setlocal EnableExtensions EnableDelayedExpansion

REM ===================================================================
REM ENVIRONMENT STARTER FOR MSYS2
REM Launcher only: calls bootstrap .sh (auto-detected)
REM Author: Ángel Vera Herrera
REM Version: 260304
REM ===================================================================

REM Detect script directory
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "ENV_DIR=%SCRIPT_DIR%\.."

REM ---------------------------------------------------------------
REM Find exactly one pair: <prefix>-env-variables.env + <prefix>-env-launcher-bootstrap.sh
REM ---------------------------------------------------------------

set /a COUNT=0
set "ENV_FILE="
set "BOOTSTRAP_SCRIPT="
set "PREFIX="

for %%F in ("%ENV_DIR%\*_env_variables.env") do (
    if exist "%%~fF" (

        set "CAND_ENV=%%~fF"
        set "CAND_PREFIX=%%~nF"

        rem remove suffix "_env_variables"
        set "CAND_PREFIX=!CAND_PREFIX:_env_variables=!"

        set "CAND_BOOT=%SCRIPT_DIR%\!CAND_PREFIX!_env_launcher_bootstrap.sh"

        echo [DEBUG] ENV  : "!CAND_ENV!"
        echo [DEBUG] PREF : "!CAND_PREFIX!"
        echo [DEBUG] BOOT : "!CAND_BOOT!"

        if exist "!CAND_BOOT!" (
            set /a COUNT+=1
            set "ENV_FILE=!CAND_ENV!"
            set "BOOTSTRAP_SCRIPT=!CAND_BOOT!"
            set "PREFIX=!CAND_PREFIX!"
        )
    )
)

if "%COUNT%"=="0" (
    echo [ERROR] No valid environment pair found.
    echo         Launcher dir : "%SCRIPT_DIR%"
    echo         Env dir      : "%ENV_DIR%"
    echo         Expected:
    echo           "%ENV_DIR%\^<prefix^>_env_variables.env"
    echo           "%SCRIPT_DIR%\^<prefix^>_env_launcher_bootstrap.sh"
    exit /b 1
)

if not "%COUNT%"=="1" (
    echo [ERROR] Multiple valid environment pairs found.
    echo         Ensure only one prefix is present in:
    echo           "%ENV_DIR%" and "%SCRIPT_DIR%"
    exit /b 1
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
    exit /b 1
)

if not defined MSYS2_ENV (
    echo [ERROR] MSYS2_ENV not defined in env file:
    echo         "%ENV_FILE%"
    exit /b 1
)

REM Normalize MSYS2_ROOT to Windows slashes
set "MSYS2_ROOT=%MSYS2_ROOT:/=\%"

set "MSYS2_SHELL=%MSYS2_ROOT%\msys2_shell.cmd"
if not exist "%MSYS2_SHELL%" (
    echo [ERROR] msys2_shell.cmd not found at:
    echo         "%MSYS2_SHELL%"
    exit /b 1
)

REM ---------------------------------------------------------------
REM Convert BOOTSTRAP_SCRIPT (Windows) -> POSIX (/g/...) for bash -lc
REM Assumes standard MSYS2 mount: X:\path -> /x/path
REM ---------------------------------------------------------------
set "BOOTSTRAP_WIN=%BOOTSTRAP_SCRIPT:\=/%"
set "DRIVE=%BOOTSTRAP_WIN:~0,1%"
set "BOOTSTRAP_POSIX=/%DRIVE%%BOOTSTRAP_WIN:~2%"

echo [INFO] Launching MSYS2 environment...
echo [INFO] MSYS2_ROOT:       %MSYS2_ROOT%
echo [INFO] MSYS2_ENV:        %MSYS2_ENV%
echo [INFO] Env file:         %ENV_FILE%
echo [INFO] Bootstrap script: %BOOTSTRAP_SCRIPT%
echo [INFO] POSIX bootstrap:  %BOOTSTRAP_POSIX%
echo.

REM ---------------------------------------------------------------
REM Launch MSYS2 
REM ---------------------------------------------------------------
REM The bootstrap path travels in an ENVIRONMENT VARIABLE, not inside the nested quotes.
REM
REM It used to be interpolated as '...''%BOOTSTRAP_POSIX%''...' inside a single-quoted bash string. Doubling a quote
REM does NOT escape it in bash: it ends the string, concatenates, and starts a new one -- so the path arrived
REM UNQUOTED and bash sourced only its first word. Any space in the path (a repo checked out under a directory with
REM one, since the on-drive path is space-free by construction) silently broke the launcher.
REM
REM There is no reliable way to nest a double quote three layers deep through cmd -> msys2_shell -> bash -lc, so the
REM value is exported instead. Inside bash, `set -f` and an empty IFS stop the unquoted expansion from being split
REM or globbed, and both are undone before the interactive shell starts.
set "DP_BOOTSTRAP=%BOOTSTRAP_POSIX%"

start "Loading env..." cmd /c ^
""%MSYS2_SHELL%" -%MSYS2_ENV% -defterm -here -no-start ^
-c "bash -lc 'unset COUNT ENV_FILE BOOTSTRAP_SCRIPT PREFIX CAND_ENV CAND_PREFIX CAND_BOOT MSYS2_ROOT SCRIPT_DIR BOOTSTRAP_WIN DRIVE BOOTSTRAP_POSIX; set -f; IFS=; . $DP_BOOTSTRAP; unset IFS DP_BOOTSTRAP; set +f; exec bash'"
exit /b 0