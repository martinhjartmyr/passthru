cmake_minimum_required(VERSION 3.12.0)

project(Passthru CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(CODESIGN_ID "" CACHE STRING "Codesign ID (empty = ad-hoc/unsigned)")

set(DRIVER_NAME "Passthru")
set(DRIVER_VERSION "0.1.0")
set(DRIVER_COPYRIGHT "MIT License (c) Passthru contributors")
set(DRIVER_IDENTIFIER "dev.passthru.driver")
set(DRIVER_UID "07C91D5E-E73C-4FA0-A75A-40FF0E87900F")
set(DRIVER_ENTRYPOINT "PassthruEntryPoint")

message(STATUS "Driver name - ${DRIVER_NAME}")
message(STATUS "Driver codesign ID - ${CODESIGN_ID}")

# Vendored libASPL v3.1.2 (vendored rather than depending on upstream).
add_subdirectory(third_party/libaspl)

add_library(${DRIVER_NAME} MODULE
  src/ClientGain.cpp
  src/Driver.cpp
  src/GainStore.cpp
  src/RingBuffer.cpp
  )

target_link_libraries(${DRIVER_NAME}
  PRIVATE libASPL
  )

find_library(LIB_CoreFoundation CoreFoundation REQUIRED)
target_link_libraries(${DRIVER_NAME}
  PRIVATE ${LIB_CoreFoundation}
  )

# Host-side logic tests for the per-app gain table (no HAL involved),
# graded against the checked-in golden vectors.
add_executable(GainStoreTests
  test/GainStoreTests.cpp
  src/GainStore.cpp
  )

# No shell-style quotes in the value: the test STRINGIFY()es the macro.
target_compile_definitions(GainStoreTests PRIVATE
  LAPV_FIXTURE_DIR=${CMAKE_CURRENT_SOURCE_DIR}/../contract/lapv
  )

target_link_libraries(GainStoreTests
  PRIVATE ${LIB_CoreFoundation}
  )

# Host-side tests for the extracted sample path (ring policies + per-client
# gain stage), mirroring the GainStoreTests build shape.
add_executable(SamplePathTests
  test/SamplePathTests.cpp
  src/ClientGain.cpp
  src/RingBuffer.cpp
  )

target_link_libraries(SamplePathTests
  PRIVATE ${LIB_CoreFoundation}
  )

set_target_properties(${DRIVER_NAME} PROPERTIES
  OUTPUT_NAME "${DRIVER_NAME}"
  BUNDLE true
  BUNDLE_EXTENSION "driver"
  PREFIX ""
  SUFFIX ""
  MACOSX_BUNDLE ON
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
  MACOSX_BUNDLE_BUNDLE_NAME "${DRIVER_NAME}"
  MACOSX_BUNDLE_BUNDLE_VERSION "${DRIVER_VERSION}"
  MACOSX_BUNDLE_COPYRIGHT "${DRIVER_COPYRIGHT}"
  MACOSX_BUNDLE_GUI_IDENTIFIER "${DRIVER_IDENTIFIER}"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "${DRIVER_VERSION}"
  )

if(NOT CODESIGN_ID STREQUAL "")
  add_custom_command(
    TARGET ${DRIVER_NAME}
    POST_BUILD
    COMMENT
      "Signing ${DRIVER_NAME}.driver with ID ${CODESIGN_ID}"
    VERBATIM
    COMMAND
      codesign --force -s "${CODESIGN_ID}"
        "${CMAKE_CURRENT_BINARY_DIR}/${DRIVER_NAME}.driver"
    )
endif()
