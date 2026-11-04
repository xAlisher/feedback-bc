# UI plugin: install-only (no C++ build step)
# QML files are loaded by the Logos shell at runtime.

set(LOGOS_APP_DATA "$ENV{HOME}/.local/share/Logos/LogosBasecamp")
set(UI_DIR "${LOGOS_APP_DATA}/plugins/my-module-ui")

install(FILES
    manifest.json
    metadata.json
    DESTINATION "${UI_DIR}"
)

install(FILES
    Main.qml
    DESTINATION "${UI_DIR}"
)

# Uncomment if you have an icon (28x28 PNG required):
# install(FILES myicon.png DESTINATION "${UI_DIR}")
# install(FILES icons/myicon.png DESTINATION "${UI_DIR}/icons")
