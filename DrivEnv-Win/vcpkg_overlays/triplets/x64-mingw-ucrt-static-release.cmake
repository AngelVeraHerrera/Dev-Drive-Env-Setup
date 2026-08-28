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

set(VCPKG_ENV_PASSTHROUGH PATH MSYSTEM MSYS2_PATH_TYPE TMP TEMP)
set(VCPKG_ENV_PASSTHROUGH_UNTRACKED "NUMBER_OF_PROCESSORS;VCPKG_MAX_CONCURRENCY")

set(VCPKG_CMAKE_SYSTEM_PROCESSOR x86_64)
set(VCPKG_BUILD_TYPE release)
set(VCPKG_DISABLE_METRICS ON)
