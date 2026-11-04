cmake_minimum_required(VERSION 3.28)
project(mymodule-basecamp VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

# --- Dependencies ---

# Qt6 Core (required for all Basecamp modules)
find_package(Qt6 REQUIRED COMPONENTS Core)

# libsodium (optional — remove if you don't need crypto)
find_package(PkgConfig REQUIRED)
pkg_check_modules(sodium IMPORTED_TARGET libsodium)

# --- Subdirectories ---

add_subdirectory(core)
add_subdirectory(ui)
