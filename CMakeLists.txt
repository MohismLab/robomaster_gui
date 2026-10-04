cmake_minimum_required(VERSION 3.16)
project(robomaster_gui_node CXX)

if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(std_msgs REQUIRED)
find_package(geometry_msgs REQUIRED)
find_package(visualization_msgs REQUIRED)
find_package(nav_msgs REQUIRED)

# godot-cpp, prebuilt with SCons (scons platform=linux target=template_debug)
set(GODOT_CPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../godot-cpp" CACHE PATH "godot-cpp checkout")
set(GODOT_CPP_TARGET "template_debug" CACHE STRING "godot-cpp build target (template_debug / template_release)")
set(GODOT_BIN "${CMAKE_CURRENT_SOURCE_DIR}/../godot/bin/godot.linuxbsd.editor.x86_64" CACHE FILEPATH "Godot 4.5 binary")
set(GODOT_CPP_LIB "${GODOT_CPP_DIR}/bin/libgodot-cpp.linux.${GODOT_CPP_TARGET}.x86_64.a")
if(NOT EXISTS "${GODOT_CPP_LIB}")
  message(FATAL_ERROR "${GODOT_CPP_LIB} not found, build it: cd ${GODOT_CPP_DIR} && scons platform=linux target=${GODOT_CPP_TARGET}")
endif()

add_library(robomaster_gui SHARED
  src/register_types.cpp
  src/ros_bridge.cpp
)
target_include_directories(robomaster_gui PRIVATE
  "${GODOT_CPP_DIR}/include"
  "${GODOT_CPP_DIR}/gen/include"
  "${GODOT_CPP_DIR}/gdextension"
)
# same defines as godot-cpp's SConstruct for linux
target_compile_definitions(robomaster_gui PRIVATE LINUX_ENABLED UNIX_ENABLED THREADS_ENABLED HOT_RELOAD_ENABLED GDEXTENSION)
if(GODOT_CPP_TARGET STREQUAL "template_debug")
  target_compile_definitions(robomaster_gui PRIVATE DEBUG_ENABLED)
endif()
target_link_libraries(robomaster_gui "${GODOT_CPP_LIB}")
ament_target_dependencies(robomaster_gui rclcpp std_msgs geometry_msgs visualization_msgs nav_msgs)
set_target_properties(robomaster_gui PROPERTIES
  POSITION_INDEPENDENT_CODE ON
  CXX_VISIBILITY_PRESET hidden
  # find librclcpp etc. through LD_LIBRARY_PATH of the sourced workspace
  LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
)
target_link_options(robomaster_gui PRIVATE -Wl,--no-undefined)

# also drop the library into the source project, so it opens directly in the Godot editor
add_custom_command(TARGET robomaster_gui POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_SOURCE_DIR}/godot_project/bin"
  COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:robomaster_gui>" "${CMAKE_CURRENT_SOURCE_DIR}/godot_project/bin/"
)

install(DIRECTORY godot_project/ DESTINATION share/${PROJECT_NAME}/godot_project
  PATTERN ".godot" EXCLUDE
  PATTERN "bin" EXCLUDE)
install(TARGETS robomaster_gui LIBRARY DESTINATION share/${PROJECT_NAME}/godot_project/bin)
install(DIRECTORY launch DESTINATION share/${PROJECT_NAME})
configure_file(tools/robomaster_gui.in "${CMAKE_CURRENT_BINARY_DIR}/robomaster_gui" @ONLY)
install(PROGRAMS "${CMAKE_CURRENT_BINARY_DIR}/robomaster_gui" DESTINATION lib/${PROJECT_NAME})

ament_package()
