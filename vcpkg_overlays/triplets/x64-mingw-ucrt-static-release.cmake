# =====================================================================
# DEVSYSTEM MINGW64 CONTROLLED TRIPLET -- STATIC LIBRARIES
# Target: x64-mingw-ucrt-static-release
# =====================================================================
#
# Identical to the dynamic triplet except for VCPKG_LIBRARY_LINKAGE. It
# provides a FULLY static build: every package installed under it, and all
# of their dependencies, are static archives in their own installed tree.
#
# NOTHING USES IT. This environment is dynamic throughout, by policy, and
# no entry in vcpkg.packages selects this triplet. It is kept as a
# CAPABILITY: use it when a whole dependency closure has to be static and
# a separate installed tree is acceptable.
#
# It was written for Fast DDS, whose MinGW DLL does not export the vtable
# of TypeSupport, so nothing defining a DDS type can link it. Forcing
# linkage in that port's own portfile turned out to be the better tool --
# same installed tree, one CMAKE_PREFIX_PATH, dependencies left dynamic,
# so a process linking Fast DDS alongside Qt or curl does not end up with
# two OpenSSL instances. Fast DDS is no longer installed here in any case.
#
# ONE TRAP TO EXPECT, whatever you build under this triplet: a library
# that unconditionally compiles a Windows resource script will fail here.
# A .rc typically gates its contents on the <target>_EXPORTS macro, which
# CMake defines only for SHARED and MODULE targets, so under static
# linkage it preprocesses to nothing and windres reports
#
#     windres.exe: no resources
#
# and exits 1 before a single object exists. Fast CDR is a known instance
# and had an overlay for exactly this; see installation/vcpkg_overlays.txt,
# section DEFERRED. Expect to need the same one-line guard elsewhere.
#
# NOTE the CRT stays DYNAMIC. On MinGW that is the UCRT DLL, which is what
# every other package here links; a static CRT would give each library its
# own copy of errno and the locale tables.

message(STATUS "[VCPKG-TRIPLET] Using <x64-mingw-ucrt-static-release> custom triplet.")

set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME MinGW)

set(VCPKG_POLICY_ALLOW_OBSOLETE_MSVCRT enabled)
set(VCPKG_POLICY_DLLS_WITHOUT_LIBS enabled)

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


set(VCPKG_CMAKE_SYSTEM_PROCESSOR x86_64)
set(VCPKG_BUILD_TYPE release)
set(VCPKG_DISABLE_METRICS ON)
