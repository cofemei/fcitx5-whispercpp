#pragma once

#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>
#include <fcitx/text.h>
#include <fcitx-utils/event.h>

#include <memory>
#include <string>

#include "dbus_client.h"

namespace fcitx {

class WhisperCppEngine final : public InputMethodEngineV2 {
public:
    explicit WhisperCppEngine(Instance* instance);
    ~WhisperCppEngine() override;

    void activate(const InputMethodEntry& entry, InputContextEvent& event) override;
    void deactivate(const InputMethodEntry& entry, InputContextEvent& event) override;
    void keyEvent(const InputMethodEntry& entry, KeyEvent& event) override;
    void reset(const InputMethodEntry& entry, InputContextEvent& event) override;

private:
    void toggleRecording();
    void setRecording(bool recording);
    void onDelta(const std::string& text);
    void onComplete(const std::string& text, int segment_num);
    void onError(const std::string& message);
    InputContext* currentInputContext() const;
    void updatePreeditDisplay(const Text& preedit);
    void setPreedit(const std::string& text);
    void clearPreedit();
    void showStatus(const std::string& message);

    Instance* instance_ = nullptr;
    std::unique_ptr<DBusClient> dbus_client_;
    std::unique_ptr<EventSource> event_source_;
    bool recording_ = false;
    InputContext* active_ic_ = nullptr;
    std::string preedit_text_;
};

class WhisperCppEngineFactory : public AddonFactory {
public:
    AddonInstance* create(AddonManager* manager) override {
        return new WhisperCppEngine(manager->instance());
    }
};

} // namespace fcitx
