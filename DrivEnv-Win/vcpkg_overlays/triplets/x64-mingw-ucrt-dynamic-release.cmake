
# =====================================================================
# DEVSYSTEM MINGW64 CONTROLLED TRIPLET
# Target: x64-mingw-dynamic-devsystem
# Last updated: 2025-11-04
# =====================================================================

# Initial log.
message(STATUS "[VCPKG-TRIPLET] Using <x64-mingw-ucrt-dynamic-release> custom triplet.")

# Target ABI and linkage
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_CMAKE_SYSTEM_NAME MinGW)

# GLIB NEEDS ITS PE TLS DIRECTORY BACK, and this is not a clang problem despite where it was first seen.
#
# glib prints "GLib-CRITICAL **: TLS callback not invoked" from every process that loads it, and it is a true
# positive: the DLL ships with no PE TLS directory, so the loader never calls the callback glib registered and
# glib's per-thread cleanup never runs. Measured: one kernel handle leaked per GLib thread that exits, against
# zero on a build whose directory is intact.
#
# glib's non-MSVC branch of G_DEFINE_TLS_CALLBACK only places the callback pointer in section .CRT$XLCE, where
# the MSVC branch also emits /INCLUDE:_tls_used. _tls_used lives in tlssup.o inside libmingw32.a, and current
# mingw-w64-crt no longer references it from crt2.o or dllcrt2.o, so lazy archive-member extraction never pulls
# it in. Verified on a GCC/ld.bfd drive: its glib has no TLS directory either, while a sibling library linked
# seconds later in the same session has one, because one of its own translation units drags tlssup.o in by
# accident. The discriminator is the crt vintage at link time, not the compiler -- which is why this guard
# belongs here as much as on the clang triplet.
#
# -u forces the linker to treat _tls_used as undefined, which extracts tlssup.o and gives the image a TLS
# directory. Scoped to glib: nothing else in the installed tree carries the construct, and C++ thread_local
# teardown does not depend on this array, since mingw-w64 dispatches __mingw_TLScallback from DllMainCRTStartup.
#
# Delete once the baseline carries glib >= 2.89.4, where GLib MR !5283 landed.
if(PORT STREQUAL "glib")
    set(VCPKG_LINKER_FLAGS "${VCPKG_LINKER_FLAGS} -Wl,-u,_tls_used")
endif()

# Policies suitable for MinGW
set(VCPKG_POLICY_ALLOW_OBSOLETE_MSVCRT enabled)
set(VCPKG_POLICY_DLLS_WITHOUT_LIBS enabled)

# Keep the environment deterministic
# WHICH ENVIRONMENT VARIABLES REACH A BUILD, AND WHICH OF THEM COUNT TOWARDS ITS ABI.
#
# VCPKG_ENV_PASSTHROUGH does two things at once: it lets a variable through to the build, and it hashes the
# variable's VALUE into every package's ABI. VCPKG_ENV_PASSTHROUGH_UNTRACKED does the first without the second.
#
# That distinction was invisible until it was measured. installed/<triplet>/share/<port>/vcpkg_abi_info.txt
# spells it out, one line per input:
#     ENV:PATH   cdd343e4...
#     ENV:TEMP   402406bd...
#     ENV:TMP    402406bd...
# and changing nothing but TMP moved a computed ABI from eb99009b... to b4359276....
#
# PATH, TMP and TEMP differ between two machines BY CONSTRUCTION -- different user profile, different installed
# software -- so while they are tracked the binary cache can never hit across machines. That is not a
# theoretical loss: five separate ABIs were observed for one identical opencv4 build, and copying a perfectly
# good 72 MB artefact from one machine to another could not be made to work at all.
#
# Untracking them does not lose the toolchain guarantee, which was the reason to be careful here. vcpkg hashes
# the compiler SEPARATELY, in the third component of triplet_abi: that component changed from dd583adb... to
# 4f9648e6... when GCC went from 16.2.0-3 to 15.2.0-11 with every other input identical. So a package built by
# a different compiler still gets a different ABI, which is the property that actually matters.
#
# MSYSTEM and MSYS2_PATH_TYPE stay TRACKED. They select which toolchain subsystem is in play -- ucrt64 against
# clang64 against mingw64 -- they hold the same value on every machine, and so they cost nothing to track while
# keeping the ABI honest about something that genuinely changes the output.
set(VCPKG_ENV_PASSTHROUGH MSYSTEM MSYS2_PATH_TYPE)
set(VCPKG_ENV_PASSTHROUGH_UNTRACKED "PATH;TMP;TEMP;NUMBER_OF_PROCESSORS;VCPKG_MAX_CONCURRENCY")

# TEMPORARY FILES STAY ON THE DEV DRIVE.
#
# MSYS2's /etc/profile sets TMP and TEMP to /tmp, so a developer working in the environment's own terminal
# already writes temporaries onto the drive. A vcpkg BUILD does not: vcpkg launches its own MSYS2 out of
# downloads/tools/msys2, which never reads that profile, so a port's configure scratch lands in the Windows
# temp directory on C:. ffmpeg's feature probes were seen creating C:/Users/<user>/AppData/Local/Temp/ffconf.*
# -- small files, but on the system disk, in front of the antivirus, and off the drive this environment exists
# to keep everything on.
#
# The triplet finds the drive from its own path rather than being told: it lives at <drive>:/overlays/triplets/,
# so CMAKE_CURRENT_LIST_FILE carries the letter. Verified with a real cmake -P: the variable holds the absolute
# path and the match yields "L:".
#
# Guarded on the directory existing, so a drive generated before step 1 began creating <drive>:/tmp keeps
# working instead of failing in a way nobody would connect to this file. This is only safe to do because PATH,
# TMP and TEMP are UNTRACKED above -- were TMP still tracked, pinning it here would write the drive letter into
# every package ABI.
if(CMAKE_CURRENT_LIST_FILE MATCHES "^([A-Za-z]:)/")
    set(_devdrive_tmp "${CMAKE_MATCH_1}/tmp")
    if(EXISTS "${_devdrive_tmp}")
        set(ENV{TMP}  "${_devdrive_tmp}")
        set(ENV{TEMP} "${_devdrive_tmp}")
    endif()
    unset(_devdrive_tmp)
endif()


# System processor hint (needed for some Qt and pkg-config logic)
set(VCPKG_CMAKE_SYSTEM_PROCESSOR x86_64)

# Build type — only release binaries
set(VCPKG_BUILD_TYPE release)

# Optional: ensure no debug packages even if referenced
set(VCPKG_DISABLE_METRICS ON)
