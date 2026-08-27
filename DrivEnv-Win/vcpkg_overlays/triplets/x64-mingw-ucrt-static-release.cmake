# =====================================================================
# DEVSYSTEM MINGW64 CONTROLLED TRIPLET -- STATIC LIBRARIES
# Target: x64-mingw-ucrt-static-release
# =====================================================================
#
# Identical to the dynamic triplet except for VCPKG_LIBRARY_LINKAGE, and
# it exists for one measured reason: Fast DDS on MinGW builds a DLL whose
# export table is missing the two things a consumer needs to DEFINE a
# type -- the vtable of TypeSupport and the traits<>::make_shared
# instantiations. Both are present in the compiled objects; only the
# table is short, and -DCMAKE_WINDOWS_EXPORT_ALL_SYMBOLS=ON did not fill
# it (no .def was generated at all).
#
# A static library has no export table, so the linker takes the symbols
# straight out of the archive and the problem cannot arise.
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
