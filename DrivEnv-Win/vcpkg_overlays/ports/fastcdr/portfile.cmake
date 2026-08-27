# ---------------------------------------------------------------------------------------------------------------------
# LOCAL OVERLAY of the upstream fastcdr port. ONE delta, and only for a STATIC build:
#   mingw-static-no-resource.patch -- FastCdr.rc is added to the sources unconditionally upstream.
#
# A resource script belongs in a DLL or an EXE, not in a static archive, and windres does not shrug at it:
#
#     windres.exe: no resources
#     ninja: build stopped: subcommand failed.
#
# With BUILD_SHARED_LIBS=OFF the guarded body of the .rc compiles to nothing, windres treats an empty result as an
# error, and the build dies before a single object exists. The patch adds the file only for a shared build.
#
# Needed because Fast DDS is built statically here on purpose: its MinGW DLL does not export the vtable of
# TypeSupport nor the traits<>::make_shared instantiations, so publish/subscribe cannot link against the shared
# build. A static archive has no export table and the problem cannot arise.
# ---------------------------------------------------------------------------------------------------------------------

vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO eProsima/Fast-CDR
    REF "v${VERSION}"
    SHA512 5c53d2b5abb433b8065e6eb3d819c60cc0e0fd7f25e92eb5d6e501c0590f47c90717f32c90c2b4b3a953454cad2e34094caa80845d763a8f0f97df56dba2963e
    HEAD_REF master
    PATCHES
        pdb-file.patch
        mingw-static-no-resource.patch
)

vcpkg_cmake_configure(
    SOURCE_PATH ${SOURCE_PATH})

vcpkg_cmake_install()

vcpkg_cmake_config_fixup(CONFIG_PATH lib/cmake/fastcdr)

vcpkg_copy_pdbs()

file(REMOVE_RECURSE ${CURRENT_PACKAGES_DIR}/debug/include ${CURRENT_PACKAGES_DIR}/lib/fastcdr ${CURRENT_PACKAGES_DIR}/debug/lib/fastcdr)
file(REMOVE_RECURSE ${CURRENT_PACKAGES_DIR}/debug/share)

if(VCPKG_LIBRARY_LINKAGE STREQUAL "dynamic")
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/include/fastcdr/eProsima_auto_link.h" "(defined(_DLL) || defined(_RTLDLL)) && defined(EPROSIMA_DYN_LINK)" "1")
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/include/fastcdr/fastcdr_dll.h" "defined(FASTCDR_DYN_LINK)" "1")
endif()

vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
