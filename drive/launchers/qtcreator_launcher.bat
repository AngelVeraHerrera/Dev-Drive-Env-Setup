@echo off
chcp 65001 >nul
setlocal EnableExtensions DisableDelayedExpansion

REM ===================================================================
REM QT CREATOR IN ONE TOOLCHAIN'S ENVIRONMENT
REM Author: Ángel Vera Herrera
REM Version: 261020
REM ===================================================================
REM
REM A template: step 7 writes it per toolchain as <stem>_qtcreator.bat, with the three paths below filled in.
REM It opens the drive's one Qt Creator in that toolchain's environment, loaded as its shell loads it (MSYS2 and
REM <stem>_env_launcher_bootstrap.sh). Every toolchain's launcher opens the same Qt Creator and kits; build each
REM kit from its own toolchain's launcher.
REM   -settingspath         user settings: sessions, preferences, recent projects
REM   -installsettingspath  the kits step 7 registered with sdktool

set "QTC_EXE=@QTCREATOR_EXE@"
set "QTC_SETTINGS=@SETTINGS_PATH@"
set "QTC_INSTALL_SETTINGS=@INSTALL_SETTINGS_PATH@"

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
for %%I in ("%SCRIPT_DIR%\..") do set "ENV_DIR=%%~fI"

REM ---------------------------------------------------------------
REM Which environment: the one this file is named after
REM ---------------------------------------------------------------
REM Named from the stem, like the shell launcher: <stem>_env_variables.env, <stem>_env_launcher_bootstrap.sh (step 2)
REM and <stem>_qtcreator_launcher.sh (step 7). 10 is the length of "_qtcreator".
set "SELF=%~n0"
if /i not "%SELF:~-10%"=="_qtcreator" (
    echo [ERROR] This launcher must be named ^<stem^>_qtcreator.bat, and it is "%SELF%.bat".
    echo         Its name is how it finds its toolchain's environment.
    goto :fail
)
set "STEM=%SELF:~0,-10%"

set "ENV_FILE=%ENV_DIR%\%STEM%_env_variables.env"
set "BOOTSTRAP_SCRIPT=%SCRIPT_DIR%\%STEM%_env_launcher_bootstrap.sh"
set "LAUNCH_SCRIPT=%SCRIPT_DIR%\%STEM%_qtcreator_launcher.sh"

if not exist "%ENV_FILE%" (
    echo [ERROR] Environment file not found:
    echo         "%ENV_FILE%"
    echo         This launcher opens Qt Creator in the environment "%STEM%"; step 2 of the generator writes its file.
    goto :fail
)

if not exist "%BOOTSTRAP_SCRIPT%" (
    echo [ERROR] The environment's bootstrap was not found:
    echo         "%BOOTSTRAP_SCRIPT%"
    echo         Step 2 of the generator deploys it.
    goto :fail
)

if not exist "%LAUNCH_SCRIPT%" (
    echo [ERROR] Qt Creator's launch script was not found:
    echo         "%LAUNCH_SCRIPT%"
    echo         Step 7 of the generator deploys it.
    goto :fail
)

if not exist "%QTC_EXE%" (
    echo [ERROR] Qt Creator not found:
    echo         "%QTC_EXE%"
    echo         Run step 2 for the toolchain whose subsystem provides it, or fix ide_integration.qtcreator.path, then step 7.
    goto :fail
)

REM ---------------------------------------------------------------
REM Read MSYS2_ROOT and MSYS2_ENV from the env file
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

set "MSYS2_ROOT=%MSYS2_ROOT:/=\%"
set "MSYS2_SHELL=%MSYS2_ROOT%\msys2_shell.cmd"
if not exist "%MSYS2_SHELL%" (
    echo [ERROR] msys2_shell.cmd not found at:
    echo         "%MSYS2_SHELL%"
    goto :fail
)

if not exist "%QTC_INSTALL_SETTINGS%\QtProject\qtcreator\profiles.xml" (
    echo [WARN] No kit registered yet in "%QTC_INSTALL_SETTINGS%". Run step 7 after the toolchains are built.
)
if not exist "%QTC_SETTINGS%" mkdir "%QTC_SETTINGS%"

REM ---------------------------------------------------------------
REM Hand-offs to bash, as variables: never inside the nested quotes
REM ---------------------------------------------------------------
REM Hand-offs as variables, as in env_launcher.bat. POSIX paths for what bash sources; Qt Creator's stay Windows.
set "BOOTSTRAP_WIN=%BOOTSTRAP_SCRIPT:\=/%"
set "ENVFILE_WIN=%ENV_FILE:\=/%"
set "LAUNCH_WIN=%LAUNCH_SCRIPT:\=/%"
set "DP_BOOTSTRAP=/%BOOTSTRAP_WIN:~0,1%%BOOTSTRAP_WIN:~2%"
set "DP_ENVFILE=/%ENVFILE_WIN:~0,1%%ENVFILE_WIN:~2%"
set "DP_QTC_LAUNCH=/%LAUNCH_WIN:~0,1%%LAUNCH_WIN:~2%"
set "DP_QTC_EXE=%QTC_EXE:\=/%"
set "DP_QTC_SETTINGS=%QTC_SETTINGS:\=/%"
set "DP_QTC_INSTALL_SETTINGS=%QTC_INSTALL_SETTINGS:\=/%"

REM Quoted: a path is configuration, and an '&' in it would otherwise end the echo and run the rest as a command.
echo [INFO] Opening Qt Creator in the environment "%STEM%" ...
echo [INFO] MSYS2_ROOT: "%MSYS2_ROOT%"
echo [INFO] Env file:   "%ENV_FILE%"
echo [INFO] Qt Creator: "%QTC_EXE%"
echo.

REM ---------------------------------------------------------------
REM Load the environment, start Qt Creator from it
REM ---------------------------------------------------------------
REM In this window: msys2_shell runs bash here (-defterm -no-start), the bootstrap loads the environment, the .sh starts
REM Qt Creator detached (setsid) and returns; its exit code is ours, so failures are shown below. No pause inside bash
REM (DEV_ENV_NO_PAUSE=1); the caller's setting is kept for the pause here. Unset list as in env_launcher.bat.
set "DP_CALLER_NO_PAUSE=%DEV_ENV_NO_PAUSE%"
set "DEV_ENV_NO_PAUSE=1"
call "%MSYS2_SHELL%" -%MSYS2_ENV% -defterm -no-start -here -c "bash -lc 'unset SELF STEM SCRIPT_DIR ENV_DIR ENV_FILE BOOTSTRAP_SCRIPT LAUNCH_SCRIPT MSYS2_ROOT MSYS2_ENV MSYS2_SHELL BOOTSTRAP_WIN ENVFILE_WIN LAUNCH_WIN QTC_EXE QTC_SETTINGS QTC_INSTALL_SETTINGS DP_CALLER_NO_PAUSE; IFS=; . $DP_BOOTSTRAP; . $DP_QTC_LAUNCH'"
set "DP_RC=%ERRORLEVEL%"
set "DEV_ENV_NO_PAUSE=%DP_CALLER_NO_PAUSE%"
if not "%DP_RC%"=="0" (
    echo.
    echo [ERROR] Qt Creator was not started: the environment %STEM% did not load, or the launch failed ^(exit %DP_RC%^).
    goto :fail
)
exit /b 0

:fail
REM Started from a shortcut, the window would close with the message on it unread, so it waits for a key first --
REM unless DEV_ENV_NO_PAUSE says otherwise: set and not 0, no pause.
set "DP_PAUSE=1"
if defined DEV_ENV_NO_PAUSE if not "%DEV_ENV_NO_PAUSE%"=="0" set "DP_PAUSE="
if defined DP_PAUSE (
    echo.
    pause
)
exit /b 1
