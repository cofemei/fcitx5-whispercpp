#pragma once

#include <dbus/dbus.h>
#include <functional>
#include <string>

namespace fcitx {

class DBusClient {
public:
    using CompleteCallback = std::function<void(const std::string&, int)>;
    using DeltaCallback = std::function<void(const std::string&)>;
    using ErrorCallback = std::function<void(const std::string&)>;

    DBusClient();
    ~DBusClient();

    void startRecording();
    void stopRecording();
    void processEvents();
    int getFileDescriptor();

    void setCompleteCallback(CompleteCallback cb);
    void setDeltaCallback(DeltaCallback cb);
    void setErrorCallback(ErrorCallback cb);

private:
    void connect();
    void disconnect();
    void callMethod(const char* method);
    void handleMessage(DBusMessage* message);

    static DBusHandlerResult messageFilter(DBusConnection* conn,
                                           DBusMessage* msg,
                                           void* user_data);

    DBusConnection* conn_ = nullptr;
    CompleteCallback complete_cb_;
    DeltaCallback delta_cb_;
    ErrorCallback error_cb_;
};

} // namespace fcitx
