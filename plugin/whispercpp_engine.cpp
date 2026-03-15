#include "whispercpp_engine.h"

#include <fcitx-utils/log.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputpanel.h>
#include <fcitx/text.h>

namespace fcitx {

WhisperCppEngine::WhisperCppEngine(Instance* instance) : instance_(instance) {
    try {
        dbus_client_ = std::make_unique<DBusClient>();
        dbus_client_->setCompleteCallback(
            [this](const std::string& text, int segment_num) {
                onComplete(text, segment_num);
            });
        dbus_client_->setDeltaCallback(
            [this](const std::string& text) {
                onDelta(text);
            });
        dbus_client_->setErrorCallback(
            [this](const std::string& message) {
                onError(message);
            });

        int dbusFd = dbus_client_->getFileDescriptor();
        if (dbusFd >= 0) {
            event_source_ = instance_->eventLoop().addIOEvent(
                dbusFd,
                IOEventFlag::In,
                [this](EventSource*, int, IOEventFlags) {
                    dbus_client_->processEvents();
                    return true;
                });
        } else {
            event_source_ = instance_->eventLoop().addTimeEvent(
                CLOCK_MONOTONIC,
                now(CLOCK_MONOTONIC),
                100 * 1000,
                [this](EventSourceTime*, uint64_t) {
                    dbus_client_->processEvents();
                    return true;
                });
        }
    } catch (const std::exception& ex) {
        FCITX_ERROR() << "Failed to initialize whispercpp engine: " << ex.what();
    }
}

WhisperCppEngine::~WhisperCppEngine() = default;

void WhisperCppEngine::activate(const InputMethodEntry&, InputContextEvent&) {
    showStatus("W: Shift+Space to start");
}

void WhisperCppEngine::deactivate(const InputMethodEntry&, InputContextEvent&) {
    if (recording_ && dbus_client_) {
        try {
            dbus_client_->stopRecording();
        } catch (...) {
        }
    }
    recording_ = false;
    active_ic_ = nullptr;
    preedit_text_.clear();
    clearPreedit();
}

void WhisperCppEngine::keyEvent(const InputMethodEntry&, KeyEvent& event) {
    if (event.key().check(FcitxKey_space, KeyState::Shift) && !event.isRelease()) {
        active_ic_ = event.inputContext();
        toggleRecording();
        event.filterAndAccept();
    }
}

void WhisperCppEngine::reset(const InputMethodEntry&, InputContextEvent&) {
    preedit_text_.clear();
    clearPreedit();
}

void WhisperCppEngine::toggleRecording() {
    if (!dbus_client_) {
        showStatus("WhisperCpp daemon not available");
        return;
    }

    try {
        if (recording_) {
            dbus_client_->stopRecording();
            setRecording(false);
        } else {
            dbus_client_->startRecording();
            setRecording(true);
        }
    } catch (const std::exception& ex) {
        setRecording(false);
        showStatus(std::string("Error: ") + ex.what());
    }
}

void WhisperCppEngine::setRecording(bool recording) {
    recording_ = recording;
    if (recording_) {
        preedit_text_.clear();
        clearPreedit();
    }
    showStatus(recording_ ? "W: recording..." : "W: stopped");
}

void WhisperCppEngine::onDelta(const std::string& text) {
    if (text.empty()) {
        return;
    }
    preedit_text_ = text;
    setPreedit(preedit_text_);
}

void WhisperCppEngine::onComplete(const std::string& text, int) {
    preedit_text_.clear();
    clearPreedit();

    if (text.empty()) {
        return;
    }

    auto* ic = currentInputContext();
    if (!ic) {
        FCITX_WARN() << "No input context available for commit, text len=" << text.size();
        return;
    }

    FCITX_INFO() << "Committing whispercpp text len=" << text.size();
    ic->commitString(text);
    showStatus("W: text committed");
}

void WhisperCppEngine::onError(const std::string& message) {
    preedit_text_.clear();
    clearPreedit();
    setRecording(false);
    FCITX_ERROR() << "WhisperCpp D-Bus error: " << message;
    showStatus(std::string("W error: ") + message);
}

InputContext* WhisperCppEngine::currentInputContext() const {
    if (active_ic_) {
        return active_ic_;
    }
    return instance_->mostRecentInputContext();
}

void WhisperCppEngine::updatePreeditDisplay(const Text& preedit) {
    auto* ic = currentInputContext();
    if (!ic) {
        return;
    }
    ic->inputPanel().setClientPreedit(preedit);
    ic->updatePreedit();
    ic->updateUserInterface(UserInterfaceComponent::InputPanel);
}

void WhisperCppEngine::setPreedit(const std::string& text) {
    auto* ic = currentInputContext();
    if (!ic) {
        FCITX_WARN() << "No input context available for preedit, text len=" << text.size();
        return;
    }
    Text preedit;
    preedit.append(text);
    preedit.setCursor(text.size());
    updatePreeditDisplay(preedit);
}

void WhisperCppEngine::clearPreedit() {
    updatePreeditDisplay(Text());
}

void WhisperCppEngine::showStatus(const std::string& message) {
    auto* ic = currentInputContext();
    if (!ic) {
        return;
    }

    Text text;
    text.append(message);
    ic->inputPanel().setAuxUp(text);
    ic->updateUserInterface(UserInterfaceComponent::InputPanel);
}

} // namespace fcitx
