# ---------------------------------------------------------------------------------------------------------------------
# LOCAL OVERLAY of the upstream fastfeat port. ONE delta, in the injected CMakeLists.txt: on anything but MSVC the
# library is built WITHOUT the "lib" prefix, so the file on disk is fastfeat.dll.
#
# WHY, because the symptom appears nowhere near the cause and cost a day to find.
#
# The port injects its own CMakeLists.txt and its own fastfeat.def, and the CMakeLists globs *.def into the sources, so
# the linker reads the .def as a module-definition file. Its first line is
#
#     LIBRARY   fastfeat
#
# and a LIBRARY statement names the DLL: the linker writes "fastfeat.dll" into the import library it generates. On MSVC
# that matches reality, because MSVC gives a DLL no prefix. On MinGW, CMake adds the customary "lib" and the output is
# libfastfeat.dll -- so the import library promises fastfeat.dll and nothing of that name is ever installed. Verified
# by reading the import library directly: it carries _head_fastfeat_dll and the string "fastfeat.dll", beside an
# installed file called libfastfeat.dll.
#
# WHAT THAT BREAKS, in order, because none of it mentions fastfeat:
#
#   svt-av1 links fastfeat and is built and installed with no complaint at all.
#   libSvtAv1Enc.dll then cannot load: ERROR_MOD_NOT_FOUND, looking for fastfeat.dll.
#   avcodec-63.dll links libSvtAv1Enc (whenever ffmpeg is built with svt-av1), so avcodec cannot load either.
#   ffmpeg.exe therefore dies on startup with 0xC0000135, before printing its version.
#   gstreamer's libgstlibav.dll links avcodec, so the entire ffmpeg bridge inside gstreamer disappears -- no
#   avdec_h264, no avenc_aac -- and gst-inspect reports only "failed to load plugin", with no reason.
#
# Every build in that chain reports success. The first thing that ever objects is a program trying to LOAD the
# library, which is why this was found by the environment verification step and not by any compiler.
#
# The prefix is dropped rather than the LIBRARY line deleted, on purpose: this honours the name upstream chose and
# makes the artefact identically named on both toolchains, instead of leaving MSVC and MinGW each self-consistent but
# disagreeing with each other.
#
# Worth sending upstream: it is a real bug on any non-MSVC Windows toolchain, and MSVC is unaffected either way.
# ---------------------------------------------------------------------------------------------------------------------

vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO edrosten/fast-C-src
    REF 391d5e939eb1545d24c10533d7de424db8d9c191
    SHA512 d6f401e2f80193c4f1f99e1ef59af7107d674c515574cf513c5977c4c95c49c0520d2a6e6787f617b42d9e3bd93c78b8fa7f1d8dc8901351820590078e62130e
    HEAD_REF master
)


file(COPY
"${CMAKE_CURRENT_LIST_DIR}/CMakeLists.txt"
"${CMAKE_CURRENT_LIST_DIR}/fastfeat.def"
DESTINATION "${SOURCE_PATH}"
)

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS_DEBUG
        -DDISABLE_INSTALL_HEADERS=ON
)

vcpkg_cmake_install()
vcpkg_copy_pdbs()

# Handle copyright
file(INSTALL "${SOURCE_PATH}/LICENSE" DESTINATION "${CURRENT_PACKAGES_DIR}/share/fastfeat" RENAME copyright)
