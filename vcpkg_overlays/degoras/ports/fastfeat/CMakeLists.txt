cmake_minimum_required(VERSION 3.8)
project(fastfeat)

if(MSVC)
  add_compile_options(/W3 /wd4005 /wd4996 /wd4018 -D_CRT_SECURE_NO_WARNINGS)
endif()

include_directories(.)
file( GLOB SRCS *.c *.def)
add_library(fastfeat ${SRCS})

# ----------------------------------------------------------------------------------------------------------------------
# LOCAL DELTA, and the only difference from the upstream port. See the portfile header for the full story.
#
# fastfeat.def is globbed into the sources above, so the linker reads it as a module-definition file -- and its first
# line is
#
#     LIBRARY   fastfeat
#
# which tells the linker the DLL is called "fastfeat.dll" and writes that name into the import library. On MSVC that is
# true: MSVC adds no prefix and the output really is fastfeat.dll. On MinGW, CMake adds the customary "lib" prefix and
# the output is libfastfeat.dll, so the import library promises a file that does not exist. Anything linking fastfeat
# then builds cleanly and dies at load time with ERROR_MOD_NOT_FOUND.
#
# Dropping the prefix rather than deleting the LIBRARY line, deliberately: this honours the name upstream chose and
# makes the artefact identical on both toolchains, instead of leaving each self-consistent but differently named.
if(NOT MSVC)
  set_target_properties(fastfeat PROPERTIES PREFIX "")
endif()
# ----------------------------------------------------------------------------------------------------------------------

install(
  TARGETS fastfeat
  RUNTIME DESTINATION bin
  LIBRARY DESTINATION lib
  ARCHIVE DESTINATION lib
)

if(NOT DISABLE_INSTALL_HEADERS)
  install(
    FILES fast.h DESTINATION include
  )
endif()
