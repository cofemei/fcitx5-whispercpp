# Feature Spec：fcitx5-whispercpp Linux C++ 原生版

**版本**：0.1.0-draft
**分支**：feat/cpp-native
**日期**：2026-03-15
**範圍**：Linux only，移除 Python daemon，全部 C++17

---

## 1. 目標

| 目標 | 指標 |
|------|------|
| 零 Python 依賴 | `ldd whispercpp.so` 無 libpython |
| 安裝簡單 | `cmake --build build && cmake --install build` 完成 |
| 行為與現版相同 | Shift+Space 開始錄音 → 再按停止 → 文字 commit |
| 程式碼可讀 | 每個 .cpp 檔 < 200 行，無隱性全域狀態 |

**不在此版範圍**：streaming delta、macOS、Windows、VAD（語音活動偵測）。

---

## 2. 使用者操作流程

```
1. 使用者切換到 WhisperCpp 輸入法
2. 按 Shift+Space            → status bar 顯示 "● 錄音中"
3. 說話
4. 再按 Shift+Space          → status bar 顯示 "⏳ 辨識中..."
5. 辨識完成                  → 文字插入游標位置，status bar 顯示 "✓ 完成"
6. 按 Escape（錄音中）        → 取消錄音，status bar 清除
```

邊界情況：
- 辨識中再按 Shift+Space → 忽略（不中斷）
- 辨識出空字串 → 靜默，不 commit
- 錄音時間 > 30 秒 → 自動停止並辨識
- daemon/model 未設定 → 建構失敗並在 fcitx5 log 記錄清楚錯誤

---

## 3. 架構圖

```
┌─────────────────────────────────────────────┐
│  fcitx5 main thread                         │
│                                             │
│  WhisperCppEngine (fcitx5 addon)            │
│    keyEvent() ──→ AudioRecorder::start()    │
│                   AudioRecorder::stop()     │
│                   WhisperContext::run()  ─────────┐
│    addIOEvent(eventfd_) ←─────────────────────────┘
│    drainResults() → commitString()          │
└─────────────────────────────────────────────┘
        │                        ↑
        │ PortAudio callback    eventfd write(1)
        ↓
┌──────────────────┐   ┌────────────────────────────┐
│  PortAudio thread│   │  whisper worker thread     │
│  pa_callback()   │   │  whisper_full(ctx, pcm)    │
│  → samples_      │   │  push result → result_     │
│    .push(frame)  │   │  write(eventfd_, 1)        │
└──────────────────┘   └────────────────────────────┘
```

---

## 4. 元件規格

### 4.1 AudioRecorder

**檔案**：`plugin/audio_recorder.h`、`plugin/audio_recorder.cpp`
**責任**：錄音開始/停止，回傳 16 kHz mono f32 PCM vector

#### 公開介面

```cpp
// plugin/audio_recorder.h
#pragma once
#include <vector>
#include <stdexcept>

class AudioRecorder {
public:
    // 初始化 PortAudio；若失敗丟 std::runtime_error
    AudioRecorder();
    ~AudioRecorder();   // 停止 stream，Pa_Terminate()

    // 開始錄音；若已在錄音則 no-op
    void start();

    // 停止錄音，回傳累積的 16 kHz f32 PCM（mono）
    // 若未在錄音則回傳空 vector
    std::vector<float> stop();

    bool isRecording() const { return recording_; }

    // 不可複製、不可移動（持有 C 指標）
    AudioRecorder(const AudioRecorder&)            = delete;
    AudioRecorder& operator=(const AudioRecorder&) = delete;

private:
    static int paCallback(const void* input, void* output,
                          unsigned long frameCount,
                          const PaStreamCallbackTimeInfo*,
                          PaStreamCallbackFlags,
                          void* userData);

    void* stream_   = nullptr;   // PaStream*，void* 避免在 .h 引入 portaudio.h
    bool  recording_ = false;

    // 由 paCallback 寫入，stop() 讀取
    // SPSC：callback thread write，main thread read（stop() 後 callback 已停）
    // 因此在 stop() 後無 data race，不需 mutex
    std::vector<float> samples_;
};
```

#### 內部說明

- PortAudio 設定：`sampleRate=16000`、`framesPerBuffer=512`、`paFloat32`、`channelCount=1`
- 若設備原生採樣率不是 16 kHz，PortAudio 會透過 `paFramesPerBufferUnspecified` + `PaSampleFormat` conversion 自動重採樣（設定 `paClipOff` 避免 clipping）
- `paCallback` 只做 `samples_.insert(end, input, input+frameCount)`，不做其他操作（real-time safe）
- `stop()` 呼叫 `Pa_StopStream()`（blocking，等 callback 結束）再讀 `samples_`，無 race

#### 錯誤處理

| 情況 | 處理 |
|------|------|
| `Pa_Initialize()` 失敗 | 建構子丟 `std::runtime_error(Pa_GetErrorText(err))` |
| `Pa_OpenDefaultStream()` 失敗 | 丟 `std::runtime_error` |
| `Pa_StartStream()` 失敗 | `start()` 丟 `std::runtime_error` |

---

### 4.2 WhisperContext

**檔案**：`plugin/whisper_context.h`、`plugin/whisper_context.cpp`
**責任**：載入 whisper.cpp model，在 worker thread 執行推理，
用 `eventfd` 通知 fcitx5 main thread

#### 公開介面

```cpp
// plugin/whisper_context.h
#pragma once
#include <functional>
#include <string>
#include <vector>

class WhisperContext {
public:
    using ResultFn = std::function<void(std::string text)>;
    using ErrorFn  = std::function<void(std::string message)>;

    // 載入 model_path；失敗丟 std::runtime_error
    // language 為 whisper language code，例如 "zh"、"en"、"auto"
    WhisperContext(const std::string& model_path,
                   const std::string& language);
    ~WhisperContext();   // 等待 worker thread 結束

    // 在 worker thread 執行 whisper_full()
    // 完成後呼叫 on_result 或 on_error（在 main thread via eventfd）
    // 若上一次推理未完成，丟 std::logic_error（caller 應先檢查 busy()）
    void run(std::vector<float> pcm, ResultFn on_result, ErrorFn on_error);

    bool busy() const;

    // 回傳 eventfd，供 fcitx5 addIOEvent() 使用
    int eventFd() const { return event_fd_; }

    // 由 addIOEvent handler 在 main thread 呼叫
    // read(eventfd)，執行 pending callback
    void drainResults();

    WhisperContext(const WhisperContext&)            = delete;
    WhisperContext& operator=(const WhisperContext&) = delete;

private:
    struct whisper_context* ctx_ = nullptr;
    std::string language_;
    int event_fd_ = -1;

    // Worker thread 狀態（以 atomic 保護）
    std::atomic<bool> busy_  = false;

    // Result queue（mutex 保護，main thread 讀，worker thread 寫）
    std::mutex          result_mu_;
    std::function<void()> pending_result_;   // 最多一個（busy_ 保證）
};
```

#### 內部說明

**run() 實作**：

```cpp
void WhisperContext::run(std::vector<float> pcm,
                         ResultFn on_result, ErrorFn on_error) {
    // pcm 移入 lambda，worker thread 獨佔
    std::thread([this,
                 pcm    = std::move(pcm),
                 on_res = std::move(on_result),
                 on_err = std::move(on_error)] {
        // --- 執行在 worker thread ---
        whisper_full_params params = whisper_full_default_params(
                                         WHISPER_SAMPLING_GREEDY);
        params.language       = language_.c_str();
        params.n_threads      = std::max(1,
                                    (int)std::thread::hardware_concurrency() / 2);
        params.print_realtime = false;
        params.print_progress = false;
        params.no_context     = true;

        std::function<void()> callback;
        if (whisper_full(ctx_, params, pcm.data(), (int)pcm.size()) == 0) {
            std::string result;
            for (int i = 0; i < whisper_full_n_segments(ctx_); ++i)
                result += whisper_full_get_segment_text(ctx_, i);
            callback = [res = std::move(result), on_res] { on_res(res); };
        } else {
            callback = [on_err] { on_err("whisper_full() failed"); };
        }

        {
            std::lock_guard lock(result_mu_);
            pending_result_ = std::move(callback);
        }
        uint64_t one = 1;
        write(event_fd_, &one, sizeof(one));   // 喚醒 main thread
    }).detach();
    // detach 是可以的：worker 僅寫入 pending_result_ + event_fd_，
    // ~WhisperContext 透過 busy_ 確保不在推理中（caller 保證）
}
```

**drainResults() 實作**：

```cpp
void WhisperContext::drainResults() {
    uint64_t val;
    read(event_fd_, &val, sizeof(val));   // 消費 eventfd 計數

    std::function<void()> cb;
    {
        std::lock_guard lock(result_mu_);
        cb = std::move(pending_result_);
    }
    busy_ = false;
    if (cb) cb();   // 呼叫 on_result 或 on_error（在 main thread）
}
```

> **為何用 detach 而非 jthread？**
> `jthread` 解構時會 join，但 `WhisperContext` 可能在 worker 還在跑時被解構（例如 fcitx5 addon 卸載）。
> 實務上推理時間 < 30s，改以 `busy_` 在解構前 spin-wait（最多 100ms），若超時 FCITX_WARN 後繼續。

---

### 4.3 WhisperCppEngine（更新）

**檔案**：`plugin/whispercpp_engine.h`、`plugin/whispercpp_engine.cpp`
**變更摘要**：移除 `DBusClient`，加入 `AudioRecorder` + `WhisperContext`

#### 更新後的標頭

```cpp
// plugin/whispercpp_engine.h（更新）
#pragma once
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>
#include <fcitx-utils/event.h>
#include <memory>
#include <string>

#include "audio_recorder.h"
#include "whisper_context.h"

namespace fcitx {

class WhisperCppEngine final : public InputMethodEngineV2 {
public:
    explicit WhisperCppEngine(Instance* instance);
    ~WhisperCppEngine() override;

    void activate(const InputMethodEntry&, InputContextEvent&) override;
    void deactivate(const InputMethodEntry&, InputContextEvent&) override;
    void keyEvent(const InputMethodEntry&, KeyEvent&) override;
    void reset(const InputMethodEntry&, InputContextEvent&) override;

private:
    void startRecording();
    void stopAndTranscribe();
    void cancelRecording();
    void onResult(std::string text);
    void onError(std::string message);
    void showStatus(std::string_view message);
    InputContext* currentIc() const;

    Instance*                    instance_     = nullptr;
    std::unique_ptr<AudioRecorder>  recorder_;
    std::unique_ptr<WhisperContext> whisper_;
    std::unique_ptr<EventSource>    io_event_;   // 監聽 whisper_.eventFd()
    bool                          recording_   = false;
    std::string                   preedit_;
    InputContext*                 active_ic_   = nullptr;
};

} // namespace fcitx
```

#### keyEvent 邏輯

```cpp
void WhisperCppEngine::keyEvent(const InputMethodEntry&, KeyEvent& event) {
    if (event.isRelease()) return;

    // Escape：取消錄音
    if (recording_ && event.key().check(FcitxKey_Escape)) {
        cancelRecording();
        event.filterAndAccept();
        return;
    }

    // Shift+Space：toggle
    if (event.key().check(FcitxKey_space, KeyState::Shift)) {
        active_ic_ = event.inputContext();
        if (!recording_) {
            if (whisper_->busy()) {
                showStatus("⏳ 辨識中，請稍候");
            } else {
                startRecording();
            }
        } else {
            stopAndTranscribe();
        }
        event.filterAndAccept();
    }
}
```

#### 建構子

```cpp
WhisperCppEngine::WhisperCppEngine(Instance* instance) : instance_(instance) {
    // model 路徑從環境變數或 fcitx5 addon config 取得（見 §4.4）
    const char* model    = std::getenv("WHISPERCPP_MODEL");
    const char* language = std::getenv("WHISPERCPP_LANGUAGE");

    if (!model || *model == '\0') {
        FCITX_ERROR() << "[WhisperCpp] WHISPERCPP_MODEL not set. "
                         "Run: export WHISPERCPP_MODEL=/path/to/ggml-base.bin";
        return;   // recorder_/whisper_ 保持 nullptr，keyEvent 中安全跳過
    }

    try {
        recorder_ = std::make_unique<AudioRecorder>();
        whisper_  = std::make_unique<WhisperContext>(
                        model,
                        language ? language : "auto");
        io_event_ = instance_->eventLoop().addIOEvent(
            whisper_->eventFd(), IOEventFlag::In,
            [this](EventSource*, int, IOEventFlags) {
                whisper_->drainResults();
                return true;
            });
    } catch (const std::exception& ex) {
        FCITX_ERROR() << "[WhisperCpp] init failed: " << ex.what();
        recorder_.reset();
        whisper_.reset();
        io_event_.reset();
    }
}
```

---

### 4.4 設定（環境變數，Phase 1 使用）

Phase 1 直接讀環境變數，不引入 fcitx5 addon config 系統（KISS）。

| 變數 | 預設 | 說明 |
|------|------|------|
| `WHISPERCPP_MODEL` | 無（必填） | ggml model 檔案路徑，例如 `/home/user/.cache/whisper/ggml-base.bin` |
| `WHISPERCPP_LANGUAGE` | `auto` | whisper language code：`zh`、`en`、`ja`、`auto` 等 |

systemd user service（`~/.config/systemd/user/fcitx5.service.d/whisper.conf`）可設定：
```ini
[Service]
Environment=WHISPERCPP_MODEL=%h/.cache/whisper/ggml-base.bin
Environment=WHISPERCPP_LANGUAGE=zh
```

---

## 5. CMakeLists.txt 規格

**頂層 `CMakeLists.txt`**（現有）：無須修改，只更新 `plugin/` 子目錄。

**`plugin/CMakeLists.txt`**：

```cmake
cmake_minimum_required(VERSION 3.21)

# --- 依賴 ---

find_package(PkgConfig REQUIRED)

# PortAudio
pkg_check_modules(PORTAUDIO REQUIRED portaudio-2.0)

# whisper.cpp：優先用本地路徑，否則 FetchContent
if(DEFINED WHISPER_CPP_SOURCE_DIR)
    add_subdirectory(${WHISPER_CPP_SOURCE_DIR} whisper_cpp_build EXCLUDE_FROM_ALL)
else()
    include(FetchContent)
    FetchContent_Declare(whisper
        GIT_REPOSITORY https://github.com/ggerganov/whisper.cpp.git
        GIT_TAG        v1.7.3
        GIT_SHALLOW    TRUE
    )
    set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
    set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(whisper)
endif()

# --- Target ---

set(SOURCES
    audio_recorder.cpp
    whisper_context.cpp
    whispercpp_engine.cpp
    whispercpp_engine_factory.cpp
)

add_library(whispercpp MODULE ${SOURCES})

target_compile_features(whispercpp PRIVATE cxx_std_17)

target_include_directories(whispercpp PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${PORTAUDIO_INCLUDE_DIRS}
)

target_link_libraries(whispercpp PRIVATE
    Fcitx5::Core
    Fcitx5::Utils
    whisper
    ${PORTAUDIO_LIBRARIES}
)

set_target_properties(whispercpp PROPERTIES PREFIX "")

# --- Install ---

if(NOT DEFINED CMAKE_INSTALL_LIBDIR)
    set(CMAKE_INSTALL_LIBDIR "${CMAKE_INSTALL_PREFIX}/lib")
endif()
if(NOT DEFINED CMAKE_INSTALL_DATADIR)
    set(CMAKE_INSTALL_DATADIR "${CMAKE_INSTALL_PREFIX}/share")
endif()

install(TARGETS whispercpp
    LIBRARY DESTINATION "${CMAKE_INSTALL_LIBDIR}/fcitx5")

configure_file(whispercpp-addon.conf.in whispercpp-addon.conf COPYONLY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/whispercpp-addon.conf"
    RENAME whispercpp.conf
    DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5/addon")
install(FILES whispercpp.conf
    DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5/inputmethod")
```

---

## 6. 移除的元件

以下目錄/檔案在此 branch 移除或標記廢棄（不立即刪除，等驗證完成後清理）：

| 路徑 | 動作 |
|------|------|
| `plugin/dbus_client.h` | 移除 |
| `plugin/dbus_client.cpp` | 移除 |
| `daemon/` | 整個目錄移除 |
| `dbus/` | 整個目錄移除 |
| `systemd/fcitx5-whispercpp-daemon.service` | 移除 |
| `pyproject.toml`、`uv.lock`、`.python-version` | 移除 |
| `tools/` | 移除（原本只服務 Python daemon）|

---

## 7. 更新的 scripts/install.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODEL="${1:-}"
LANGUAGE="${2:-auto}"
LOCAL_INSTALL=false

usage() {
    echo "Usage: $0 [--local] <model-path> [language]"
    echo "  model-path  path to ggml model, e.g. ~/.cache/whisper/ggml-base.bin"
    echo "  language    whisper language code (default: auto)"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local) LOCAL_INSTALL=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) MODEL="$1"; shift; LANGUAGE="${1:-auto}"; break ;;
    esac
done

if [[ -z "$MODEL" ]]; then
    echo "Error: model path required" >&2
    usage; exit 1
fi

echo "==> Building plugin"
mkdir -p "$PROJECT_ROOT/build"
(
    cd "$PROJECT_ROOT/build"
    PREFIX="$HOME/.local"
    [[ "$LOCAL_INSTALL" == false ]] && PREFIX="/usr"
    cmake .. -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release
    make -j"$(nproc)"
    if [[ "$LOCAL_INSTALL" == false ]]; then sudo make install; else make install; fi
)

echo "==> Setting environment for fcitx5"
OVERRIDE_DIR="$HOME/.config/systemd/user/fcitx5.service.d"
mkdir -p "$OVERRIDE_DIR"
cat > "$OVERRIDE_DIR/whisper.conf" <<EOF
[Service]
Environment=WHISPERCPP_MODEL=$MODEL
Environment=WHISPERCPP_LANGUAGE=$LANGUAGE
EOF
systemctl --user daemon-reload
systemctl --user restart fcitx5 || true

echo "==> Reloading fcitx5"
fcitx5-remote -r 2>/dev/null || echo "Restart fcitx5 manually."

echo "Done. Model: $MODEL, Language: $LANGUAGE"
```

---

## 8. 程式碼風格規範（適用本專案）

根據 CppCoreGuidelines 2025 + KISS 原則，本專案的具體規則：

### 命名
- 類別：`PascalCase`（`AudioRecorder`、`WhisperContext`）
- 私有成員：`snake_case_`（trailing underscore）
- 函式：`camelCase`（`startRecording`、`drainResults`）
- 常數：`k_snake_case` 或 `kPascalCase`（C++ Core Guidelines 風格）

### 記憶體
- `unique_ptr` 為預設選擇；`shared_ptr` 僅在確實共享 ownership 時使用
- 禁止裸指標 ownership（例外：PortAudio/whisper.cpp C API 回傳的 opaque pointer，包裝在 RAII 類別內）
- 使用 `make_unique<T>()`，不直接 `new`

### 執行緒
- `std::jthread` 用於生命週期明確的 thread
- `std::atomic<bool>` 用於 flag，不用 `volatile`
- audio callback thread 不呼叫任何可能 allocate / lock 的函式（POSIX real-time safety rule）
- 跨 thread 資料傳遞：移動語義（`std::move`）而非複製

### 錯誤處理
- 建構子失敗：丟 `std::runtime_error`（RAII 保證物件有效或不存在）
- 預期可恢復的錯誤（e.g., 辨識失敗）：透過 callback 回報，不丟 exception
- `std::expected<T,E>` 留待 C++23 compiler 普及後使用（目前 GCC 12+ 支援，但 fcitx5 build system 尚需驗證）

### 一般規則
- 每個 .h/.cpp 對：單一職責，< 200 行
- 沒有全域變數（fcitx5 addon factory 除外）
- 優先用標準庫；引入第三方函式庫需有充分理由
- 不寫「以後可能用到」的抽象

---

## 9. 驗證清單

### 編譯
- [ ] `cmake -B build -DCMAKE_BUILD_TYPE=Debug && cmake --build build` 無 error 無 warning
- [ ] `ldd build/plugin/whispercpp.so | grep python` 無輸出
- [ ] `ldd build/plugin/whispercpp.so | grep dbus` 無輸出

### 功能
- [ ] 設定 `WHISPERCPP_MODEL`，重啟 fcitx5，輸入法出現在列表
- [ ] 切換輸入法，status bar 顯示 "W: Shift+Space to start"
- [ ] Shift+Space → "● 錄音中"
- [ ] 說 "你好" → Shift+Space → "⏳ 辨識中..." → commit "你好"
- [ ] Escape 取消錄音
- [ ] 辨識中再按 Shift+Space → 被忽略
- [ ] 未設定 `WHISPERCPP_MODEL`：fcitx5 log 有清楚錯誤，不 crash

### 穩定性
- [ ] 切換 10 次輸入法不 crash
- [ ] 連續錄音/辨識 5 次不 crash
- [ ] `valgrind --tool=memcheck` 無 definitely lost

---

## 10. 開發順序

```
Phase 0  CMakeLists.txt 修改（先確認能 link）
    ↓
Phase 1  audio_recorder.h/.cpp（獨立測試）
    ↓
Phase 2  whisper_context.h/.cpp（獨立測試）
    ↓
Phase 3  whispercpp_engine.cpp 更新（接線）
    ↓
Phase 4  刪除 daemon/、dbus/、Python 檔案
    ↓
Phase 5  install.sh 精簡化
    ↓
Phase 6  驗證清單全過
```
