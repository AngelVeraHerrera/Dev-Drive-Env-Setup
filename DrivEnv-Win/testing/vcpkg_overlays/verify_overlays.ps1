# =====================================================================
# DID THE OVERLAY PORTS ACTUALLY DO THEIR JOB?
# =====================================================================
#
# Run this after generating an environment, or after any vcpkg baseline
# bump, from the environment's own launcher.
#
# WHY IT EXISTS: every defect the remaining overlays fix is invisible to
# the build. All three produce a green build when broken, and fail later
# somewhere that does not mention them.
#
#   fastfeat    the import library names fastfeat.dll while MinGW writes
#               libfastfeat.dll, so consumers LINK cleanly and die at
#               LOAD time. The cascade ends in gstreamer losing its
#               whole ffmpeg bridge, and nothing in it says "fastfeat".
#
#   gstreamer   a plugin that fails to load is reported by gst-inspect
#               as "failed to load plugin" with no reason given, long
#               after the build finished. And its d3d11 config header is
#               installed under lib/, then deleted, while the installed
#               gstd3d11.h still includes it -- which only breaks a C++
#               consumer of that API, never a pipeline.
#
#   vcpkg-qmake has no consumers in the current package set at all, so a
#               green build proves nothing about it either way. Reported
#               here so that is on the record rather than assumed.
#
# A green build is therefore not evidence. This checks the artefacts and
# the loader instead.
#
# Exit code 0 when every check that ran passed, 1 otherwise.
# =====================================================================

param(
    [string]$Root,
    [string]$Mingw = $env:MINGW_ROOT
)

$ErrorActionPreference = 'Continue'

if (-not $Root) {
    if (-not $env:VCPKG_ROOT -or -not $env:VCPKG_DEFAULT_TRIPLET) {
        Write-Output "VCPKG_ROOT / VCPKG_DEFAULT_TRIPLET are not set. Run this from the environment launcher,"
        Write-Output "or pass -Root <vcpkg>/installed/<triplet> explicitly."
        exit 1
    }
    $Root = Join-Path $env:VCPKG_ROOT ("installed/" + $env:VCPKG_DEFAULT_TRIPLET)
}
if (-not $Mingw) { $Mingw = 'S:/msys64/ucrt64' }

$script:checks = 0
$script:failed = 0
$script:skipped = 0

function Check {
    param([bool]$Ok, [string]$What, [string]$Detail = '')
    $script:checks++
    if ($Ok) { Write-Output ("  [ OK ] " + $What) }
    else {
        $script:failed++
        if ($Detail) { Write-Output ("  [FAIL] " + $What + "  ->  " + $Detail) }
        else { Write-Output ("  [FAIL] " + $What) }
    }
}
function Skip { param([string]$What, [string]$Why) ; $script:skipped++ ; Write-Output ("  [skip] " + $What + "  --  " + $Why) }

Write-Output "====================================================================="
Write-Output " OVERLAY VERIFICATION"
Write-Output "====================================================================="
Write-Output ("  installed tree : " + $Root)
Write-Output ("  mingw          : " + $Mingw)
if (-not (Test-Path $Root)) { Write-Output "  the installed tree does not exist"; exit 1 }

$objdump = Join-Path $Mingw 'bin/objdump.exe'
$gpp     = Join-Path $Mingw 'bin/g++.exe'

# PATH is REPLACED, not prepended, and that is the whole difference between this script working and lying.
# Prepending leaves whatever was already there behind $Root/bin, so a DLL missing from the tree under test can be
# satisfied by an identically named one from ANOTHER installed tree, and the load check passes on a broken tree.
# Caught doing exactly that: a scratch tree with the unfixed fastfeat reported its consumer as loading fine,
# because the working drive's correctly named fastfeat.dll was still reachable further down PATH. This is the
# mixed-environment hazard ../README.txt warns about, and a verification script is the last place it belongs.
$env:PATH = @(
    (Join-Path $Root 'bin')
    (Join-Path $Mingw 'bin')
    "$env:SystemRoot\System32"
    "$env:SystemRoot"
) -join ';'

# ---------------------------------------------------------------------------------------------------------------------
# fastfeat: does every import library promise a file that exists?
# ---------------------------------------------------------------------------------------------------------------------
Write-Output ""
Write-Output "fastfeat -- the name the import library promises"
Write-Output "---------------------------------------------------------------------"

# Read the name from the CONSUMER, not from the import library. objdump -p reports no "DLL Name" at all for a
# MinGW import archive (measured: zero matches on libfastfeat.dll.a), but it does report what a linked DLL
# imports -- which is where the wrong name ends up and therefore the only place worth reading it.
#
# Narrowed to fastfeat on purpose. Checking that EVERY imported DLL exists on disk looks more thorough and is
# useless: the api-ms-win-crt-*.dll imports are API sets resolved by the OS through apisetschema, not files, so
# they all read as missing and drown the one import that matters.
$ffDll = Get-ChildItem (Join-Path $Root 'bin') -Filter '*fastfeat*.dll' -ErrorAction SilentlyContinue

if (-not $ffDll) {
    Skip 'fastfeat naming' 'not installed (nothing pulled svt-av1)'
} elseif (-not (Test-Path $objdump)) {
    Skip 'fastfeat naming' "objdump not found at $objdump"
} else {
    foreach ($d in $ffDll) { Write-Output ("         installed DLL  : " + $d.Name) }

    $wanted = @()
    foreach ($consumer in (Get-ChildItem (Join-Path $Root 'bin') -Filter '*.dll' -ErrorAction SilentlyContinue)) {
        $names = & $objdump -p $consumer.FullName 2>$null |
                 Select-String -Pattern 'DLL Name:\s*(\S*fastfeat\S*\.dll)' -AllMatches |
                 ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value }
        foreach ($n in $names) { $wanted += [pscustomobject]@{ By = $consumer.Name; Needs = $n } }
    }

    if (-not $wanted) {
        Skip 'fastfeat naming' 'no installed DLL imports fastfeat, so the name cannot be wrong yet'
    } else {
        foreach ($w in ($wanted | Sort-Object Needs, By -Unique)) {
            $exists = Test-Path (Join-Path $Root ('bin/' + $w.Needs))
            Check $exists ($w.By + " imports " + $w.Needs + ", and that file exists") 'ERROR_MOD_NOT_FOUND at load time'
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# the loader: the cascade fastfeat breaks, checked where it actually breaks
# ---------------------------------------------------------------------------------------------------------------------
Write-Output ""
Write-Output "the loader -- can the built DLLs be loaded at all?"
Write-Output "---------------------------------------------------------------------"

if (-not ('Win32Loader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Win32Loader {
    [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr LoadLibraryW(string path);
    [DllImport("kernel32")] public static extern uint GetLastError();
}
'@ -ErrorAction SilentlyContinue
}

$anyLoaded = $false
foreach ($pattern in @('libSvtAv1Enc.dll', 'avcodec-*.dll', 'libgstlibav.dll', 'libgstsvtav1.dll')) {
    $hits = Get-ChildItem $Root -Recurse -Filter $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $hits) { continue }
    $anyLoaded = $true
    $h = [Win32Loader]::LoadLibraryW($hits.FullName)
    if ($h -eq [IntPtr]::Zero) {
        Check $false ($hits.Name + " loads") ("win32 error " + [Win32Loader]::GetLastError() + " (126 = ERROR_MOD_NOT_FOUND)")
    } else {
        Check $true ($hits.Name + " loads")
    }
}
if (-not $anyLoaded) { Skip 'loader checks' 'none of the affected libraries are installed' }

# ---------------------------------------------------------------------------------------------------------------------
# gstreamer delta 9: the d3d11 config header, and a real consumer of it
# ---------------------------------------------------------------------------------------------------------------------
Write-Output ""
Write-Output "gstreamer -- the d3d11 config header the port used to delete"
Write-Output "---------------------------------------------------------------------"

$d3d11Header = Join-Path $Root 'include/gstreamer-1.0/gst/d3d11/gstd3d11.h'
if (-not (Test-Path $d3d11Header)) {
    Skip 'gstd3d11config.h' 'the d3d11 helper API is not installed (no plugins-bad?)'
} else {
    $cfg = Join-Path $Root 'include/gstreamer-1.0/gst/d3d11/gstd3d11config.h'
    Check (Test-Path $cfg) 'gstd3d11config.h sits beside the header that includes it' 'gstd3d11.h line 28 includes it'

    $pc = Join-Path $Root 'lib/pkgconfig/gstreamer-d3d11-1.0.pc'
    if (Test-Path $pc) {
        $stale = Select-String -Path $pc -Pattern 'libdir\}/gstreamer-1\.0/include' -Quiet
        Check (-not $stale) 'gstreamer-d3d11-1.0.pc does not point at the deleted directory'
    }

    # The decisive one: the defect above is only observable from a consumer.
    if (Test-Path $gpp) {
        $scratch = Join-Path $env:TEMP 'dp-overlay-probe'
        New-Item -ItemType Directory -Force -Path $scratch | Out-Null
        $src = Join-Path $scratch 'probe.cpp'
        @'
#include <gst/gst.h>
#include <gst/d3d11/gstd3d11.h>
int main() { gst_init(nullptr, nullptr); return 0; }
'@ | Set-Content -Path $src -Encoding utf8
        $inc = @("-I$Root/include/gstreamer-1.0", "-I$Root/include/glib-2.0", "-I$Root/lib/glib-2.0/include", "-I$Root/include")
        $out = & $gpp -std=c++17 -fsyntax-only @inc $src 2>&1 | Out-String
        $rc = $LASTEXITCODE
        Check ($rc -eq 0) 'a C++ consumer can #include <gst/d3d11/gstd3d11.h>' (($out -split "`n" | Where-Object { $_ -match 'fatal|error' } | Select-Object -First 1))
    } else {
        Skip 'C++ consumer probe' "g++ not found at $gpp"
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# gstreamer: the plugin registry. A plugin that cannot load says so here and nowhere else.
# ---------------------------------------------------------------------------------------------------------------------
Write-Output ""
Write-Output "gstreamer -- the plugin registry"
Write-Output "---------------------------------------------------------------------"

$inspect = Join-Path $Root 'tools/gstreamer/gst-inspect-1.0.exe'
if (-not (Test-Path $inspect)) {
    Skip 'plugin registry' 'gst-inspect-1.0 not installed'
} else {
    # An isolated registry, so a stale cache cannot make a broken tree look healthy.
    $env:GST_PLUGIN_PATH = Join-Path $Root 'plugins/gstreamer'
    $env:GST_PLUGIN_SYSTEM_PATH = ''
    $env:GST_REGISTRY = Join-Path $env:TEMP 'dp-overlay-probe-registry.bin'
    Remove-Item $env:GST_REGISTRY -ErrorAction SilentlyContinue
    $env:GST_DEBUG = '1'

    $out = & $inspect 2>&1 | Out-String
    $failedLoads = ([regex]::Matches($out, 'Failed to load plugin')).Count
    $total = ($out -split "`n" | Where-Object { $_ -match 'Total count:' } | Select-Object -First 1)
    if ($total) { Write-Output ("        " + $total.Trim()) }

    Check ($failedLoads -eq 0) 'every plugin in the tree loads' ("$failedLoads failed -- rerun with GST_DEBUG=3 for the reason")
    if ($failedLoads -gt 0) {
        ($out -split "`n" | Where-Object { $_ -match 'Failed to load plugin' } | Select-Object -First 4) |
            ForEach-Object { Write-Output ("           " + $_.Trim()) }
    }

    # svtav1enc is the element the fastfeat cascade takes out, and it is the cheapest single indicator.
    $r = & $inspect 'svtav1enc' 2>&1 | Out-String
    if ($out -match 'svtav1') { Check ($r -match 'Factory Details') 'svtav1enc exists (the fastfeat cascade is not active)' }
    else { Skip 'svtav1enc' 'the svtav1 plugin is not part of this build' }
}

# ---------------------------------------------------------------------------------------------------------------------
# vcpkg-qmake: on the record, because a green build says nothing about it
# ---------------------------------------------------------------------------------------------------------------------
Write-Output ""
Write-Output "vcpkg-qmake -- dormant insurance, reported not tested"
Write-Output "---------------------------------------------------------------------"
Write-Output "  The overlay makes qmake-built ports use GNU make instead of jom on a"
Write-Output "  MinGW target. qtbase does NOT consume it -- it only produces the"
Write-Output "  qt_*.conf files it reads -- and its only consumers repo-wide are"
Write-Output "  qcustomplot, qscintilla and qwt. If none of those is installed, this"
Write-Output "  overlay is not exercised by anything and no check here can cover it."

# ---------------------------------------------------------------------------------------------------------------------
Write-Output ""
Write-Output "====================================================================="
Write-Output (" " + ($script:checks - $script:failed) + " of " + $script:checks + " checks passed, " + $script:skipped + " skipped")
Write-Output "====================================================================="
exit $(if ($script:failed -eq 0) { 0 } else { 1 })
