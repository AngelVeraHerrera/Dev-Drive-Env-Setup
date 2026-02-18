# =====================================================================
#  DEGORAS overlay port for static build
# =====================================================================

set(VCPKG_LIBRARY_LINKAGE static)

# This port needs to be updated at the same time as libbson
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO mongodb/mongo-c-driver
    REF "${VERSION}"
    SHA512 2f751bf33410f084e083fc73d8ebb138e40c956e9bccb2ca460d33ab5e6b75793e1910defb1d5faad849a9668e0afc5024179ad323beacd75a12538f2abda270
    HEAD_REF master
    PATCHES
        disable-dynamic-when-static.patch
        fix-include-directory.patch
        fix-mingw.patch
        remove_abs_patch.cmake
)
file(WRITE "${SOURCE_PATH}/VERSION_CURRENT" "${VERSION}")
file(TOUCH "${SOURCE_PATH}/src/utf8proc-editable")
file(GLOB vendored_libs "${SOURCE_PATH}/src/utf8proc-*" "${SOURCE_PATH}/src/zlib-*/*.h")
file(REMOVE_RECURSE ${vendored_libs})

# Cannot use string(COMPARE EQUAL ...)
set(ENABLE_STATIC OFF)
if(VCPKG_LIBRARY_LINKAGE STREQUAL "static")
    set(ENABLE_STATIC ON)
endif()

vcpkg_check_features(OUT_FEATURE_OPTIONS OPTIONS
    FEATURES
        snappy      ENABLE_SNAPPY
        zstd        ENABLE_ZSTD
)

if("openssl" IN_LIST FEATURES)
    list(APPEND OPTIONS -DENABLE_SSL=OPENSSL)
elseif(VCPKG_TARGET_IS_WINDOWS)
    list(APPEND OPTIONS -DENABLE_SSL=WINDOWS)
elseif(VCPKG_TARGET_IS_OSX OR VCPKG_TARGET_IS_IOS)
    list(APPEND OPTIONS -DENABLE_SSL=DARWIN)
else()
    list(APPEND OPTIONS -DENABLE_SSL=OFF)
endif()

if(VCPKG_TARGET_IS_ANDROID)
    vcpkg_list(APPEND OPTIONS -DENABLE_SRV=OFF)
endif()

vcpkg_find_acquire_program(PKGCONFIG)

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    DISABLE_PARALLEL_CONFIGURE
    OPTIONS
        ${OPTIONS}
        "-DBUILD_VERSION=${VERSION}"
        -DUSE_BUNDLED_UTF8PROC=OFF
        -DUSE_SYSTEM_LIBBSON=ON
        -DENABLE_CLIENT_SIDE_ENCRYPTION=OFF
        -DENABLE_EXAMPLES=OFF
        -DENABLE_SASL=OFF
        -DENABLE_SHM_COUNTERS=OFF
        -DENABLE_STATIC=${ENABLE_STATIC}
        -DENABLE_TESTS=OFF
        -DBUILD_TESTING=OFF
        -DENABLE_UNINSTALL=OFF
        -DENABLE_ZLIB=SYSTEM
        "-DPKG_CONFIG_EXECUTABLE=${PKGCONFIG}"
    MAYBE_UNUSED_VARIABLES
        PKG_CONFIG_EXECUTABLE
)

vcpkg_cmake_install()
vcpkg_copy_pdbs()

# Quita referencias a utf8proc en .pc para que PkgConfig no inyecte -lutf8proc
foreach(pc IN ITEMS
    "${CURRENT_PACKAGES_DIR}/lib/pkgconfig/libmongoc-1.0.pc"
    "${CURRENT_PACKAGES_DIR}/lib/pkgconfig/libmongoc-static-1.0.pc"
    "${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig/libmongoc-1.0.pc"
    "${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig/libmongoc-static-1.0.pc"
)
    if(EXISTS "${pc}")
        vcpkg_replace_string("${pc}" "-lutf8proc" "")
        vcpkg_replace_string("${pc}" "libutf8proc" "")
    endif()
endforeach()

vcpkg_fixup_pkgconfig()

if("snappy" IN_LIST FEATURES AND VCPKG_LIBRARY_LINKAGE STREQUAL "static")
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/lib/pkgconfig/libmongoc-static-1.0.pc" " -lSnappy::snappy" "")
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/lib/pkgconfig/libmongoc-static-1.0.pc" "Requires: " "Requires: snappy ")
    if(NOT VCPKG_BUILD_TYPE)
        vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig/libmongoc-static-1.0.pc" " -lSnappy::snappy" "")
        vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/debug/lib/pkgconfig/libmongoc-static-1.0.pc" "Requires: " "Requires: snappy ")
    endif()
endif()
vcpkg_fixup_pkgconfig()

# -------------------------------------------------------------------
# Limpieza extra: eliminar -lutf8proc de los targets exportados
# -------------------------------------------------------------------

# Quita referencias a -lutf8proc en los ficheros CMake exportados
foreach(cfg IN ITEMS
    "${CURRENT_PACKAGES_DIR}/share/mongoc-1.0/mongoc-1.0-targets.cmake"
    "${CURRENT_PACKAGES_DIR}/share/libmongoc-1.0/libmongoc-1.0-targets.cmake"
    "${CURRENT_PACKAGES_DIR}/share/libmongoc-static-1.0/libmongoc-static-1.0-targets.cmake"
)
    if(EXISTS "${cfg}")
        vcpkg_replace_string("${cfg}" "-lutf8proc" "")
        vcpkg_replace_string("${cfg}" "utf8proc" "utf8proc::utf8proc")
    endif()
endforeach()

# También corrige mongoc-static-1.0-config.cmake si contiene texto literal
foreach(cfg IN ITEMS
    "${CURRENT_PACKAGES_DIR}/share/libmongoc-static-1.0/libmongoc-static-1.0-config.cmake"
    "${CURRENT_PACKAGES_DIR}/share/mongoc-1.0/mongoc-1.0-config.cmake"
)
    if(EXISTS "${cfg}")
        vcpkg_replace_string("${cfg}" "-lutf8proc" "")
        vcpkg_replace_string("${cfg}" "utf8proc" "utf8proc::utf8proc")
    endif()
endforeach()

# deprecated
vcpkg_cmake_config_fixup(PACKAGE_NAME libmongoc-1.0 CONFIG_PATH "lib/cmake/libmongoc-1.0" DO_NOT_DELETE_PARENT_CONFIG_PATH)
if(VCPKG_LIBRARY_LINKAGE STREQUAL "static")
    vcpkg_cmake_config_fixup(PACKAGE_NAME libmongoc-static-1.0 CONFIG_PATH "lib/cmake/libmongoc-static-1.0" DO_NOT_DELETE_PARENT_CONFIG_PATH)
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/include/mongoc/mongoc-macros.h"
        "#define MONGOC_MACROS_H" "#define MONGOC_MACROS_H\n#ifndef MONGOC_STATIC\n#define MONGOC_STATIC\n#endif")
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/share/libmongoc-1.0/libmongoc-1.0-config.cmake" "mongoc_shared" "mongoc_static")
endif()
# recommended
vcpkg_cmake_config_fixup(PACKAGE_NAME mongoc-1.0 CONFIG_PATH "lib/cmake/mongoc-1.0")

file(REMOVE_RECURSE
    "${CURRENT_PACKAGES_DIR}/debug/include"
    "${CURRENT_PACKAGES_DIR}/debug/share"
)

file(INSTALL "${CMAKE_CURRENT_LIST_DIR}/usage" DESTINATION  "${CURRENT_PACKAGES_DIR}/share/${PORT}")

vcpkg_install_copyright(
    FILE_LIST
        "${SOURCE_PATH}/COPYING"
        "${SOURCE_PATH}/THIRD_PARTY_NOTICES"
        "${SOURCE_PATH}/src/libmongoc/THIRD_PARTY_NOTICES"
)

vcpkg_replace_string(
    "${CURRENT_PACKAGES_DIR}/share/libmongoc-1.0/libmongoc-1.0-config.cmake"
    "find_dependency(unofficial-utf8proc CONFIG)"
    "find_dependency(utf8proc CONFIG)"
)

