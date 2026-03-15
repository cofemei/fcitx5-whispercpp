#include "dbus_client.h"

#include <fcitx-utils/log.h>
#include <cstring>
#include <stdexcept>

namespace fcitx {

static const char* kService = "org.fcitx.Fcitx5.WhisperCpp";
static const char* kPath = "/org/fcitx/Fcitx5/WhisperCpp";
static const char* kInterface = "org.fcitx.Fcitx5.WhisperCpp";

DBusClient::DBusClient() {
    connect();
}

DBusClient::~DBusClient() {
    disconnect();
}

void DBusClient::connect() {
    DBusError error;
    dbus_error_init(&error);

    conn_ = dbus_bus_get(DBUS_BUS_SESSION, &error);
    if (dbus_error_is_set(&error)) {
        std::string msg = error.message ? error.message : "failed to connect";
        dbus_error_free(&error);
        throw std::runtime_error(msg);
    }
    if (!conn_) {
        throw std::runtime_error("D-Bus connection is null");
    }

    const char* match_rule =
        "type='signal',interface='org.fcitx.Fcitx5.WhisperCpp',"
        "path='/org/fcitx/Fcitx5/WhisperCpp'";
    dbus_bus_add_match(conn_, match_rule, &error);
    if (dbus_error_is_set(&error)) {
        std::string msg = error.message ? error.message : "failed to add D-Bus match";
        dbus_error_free(&error);
        throw std::runtime_error(msg);
    }
    dbus_connection_flush(conn_);
    dbus_connection_add_filter(conn_, messageFilter, this, nullptr);
}

void DBusClient::disconnect() {
    if (conn_) {
        dbus_connection_remove_filter(conn_, messageFilter, this);
        dbus_connection_unref(conn_);
        conn_ = nullptr;
    }
}

void DBusClient::startRecording() {
    FCITX_DEBUG() << "DBusClient StartRecording";
    callMethod("StartRecording");
}

void DBusClient::stopRecording() {
    FCITX_DEBUG() << "DBusClient StopRecording";
    callMethod("StopRecording");
}

void DBusClient::processEvents() {
    if (!conn_) {
        return;
    }

    if (!dbus_connection_read_write(conn_, 0)) {
        return;
    }

    while (dbus_connection_dispatch(conn_) == DBUS_DISPATCH_DATA_REMAINS) {
    }
}

int DBusClient::getFileDescriptor() {
    if (!conn_) {
        return -1;
    }

    int fd = -1;
    if (!dbus_connection_get_unix_fd(conn_, &fd)) {
        return -1;
    }
    return fd;
}

void DBusClient::setCompleteCallback(CompleteCallback cb) {
    complete_cb_ = std::move(cb);
}

void DBusClient::setDeltaCallback(DeltaCallback cb) {
    delta_cb_ = std::move(cb);
}

void DBusClient::setErrorCallback(ErrorCallback cb) {
    error_cb_ = std::move(cb);
}

void DBusClient::callMethod(const char* method) {
    if (!conn_) {
        throw std::runtime_error("not connected to D-Bus");
    }

    DBusMessage* msg = dbus_message_new_method_call(kService, kPath, kInterface, method);
    if (!msg) {
        throw std::runtime_error("failed to allocate D-Bus message");
    }

    DBusError error;
    dbus_error_init(&error);

    DBusMessage* reply = dbus_connection_send_with_reply_and_block(conn_, msg, 2000, &error);
    dbus_message_unref(msg);

    if (dbus_error_is_set(&error)) {
        std::string err = error.message ? error.message : "D-Bus call failed";
        dbus_error_free(&error);
        throw std::runtime_error(err);
    }

    if (reply) {
        dbus_message_unref(reply);
    }
}

void DBusClient::handleMessage(DBusMessage* msg) {
    if (dbus_message_is_signal(msg, kInterface, "TranscriptionComplete")) {
        const char* text = "";
        int segment = 0;
        DBusError error;
        dbus_error_init(&error);

        if (dbus_message_get_args(msg, &error,
                                  DBUS_TYPE_STRING, &text,
                                  DBUS_TYPE_INT32, &segment,
                                  DBUS_TYPE_INVALID)) {
            if (complete_cb_) {
                FCITX_DEBUG() << "DBus signal TranscriptionComplete len=" << std::strlen(text);
                complete_cb_(text, segment);
            }
        }
        if (dbus_error_is_set(&error)) {
            dbus_error_free(&error);
        }
    } else if (dbus_message_is_signal(msg, kInterface, "TranscriptionDelta")) {
        const char* text = "";
        DBusError error;
        dbus_error_init(&error);

        if (dbus_message_get_args(msg, &error,
                                  DBUS_TYPE_STRING, &text,
                                  DBUS_TYPE_INVALID)) {
            if (delta_cb_) {
                FCITX_DEBUG() << "DBus signal TranscriptionDelta len=" << std::strlen(text);
                delta_cb_(text);
            }
        }
        if (dbus_error_is_set(&error)) {
            dbus_error_free(&error);
        }
    } else if (dbus_message_is_signal(msg, kInterface, "Error")) {
        const char* message = "error";
        DBusError error;
        dbus_error_init(&error);

        if (dbus_message_get_args(msg, &error,
                                  DBUS_TYPE_STRING, &message,
                                  DBUS_TYPE_INVALID)) {
            if (error_cb_) {
                FCITX_ERROR() << "DBus signal Error: " << message;
                error_cb_(message);
            }
        }
        if (dbus_error_is_set(&error)) {
            dbus_error_free(&error);
        }
    }
}

DBusHandlerResult DBusClient::messageFilter(DBusConnection*, DBusMessage* msg, void* user_data) {
    auto* client = static_cast<DBusClient*>(user_data);
    const char* interface = dbus_message_get_interface(msg);
    if (interface && std::strcmp(interface, kInterface) == 0) {
        client->handleMessage(msg);
        return DBUS_HANDLER_RESULT_HANDLED;
    }
    return DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

} // namespace fcitx
