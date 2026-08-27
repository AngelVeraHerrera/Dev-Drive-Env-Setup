# =====================================================================
# DEVSYSTEM MINGW64 CONTROLLED TRIPLET -- STATIC LIBRARIES
# Target: x64-mingw-ucrt-static-release
# =====================================================================
#
# Identical to the dynamic triplet except for VCPKG_LIBRARY_LINKAGE. It
# provides a FULLY static build: every package installed under it, and all
# of their dependencies, are static archives in their own installed tree.
#
# It is NOT the way Fast DDS is built here, although it was written for
# that. Forcing linkage in the fastdds portfile turned out to be the
# better tool: same installed tree, one CMAKE_PREFIX_PATH, and the
# dependencies stay dynamic so a process linking Fast DDS alongside Qt or
# curl does not end up with two OpenSSL instances.
#
# Use this triplet when you want the WHOLE dependency closure static and
# accept a separate tree for it. Note that it needs the fastcdr overlay:
# upstream compiles a Windows resource script into the library, and
# windres refuses that in a static build.
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

set(VCPKG_ENV_PASSTHROUGH PATH MSYSTEM MSYS2_PATH_TYPE TMP TEMP)
set(VCPKG_ENV_PASSTHROUGH_UNTRACKED "NUMBER_OF_PROCESSORS;VCPKG_MAX_CONCURRENCY")

set(VCPKG_CMAKE_SYSTEM_PROCESSOR x86_64)
set(VCPKG_BUILD_TYPE release)
set(VCPKG_DISABLE_METRICS ON)
