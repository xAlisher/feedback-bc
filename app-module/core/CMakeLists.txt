# feedback_core — crypto core plugin (libsodium crypto_box_seal)

if(DEFINED ENV{LOGOS_CPP_SDK_ROOT})
    set(LOGOS_CPP_SDK "$ENV{LOGOS_CPP_SDK_ROOT}")
else()
    message(FATAL_ERROR "LOGOS_CPP_SDK_ROOT not set (run via nix)")
endif()

if(DEFINED ENV{LOGOS_LIBLOGOS_HEADERS})
    set(LOGOS_LIBLOGOS_HEADERS "$ENV{LOGOS_LIBLOGOS_HEADERS}")
else()
    message(FATAL_ERROR "LOGOS_LIBLOGOS_HEADERS not set (run via nix)")
endif()

set(PLUGIN_SOURCES
    FeedbackCore.h
    FeedbackCore.cpp
)

configure_file(
    plugin_metadata.json
    ${CMAKE_CURRENT_BINARY_DIR}/plugin_metadata.json
    COPYONLY
)

add_library(feedback_core_plugin MODULE ${PLUGIN_SOURCES})

set_target_properties(feedback_core_plugin PROPERTIES
    PREFIX ""
    OUTPUT_NAME "feedback_core_plugin"
    BUILD_RPATH "$ORIGIN"
    INSTALL_RPATH "$ORIGIN"
)

target_include_directories(feedback_core_plugin PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    "${LOGOS_LIBLOGOS_HEADERS}"
    "${LOGOS_CPP_SDK}/include"
    "${LOGOS_CPP_SDK}/include/cpp"
    "${LOGOS_CPP_SDK}/include/core"
)

target_link_libraries(feedback_core_plugin PRIVATE
    Qt6::Core
    Qt6::RemoteObjects   # liblogos_sdk.a uses QRemoteObject* for IPC; the darwin linker needs it explicit
    "${LOGOS_CPP_SDK}/lib/liblogos_sdk.a"
)

# libsodium is required for this module
if(NOT TARGET PkgConfig::sodium)
    message(FATAL_ERROR "libsodium not found (pkg-config)")
endif()
target_link_libraries(feedback_core_plugin PRIVATE PkgConfig::sodium)

# --- Install (local dev convenience) ---
set(LOGOS_APP_DATA "$ENV{HOME}/.local/share/Logos/LogosBasecamp")
set(MODULE_DIR "${LOGOS_APP_DATA}/modules/feedback_core")
install(CODE "
    set(_modules_dir \"${LOGOS_APP_DATA}/modules\")
    file(GLOB _old \"\${_modules_dir}/feedback_core.*\")
    foreach(_dir \${_old})
        file(REMOVE_RECURSE \"\${_dir}\")
    endforeach()
")
install(TARGETS feedback_core_plugin LIBRARY DESTINATION "${MODULE_DIR}")
install(FILES manifest.json DESTINATION "${MODULE_DIR}")
