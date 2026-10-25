cmake_minimum_required(VERSION 3.25)
project(MoltenVKDrawablePatch LANGUAGES C CXX OBJC OBJCXX)

# All dependencies are supplied locally at the upstream revision's pins.
# No downloads occur during configure, build or runtime.
foreach(NAME SOURCE_DIR VULKAN_HEADERS_DIR SPIRV_HEADERS_DIR SPIRV_TOOLS_DIR
             SPIRV_CROSS_DIR CEREAL_DIR)
  set(MVK_${NAME} "" CACHE PATH "Local MoltenVK ${NAME}")
  if(NOT IS_DIRECTORY "${MVK_${NAME}}")
    message(FATAL_ERROR "Set MVK_${NAME} to the corresponding local directory")
  endif()
endforeach()
set(MVK_FRAMEWORK_VERSION "" CACHE STRING "Matching upstream framework version")
set(MVK_SOURCE_REVISION "" CACHE STRING "Matching upstream source commit")
if(NOT MVK_FRAMEWORK_VERSION OR NOT MVK_SOURCE_REVISION)
  message(FATAL_ERROR "Set MVK_FRAMEWORK_VERSION and MVK_SOURCE_REVISION")
endif()

set(MVK_LOG_LEVEL 2 CACHE STRING "MoltenVK logging level")
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(PREPARED "${CMAKE_CURRENT_BINARY_DIR}/prepared")
execute_process(COMMAND "${Python3_EXECUTABLE}"
  "${CMAKE_CURRENT_SOURCE_DIR}/prepare_build.py" "${MVK_SOURCE_DIR}" "${PREPARED}"
  COMMAND_ERROR_IS_FATAL ANY)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
  "${CMAKE_CURRENT_SOURCE_DIR}/patch_driver.py"
  "${CMAKE_CURRENT_SOURCE_DIR}/prepare_build.py"
  "${MVK_SOURCE_DIR}/MoltenVK/MoltenVK/GPUObjects/MVKImage.mm"
  "${MVK_SOURCE_DIR}/MoltenVK/MoltenVK/OS/MTLSamplerDescriptor+MoltenVK.m")

set(SPIRV_SKIP_EXECUTABLES ON CACHE BOOL "" FORCE)
set(SPIRV_SKIP_TESTS ON CACHE BOOL "" FORCE)
set(SPIRV_WERROR OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_CLI OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_TESTS OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_C_API OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_HLSL OFF CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_REFLECT ON CACHE BOOL "" FORCE)
set(SPIRV_CROSS_ENABLE_CPP OFF CACHE BOOL "" FORCE)
set(SPIRV-Headers_SOURCE_DIR "${MVK_SPIRV_HEADERS_DIR}" CACHE PATH "" FORCE)
add_subdirectory("${MVK_SPIRV_CROSS_DIR}" cross)
add_subdirectory("${MVK_SPIRV_TOOLS_DIR}" spirv-tools)

file(GLOB COMMON "${MVK_SOURCE_DIR}/Common/*.c" "${MVK_SOURCE_DIR}/Common/*.cpp"
                 "${MVK_SOURCE_DIR}/Common/*.m" "${MVK_SOURCE_DIR}/Common/*.mm")
file(GLOB CONVERTER "${MVK_SOURCE_DIR}/MoltenVKShaderConverter/MoltenVKShaderConverter/*.cpp"
                    "${MVK_SOURCE_DIR}/MoltenVKShaderConverter/MoltenVKShaderConverter/*.mm")
file(GLOB_RECURSE DRIVER "${MVK_SOURCE_DIR}/MoltenVK/MoltenVK/*.c"
                        "${MVK_SOURCE_DIR}/MoltenVK/MoltenVK/*.cpp"
                        "${MVK_SOURCE_DIR}/MoltenVK/MoltenVK/*.m"
                        "${MVK_SOURCE_DIR}/MoltenVK/MoltenVK/*.mm")
list(REMOVE_ITEM DRIVER
  "${MVK_SOURCE_DIR}/MoltenVK/MoltenVK/GPUObjects/MVKImage.mm"
  "${MVK_SOURCE_DIR}/MoltenVK/MoltenVK/OS/MTLSamplerDescriptor+MoltenVK.m")
add_library(MoltenVK SHARED ${COMMON} ${CONVERTER} ${DRIVER}
  "${PREPARED}/MVKImage.mm" "${PREPARED}/MTLSamplerDescriptor+MoltenVK.m"
  patch_marker.cc)
set_target_properties(MoltenVK PROPERTIES PREFIX "" SUFFIX ""
  INSTALL_NAME_DIR "@rpath" BUILD_WITH_INSTALL_NAME_DIR TRUE)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/mvkGitRevDerived.h"
  "static const char* mvkRevString = \"${MVK_SOURCE_REVISION}\";\n")
target_compile_definitions(MoltenVK PRIVATE
  MVK_FRAMEWORK_VERSION=${MVK_FRAMEWORK_VERSION}
  MVK_CONFIG_LOG_LEVEL=${MVK_LOG_LEVEL} MVK_USE_METAL_PRIVATE_API=1)
target_compile_options(MoltenVK PRIVATE -Wno-deprecated-declarations -Wno-vla-cxx-extension)
target_include_directories(MoltenVK PRIVATE
  "${MVK_SOURCE_DIR}/Common" "${MVK_SOURCE_DIR}/MoltenVK/include"
  "${MVK_SOURCE_DIR}/MoltenVKShaderConverter" "${MVK_VULKAN_HEADERS_DIR}"
  "${MVK_CEREAL_DIR}/include" "${MVK_SPIRV_HEADERS_DIR}/include"
  "${CMAKE_CURRENT_BINARY_DIR}")
foreach(DIR API Commands GPUObjects Layers OS Utility Vulkan)
  target_include_directories(MoltenVK PRIVATE "${MVK_SOURCE_DIR}/MoltenVK/MoltenVK/${DIR}")
endforeach()
target_link_libraries(MoltenVK PRIVATE spirv-cross-msl spirv-cross-reflect SPIRV-Tools-static
  "-framework Foundation" "-framework Metal" "-framework AppKit" "-framework IOKit"
  "-framework IOSurface" "-framework QuartzCore" "-framework CoreGraphics")

option(MVK_BUILD_DEVICE_LOSS_HARNESS "Build private-ABI CPU wait fault-injection checks" OFF)
if(MVK_BUILD_DEVICE_LOSS_HARNESS)
  add_executable(mvk-device-loss-harness device_loss_harness.mm)
  get_target_property(MVK_PRIVATE_INCLUDES MoltenVK INCLUDE_DIRECTORIES)
  target_include_directories(mvk-device-loss-harness PRIVATE ${MVK_PRIVATE_INCLUDES}
    "${MVK_SPIRV_CROSS_DIR}" "${MVK_SPIRV_TOOLS_DIR}/include")
  target_compile_definitions(mvk-device-loss-harness PRIVATE MVK_USE_METAL_PRIVATE_API=1)
  target_link_libraries(mvk-device-loss-harness PRIVATE MoltenVK
    "-framework Foundation" "-framework Metal" "-framework QuartzCore")
endif()

option(MVK_BUILD_TIMELINE_HARNESS "Build private-ABI timeline encoding checks" OFF)
if(MVK_BUILD_TIMELINE_HARNESS)
  add_executable(mvk-timeline-harness timeline_encoding_harness.mm)
  get_target_property(MVK_TIMELINE_INCLUDES MoltenVK INCLUDE_DIRECTORIES)
  target_include_directories(mvk-timeline-harness PRIVATE ${MVK_TIMELINE_INCLUDES}
    "${MVK_SPIRV_CROSS_DIR}" "${MVK_SPIRV_TOOLS_DIR}/include")
  target_compile_definitions(mvk-timeline-harness PRIVATE MVK_USE_METAL_PRIVATE_API=1)
  target_link_libraries(mvk-timeline-harness PRIVATE MoltenVK
    "-framework Foundation" "-framework Metal" "-framework QuartzCore")
endif()
