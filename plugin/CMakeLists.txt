find_package(PkgConfig REQUIRED)
pkg_check_modules(DBUS REQUIRED dbus-1)
include(GNUInstallDirs)

set(WHISPERCPP_SRCS
    whispercpp_engine.cpp
    whispercpp_engine_factory.cpp
    dbus_client.cpp
)

add_library(whispercpp MODULE ${WHISPERCPP_SRCS})

target_include_directories(whispercpp PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${DBUS_INCLUDE_DIRS}
)

target_link_libraries(whispercpp
    Fcitx5::Core
    Fcitx5::Utils
    ${DBUS_LIBRARIES}
)

set_target_properties(whispercpp PROPERTIES PREFIX "")

install(TARGETS whispercpp
    LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}/fcitx5"
)

configure_file(whispercpp-addon.conf.in whispercpp-addon.conf)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/whispercpp-addon.conf"
    RENAME whispercpp.conf
    DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5/addon"
)

install(FILES whispercpp.conf
    DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5/inputmethod"
)
