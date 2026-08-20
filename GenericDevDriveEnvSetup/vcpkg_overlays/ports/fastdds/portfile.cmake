# ---------------------------------------------------------------------------------------------------------------------
# LOCAL OVERLAY of the upstream fastdds port. FOUR deltas, all MinGW-only, all invisible to MSVC:
#   mingw-qos-default-linkage.patch  -- dllexport on an internal-linkage const definition.
#   mingw-no-clock-gettime.patch     -- clock_gettime redefined where mingw-w64 already has it.
#   the tool-copy block below        -- gated off MinGW, where fastdds itself does not build the tools.
#   MINGW_COMPILER propagated        -- without it every consumer hits dllimport-on-a-definition.
#
# GCC refuses to dllexport a namespace-scope const definition, which has internal linkage:
#
#   error: external linkage required for symbol 'eprosima::fastdds::dds::PUBLISHER_QOS_DEFAULT'
#          because of 'dllexport' attribute
#
# Two of the seven QoS defaults repeat FASTDDS_EXPORTED_API on their definition; the other five do not, and
# those five compile. The patch makes the two match. MSVC does not object, so upstream CI never sees it.
# Re-check on every version bump: if upstream drops the redundant macro, delete the patch.
# ---------------------------------------------------------------------------------------------------------------------

vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO eProsima/Fast-DDS
    REF "v${VERSION}"
    SHA512 f9cba9b881b5b34ad496e2123dd1f3303936eab2a0b985207f470e6b5a91a99e8a0d96fa5596bc2ff4babc348e2f2f91a90e612fa9b7c1de2424e036b8d2366a
    HEAD_REF master
    PATCHES
        fix-deps.patch
        disable-autolink.patch
        pdb-file.patch
        disable-test.patch
        disable-werror.patch
        mingw-qos-default-linkage.patch   # LOCAL, see header
        mingw-no-clock-gettime.patch      # LOCAL, see header
)

set(extra_opts "")
if (VCPKG_TARGET_IS_WINDOWS AND VCPKG_TARGET_ARCHITECTURE STREQUAL "arm64")
    # when cross-compiling, try_run will not work.
    set(extra_opts
        -DSM_RUN_RESULT=TRUE
        -DSM_RUN_RESULT__TRYRUN_OUTPUT=
    )
endif()

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DSECURITY=ON
        -DFORCE_CXX=14 # foonathan memory debug needs C++14 constexpr
        ${extra_opts}
)

vcpkg_cmake_install()
vcpkg_copy_pdbs()

vcpkg_cmake_config_fixup(CONFIG_PATH share/fastdds/cmake)

# LOCAL DELTA 4. Propagate MINGW_COMPILER to CONSUMERS.
#
# fastdds_dll.hpp already has a MinGW branch that uses __attribute__((visibility("default"))) instead of
# __declspec(dllimport}, precisely because GCC rejects dllimport on an inline definition and many of these headers
# define constructors and operators in the class body. But that branch is gated on MINGW_COMPILER, which fastdds
# defines only while building ITSELF (add_definitions in its CMakeLists), and the exported target does not pass on.
#
# So every MinGW consumer took the dllimport branch and failed before compiling a line of its own:
#
#     ParameterTypes.hpp:208:26: error: function ...Parameter_t::Parameter_t() definition is marked dllimport
#
# Appending it to the interface definitions fixes it once, for every consumer, instead of asking each of them to
# define an internal macro they should never have to know about. Written as an append to the installed config so it
# survives however vcpkg chooses to lay out the targets files.
if(VCPKG_TARGET_IS_MINGW)
    file(APPEND "${CURRENT_PACKAGES_DIR}/share/${PORT}/fastdds-config.cmake"
"
# Added by the local overlay port: see LOCAL DELTA 4 in its portfile.
if(TARGET fastdds AND MINGW)
    set_property(TARGET fastdds APPEND PROPERTY INTERFACE_COMPILE_DEFINITIONS MINGW_COMPILER=1)
endif()
")
endif()

# LOCAL DELTA 3. fastdds's own CMakeLists turns COMPILE_TOOLS OFF for MinGW -- its decision, not ours:
#
#     if(COMPILER_MACHINE MATCHES "mingw")
#         option(COMPILE_TOOLS "Build tools" OFF)
#
# so tools/ is never added to the build and neither fast-discovery-server nor the .bat wrappers exist. This
# block asked for them on the strength of VCPKG_TARGET_IS_WINDOWS, which is TRUE for MinGW, so the port could
# only ever fail there -- after compiling the entire library:
#
#     Couldn't find tool "fast-discovery-server-1.0.1"
#
# Excluding MinGW leaves the library, headers and CMake config, which is what a consumer links against. The
# discovery server is simply not available on this toolchain; run it from an MSVC build if it is needed.
if(VCPKG_TARGET_IS_WINDOWS AND NOT VCPKG_TARGET_IS_MINGW)
    vcpkg_copy_tools(TOOL_NAMES "fast-discovery-server-1.0.1" AUTO_CLEAN)
    file(INSTALL "${CURRENT_PACKAGES_DIR}/tools/${PORT}/fast-discovery-server-1.0.1.exe"
        DESTINATION "${CURRENT_PACKAGES_DIR}/tools/${PORT}"
        RENAME "fast-discovery-server.exe"
    )

    foreach(TOOL "fastdds.bat" "ros-discovery.bat")
        file(INSTALL "${CURRENT_PACKAGES_DIR}/bin/${TOOL}" DESTINATION "${CURRENT_PACKAGES_DIR}/tools/${PORT}")
        file(REMOVE "${CURRENT_PACKAGES_DIR}/bin/${TOOL}")
    endforeach()

    foreach(TOOL "fast-discovery-server.exe" "fast-discovery-serverd-1.0.1.exe" "fastdds.bat" "ros-discovery.bat")
        file(REMOVE "${CURRENT_PACKAGES_DIR}/bin/${TOOL}")
        if(EXISTS "${CURRENT_PACKAGES_DIR}/debug/bin/${TOOL}")
            file(REMOVE "${CURRENT_PACKAGES_DIR}/debug/bin/${TOOL}")
        endif()
    endforeach()

    # adjust paths in batch files
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/tools/${PORT}/fastdds.bat" "%dir%\\..\\tools\\fastdds\\fastdds.py" "%dir%\\..\\fastdds\\fastdds.py")
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/tools/${PORT}/ros-discovery.bat" "%dir%\\..\\tools\\fastdds\\fastdds.py" "%dir%\\..\\fastdds\\fastdds.py")

elseif(VCPKG_TARGET_IS_LINUX)
    # copy tools from "bin" to "tools" folder
    foreach(TOOL "fast-discovery-server-1.0.1" "fast-discovery-server" "fastdds" "ros-discovery")
        file(INSTALL "${CURRENT_PACKAGES_DIR}/bin/${TOOL}" DESTINATION "${CURRENT_PACKAGES_DIR}/tools/${PORT}")
        file(REMOVE "${CURRENT_PACKAGES_DIR}/bin/${TOOL}")
    endforeach()

    # replace symlink by a copy because symlinks do not work well together with vcpkg binary caching
    file(REMOVE "${CURRENT_PACKAGES_DIR}/tools/${PORT}/fast-discovery-server")
    file(INSTALL "${CURRENT_PACKAGES_DIR}/tools/${PORT}/fast-discovery-server-1.0.1" DESTINATION "${CURRENT_PACKAGES_DIR}/tools/${PORT}" RENAME "fast-discovery-server")

    # remove tools from debug builds
    foreach(TOOL "fast-discovery-serverd-1.0.1" "fast-discovery-server" "fastdds" "ros-discovery")
        file(REMOVE "${CURRENT_PACKAGES_DIR}/debug/bin/${TOOL}")
    endforeach()

    # adjust paths in batch files
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/tools/${PORT}/fastdds" "$dir/../tools/fastdds/fastdds.py" "$dir/../fastdds/fastdds.py")
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/tools/${PORT}/ros-discovery" "$dir/../tools/fastdds/fastdds.py" "$dir/../fastdds/fastdds.py")
endif()

# Part of LOCAL DELTA 3. This sat outside every branch, so it also ran where COMPILE_TOOLS is OFF and the Python
# tools were never installed. Guarded on the file rather than on the toolchain: it then stays correct however
# the tools come to be absent.
if(EXISTS "${CURRENT_PACKAGES_DIR}/tools/fastdds/discovery/parser.py")
    vcpkg_replace_string("${CURRENT_PACKAGES_DIR}/tools/fastdds/discovery/parser.py" "tool_path / '../../../bin'" "tool_path / '../../${PORT}'")
endif()

file(INSTALL "${CMAKE_CURRENT_LIST_DIR}/usage" DESTINATION "${CURRENT_PACKAGES_DIR}/share/${PORT}")
if(VCPKG_LIBRARY_LINKAGE STREQUAL "static" OR NOT VCPKG_TARGET_IS_WINDOWS)
    file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/bin")
    file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/bin")
endif()

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/share")
file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/tools")

vcpkg_install_copyright(
    FILE_LIST
        "${SOURCE_PATH}/LICENSE"
        "${SOURCE_PATH}/thirdparty/boost/LICENSE.TXT"
        "${SOURCE_PATH}/thirdparty/filewatch/LICENSE"
        "${SOURCE_PATH}/thirdparty/optionparser/optionparser.hpp"
        "${SOURCE_PATH}/thirdparty/optionparser/optionparser/optionparser.h"
        "${SOURCE_PATH}/thirdparty/taocpp-pegtl/pegtl.hpp"
        "${SOURCE_PATH}/src/cpp/rtps/persistence/sqlite3.h"
)
