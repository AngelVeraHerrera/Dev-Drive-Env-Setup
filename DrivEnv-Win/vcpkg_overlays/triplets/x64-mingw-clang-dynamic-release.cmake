# =====================================================================
# DEVSYSTEM MINGW-CLANG64 CONTROLLED TRIPLET
# Target: x64-mingw-clang-dynamic-release
# =====================================================================

# Initial log.
message(STATUS "[VCPKG-TRIPLET] Using <x64-mingw-clang-dynamic-release> custom LLVM/Clang triplet.")

# Target ABI and linkage
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE dynamic)
set(VCPKG_CMAKE_SYSTEM_NAME MinGW)

# Force Clang compilers for CMake toolchains inside vcpkg
set(VCPKG_C_COMPILER clang)
set(VCPKG_CXX_COMPILER clang++)
set(VCPKG_AR llvm-ar)
set(VCPKG_RANLIB llvm-ranlib)

set(ENV{CC} "clang")
set(ENV{CXX} "clang++")
set(ENV{AR} "llvm-ar")
set(ENV{RANLIB} "llvm-ranlib")

# THREE THINGS AUTOTOOLS ASSUMES ABOUT A MINGW TOOLCHAIN THAT ARE NOT TRUE OF CLANG64.
#
# 1. libtool classifies a Windows import library by running "$OBJDUMP -f" and matching the output against
#    deplibs_check_method, which is "file_magic ^x86 archive import|^x86 DLL". That needs GNU binutils'
#    spelling, "pei-x86-64". CLANG64 ships LLVM's objdump, which says "coff-x86-64" instead, and MSYS2
#    publishes no binutils package for CLANG64 to point it at -- only lld. So the test fails for EVERY Windows
#    system library (ws2_32, kernel32, user32, gdi32) and libtool refuses to link against libraries that are
#    perfectly fine. pass_all tells it to stop second-guessing the linker; a genuinely missing library still
#    fails, at the linker, where it should.
set(ENV{lt_cv_deplibs_check_method} "pass_all")

# 2. Past max_cmd_len, libtool writes the object list into a GNU ld linker script -- a file containing
#    INPUT( ... ) -- and passes that instead. ld.lld cannot read one: linker scripts are an ELF feature and
#    lld's MinGW driver is COFF, so it reports "unknown file type" and the link dies. The detour is not even
#    needed: libtool caches 8192, the real Windows CreateProcess limit is 32767, and the object list that
#    triggered this was 11375 bytes. Raising the threshold stops the linker script being generated at all.
set(ENV{lt_cv_sys_max_cmd_len} "32000")

# 3. mingw-w64's headers only route printf and friends through the C99-conformant implementation when
#    __USE_MINGW_ANSI_STDIO is set. GCC's C++ driver defines it implicitly; clang does not, so a library that
#    checks stops the build outright -- libbson does exactly that:
#        bson/compat.h:24: error: "__USE_MINGW_ANSI_STDIO > 0 is required for correct PRI* macros"
#    Setting it matches what a GCC build already gets, and without it the PRI* width macros would genuinely
#    misbehave rather than merely warn.
set(VCPKG_C_FLAGS   "-D__USE_MINGW_ANSI_STDIO=1")
set(VCPKG_CXX_FLAGS "-D__USE_MINGW_ANSI_STDIO=1")

# AND ONE ABOUT THE RUNTIME LIBRARY.
#
# libtool links shared libraries with -nostdlib and then rebuilds the runtime library list itself, from the
# postdeps it derived by parsing "clang++ -v". clang links compiler-rt's builtins by ABSOLUTE PATH rather than
# with -l -- "clang --print-libgcc-file-name" returns .../lib/clang/22/lib/windows/libclang_rt.builtins-
# x86_64.a -- and libtool's parser keeps the -L for that directory while dropping the absolute-path archive.
# The result is a link that can see the directory but never asks for the library, and every object clang
# compiled with a stack probe fails on "undefined symbol: ___chkstk_ms". The search path is already on the
# command line, so naming the library is enough. A GCC triplet needs none of this: it gets ___chkstk_ms from
# libgcc, which libtool does keep.
set(VCPKG_LINKER_FLAGS "-lclang_rt.builtins-x86_64")

# Policies suitable for MinGW / LLVM
set(VCPKG_POLICY_ALLOW_OBSOLETE_MSVCRT enabled)
set(VCPKG_POLICY_DLLS_WITHOUT_LIBS enabled)

# Pass CC/CXX to external build tools (like Autotools/Make used by FFmpeg or GStreamer)
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
set(VCPKG_ENV_PASSTHROUGH MSYSTEM MSYS2_PATH_TYPE CC CXX AR RANLIB lt_cv_deplibs_check_method lt_cv_sys_max_cmd_len)
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


# System processor hint (needed for Qt, OpenCV and pkg-config logic)
set(VCPKG_CMAKE_SYSTEM_PROCESSOR x86_64)

# Build type — only release binaries
set(VCPKG_BUILD_TYPE release)

# Optional: ensure no debug packages even if referenced
set(VCPKG_DISABLE_METRICS ON)