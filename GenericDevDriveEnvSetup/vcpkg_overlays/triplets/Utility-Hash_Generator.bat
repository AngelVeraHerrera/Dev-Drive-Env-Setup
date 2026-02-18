@echo off
setlocal enabledelayedexpansion

echo =====================================================
echo   Universal Hash Generator (Hash + Filename)
echo =====================================================
echo.

set "count=0"

for %%F in (*.cmake) do (
    set "SOURCE_FILE=%%F"
    set "HASH_FILE=%%~nF.sha256"
    
    echo Processing: "%%F" ...
    
    :: Generate hash with the filename
    powershell -Command "$h = (Get-FileHash '%%F' -Algorithm SHA256).Hash; \"$h  %%F\" | Out-File -FilePath '!HASH_FILE!' -NoNewline -Encoding ASCII"
    
    if exist "!HASH_FILE!" (
        echo [OK] Created: !HASH_FILE!
        set /a count+=1
    ) else (
        echo [ERROR] Failed to create !HASH_FILE!
    )
    echo -----------------------------------------------------
)

echo Completed successfully. %count% files processed.
pause