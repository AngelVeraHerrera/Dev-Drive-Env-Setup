@echo off
setlocal enabledelayedexpansion

REM =====================================================================
REM   Triplet hash generator
REM ---------------------------------------------------------------------
REM   Writes <name>.sha256 beside every <name>.cmake in this directory.
REM   Step 3 verifies each triplet against its file before installing it.
REM
REM   THE HASH IS OVER NORMALISED CONTENT, NOT OVER THE RAW BYTES, and
REM   that is not a detail. These files live in a git repository used
REM   with core.autocrlf=true, so the same committed bytes reach one
REM   working tree as LF and another as CRLF. A raw byte hash therefore
REM   measures the developer's git configuration rather than the file,
REM   and the check fails on a machine that changed nothing.
REM
REM   Measured, not theorised: x64-mingw-ucrt-static-release.cmake hashes
REM   910B5E89... as LF and 8BAE34F2... as CRLF. A hash generated on one
REM   machine failed on the other, and regenerating it there fixed it
REM   there while breaking it back here.
REM
REM   So: strip a BOM, fold CRLF to LF, then hash. .gitattributes also
REM   marks these files -text so the bytes stay put, and step 3
REM   normalises the same way when it checks. Either guard alone is
REM   fragile; both together are not.
REM
REM   IF A CHECK EVER FAILS, read the diff before running this. The hash
REM   ignores line endings, so a mismatch means the CONTENT changed. That
REM   is the check working.
REM =====================================================================

echo =====================================================
echo   Triplet hash generator (normalised content hash)
echo =====================================================
echo.

set "count=0"

for %%F in (*.cmake) do (
    set "SOURCE_FILE=%%F"
    set "HASH_FILE=%%~nF.sha256"

    echo Processing: "%%F" ...

    powershell -NoProfile -Command ^
        "$p = '%%F';" ^
        "$t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8);" ^
        "if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) };" ^
        "$t = $t -replace \"`r`n\", \"`n\";" ^
        "$s = [System.Security.Cryptography.SHA256]::Create();" ^
        "$h = ([System.BitConverter]::ToString($s.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($t))) -replace '-','').ToUpperInvariant();" ^
        "$s.Dispose();" ^
        "\"$h  $p\" | Out-File -FilePath '!HASH_FILE!' -NoNewline -Encoding ASCII"

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
