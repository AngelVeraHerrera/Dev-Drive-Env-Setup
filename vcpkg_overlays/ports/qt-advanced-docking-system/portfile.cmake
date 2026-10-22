# DrivEnv overlay: the official port at baseline 3cd21e48 (4.5.0) moved to upstream 5.1.1, wanted before vcpkg ships
# it. 5.x rewrote its versioning (the version comes from project(), not from git), so both official patches are
# obsolete and dropped; it also installs its licenses under share/ads, removed below. Packaging is otherwise the same:
# find_package(qtadvanceddocking-qt6 CONFIG REQUIRED), target ads::qtadvanceddocking-qt6. See vcpkg_overlays/README.md.
# Retire this overlay once vcpkg ships 5.1.1 or later.
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO githubuser0xFFFF/Qt-Advanced-Docking-System
    REF "v${VERSION}"
    SHA512 a2b4ad4887733b3126e4a5f3c9973e058e0a7f408f213dd24e3c55e90258b28ec448d6af0602d397e6c16cabe402f436ae33c96b93f5504db5fa7802359263f4
    HEAD_REF master
)

if(VCPKG_CROSSCOMPILING)
    list(APPEND _qarg_OPTIONS "-DQT_HOST_PATH=${CURRENT_HOST_INSTALLED_DIR}")
    list(APPEND _qarg_OPTIONS "-DQT_HOST_PATH_CMAKE_DIR:PATH=${CURRENT_HOST_INSTALLED_DIR}/share")
endif()

string(COMPARE EQUAL "${VCPKG_LIBRARY_LINKAGE}" "static" BUILD_STATIC)
vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        ${_qarg_OPTIONS}
        -DBUILD_EXAMPLES=OFF
        -DQT_VERSION_MAJOR=6
        -DBUILD_STATIC=${BUILD_STATIC}
)
vcpkg_cmake_install()
vcpkg_copy_pdbs()
vcpkg_cmake_config_fixup(PACKAGE_NAME "qtadvanceddocking-qt6" CONFIG_PATH "lib/cmake/qtadvanceddocking-qt6")

vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/share/qtadvanceddocking-qt6/qtadvanceddocking-qt6Config.cmake"
"include(CMakeFindDependencyMacro)"
[[include(CMakeFindDependencyMacro)
find_dependency(Qt6 COMPONENTS Core Gui Widgets)]])

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/share")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/share/ads")

file(INSTALL "${SOURCE_PATH}/gnu-lgpl-v2.1.md" DESTINATION "${CURRENT_PACKAGES_DIR}/share/${PORT}")
vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
