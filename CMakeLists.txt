cmake_minimum_required(VERSION 3.23)
project(godot_soci VERSION 0.3.1 LANGUAGES C CXX)

include(FetchContent)

# Pinned upstream commits: reproducible source dependencies, not vendored binaries.
set(GODOT_SOCI_GODOT_CPP_REF "b8530af7546a3fcae80cef2477526569fd42ffc2" CACHE STRING "godot-cpp commit")
set(GODOT_SOCI_SOCI_REF "a9e51707d565baa6e02634453d5e81b84062c94a" CACHE STRING "SOCI commit")
option(GODOT_SOCI_WITH_POSTGRESQL "Compile PostgreSQL backend (requires libpq)" ON)

# Match the minimum runtime version in the .gdextension manifest.
set(GODOTCPP_API_VERSION "4.7" CACHE STRING "Godot API version for godot-cpp")
find_package(Python3 COMPONENTS Interpreter REQUIRED)
find_package(Threads REQUIRED)

# Match vcpkg x64-windows-static-md: statically linked SQL libraries still use
# the *dynamic* MSVC CRT. godot-cpp defaults to static CRT, causing LNK20xx.
if(MSVC)
    set(GODOTCPP_USE_STATIC_CPP OFF CACHE BOOL "Use dynamic MSVC CRT" FORCE)
    set(CMAKE_MSVC_RUNTIME_LIBRARY
        "MultiThreadedDLL"
        CACHE STRING "Use redistributable /MD CRT with release libraries for both Godot template targets" FORCE)
endif()

FetchContent_Declare(godot_cpp
    GIT_REPOSITORY https://github.com/godotengine/godot-cpp.git
    GIT_TAG ${GODOT_SOCI_GODOT_CPP_REF}
    GIT_SHALLOW FALSE
)
FetchContent_MakeAvailable(godot_cpp)

# Keep SOCI's synchronous C++ backends in this GDExtension; no runtime dlopen backend search.
set(SOCI_STATIC ON CACHE BOOL "Build SOCI static" FORCE)
set(SOCI_SHARED OFF CACHE BOOL "Build SOCI shared" FORCE)
set(SOCI_INSTALL OFF CACHE BOOL "Do not install SOCI" FORCE)
set(SOCI_TESTS OFF CACHE BOOL "Do not build upstream tests" FORCE)
set(SOCI_LTO OFF CACHE BOOL "Disable SOCI LTO for portable builds" FORCE)
set(WITH_BOOST OFF CACHE BOOL "No Boost dependency" FORCE)
set(SOCI_DB2 OFF CACHE STRING "" FORCE)
set(SOCI_EMPTY OFF CACHE STRING "" FORCE)
set(SOCI_FIREBIRD OFF CACHE STRING "" FORCE)
set(SOCI_MYSQL OFF CACHE STRING "" FORCE)
set(SOCI_ODBC OFF CACHE STRING "" FORCE)
set(SOCI_ORACLE OFF CACHE STRING "" FORCE)
set(SOCI_SQLITE3 ON CACHE STRING "" FORCE)
if(GODOT_SOCI_WITH_POSTGRESQL)
    set(SOCI_POSTGRESQL ON CACHE STRING "" FORCE)
else()
    set(SOCI_POSTGRESQL OFF CACHE STRING "" FORCE)
endif()

# FetchContent retrieves upstream submodules (SOCI's fmt fallback) on checkout.
FetchContent_Declare(soci_src
    GIT_REPOSITORY https://github.com/SOCI/soci.git
    GIT_TAG ${GODOT_SOCI_SOCI_REF}
    GIT_SHALLOW FALSE
    GIT_SUBMODULES_RECURSE TRUE
)
FetchContent_MakeAvailable(soci_src)

add_library(godot_soci SHARED
    src/database.cpp
    src/query_request.cpp
    src/query_worker.cpp
    src/query_dispatcher.cpp
    src/register_types.cpp
)
target_compile_features(godot_soci PRIVATE cxx_std_17)
target_include_directories(godot_soci PRIVATE src include)
target_link_libraries(godot_soci PRIVATE godot-cpp Threads::Threads SOCI::SQLite3)
if(GODOT_SOCI_WITH_POSTGRESQL)
    target_link_libraries(godot_soci PRIVATE SOCI::PostgreSQL)
    target_compile_definitions(godot_soci PRIVATE GODOT_SOCI_WITH_POSTGRESQL=1)
endif()

# SOCI uses C++ exceptions. godot-cpp normally builds with exceptions disabled.
if(MSVC)
    target_compile_options(godot_soci PRIVATE /EHsc)
else()
    target_compile_options(godot_soci PRIVATE -fexceptions)
endif()

get_target_property(GODOTCPP_SUFFIX godot::cpp GODOTCPP_SUFFIX)
get_target_property(GODOTCPP_PLATFORM godot::cpp GODOTCPP_PLATFORM)
if(NOT GODOTCPP_PLATFORM)
    message(FATAL_ERROR "Cannot determine godot-cpp target platform")
endif()

set(ADDON_BINARY_DIR "${CMAKE_SOURCE_DIR}/addons/godot_soci/bin/${GODOTCPP_PLATFORM}")
set_target_properties(godot_soci PROPERTIES
    PREFIX ""
    OUTPUT_NAME "godot_soci${GODOTCPP_SUFFIX}"
    RUNTIME_OUTPUT_DIRECTORY "$<1:${ADDON_BINARY_DIR}>"
    LIBRARY_OUTPUT_DIRECTORY "$<1:${ADDON_BINARY_DIR}>"
)
