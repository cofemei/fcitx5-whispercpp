# 計畫：Linux 全 C++ 原生版（移除 Python daemon）

## Context

原本架構：fcitx5 plugin（C++）→ D-Bus → Python daemon（asyncio + pywhispercpp + sounddevice）

目標：把 Python daemon 完全移除，讓 fcitx5 plugin 直接包含音訊錄製與 whisper.cpp 推理，
整個系統只剩一個 C++ shared library（fcitx5 addon），零 Python 依賴。

---

## 新架構

```
Shift+Space → WhisperCppEngine::keyEvent()
                    ↓
             AudioRecorder::start()  ←── PortAudio callback（錄音 thread）
             （PCM 樣本累積在 ring buffer）
                    ↓
             Shift+Space 再次
                    ↓
             AudioRecorder::stop() → 取得完整 PCM
                    ↓
             WhisperContext::transcribe(samples)  ←── 推理 worker thread
                    ↓ （eventfd 通知）
             WhisperCppEngine 收到結果 → commitString()
```

執行緒：
- **Main thread**：fcitx5 event loop（keyEvent、commitString）
- **PortAudio callback thread**：音訊錄製（lock-free ring buffer）
- **Worker thread**：whisper.cpp 推理（阻塞操作，離開 main thread）

Main thread ↔ Worker thread 溝通：`eventfd` + `std::queue`（mutex 保護），
eventfd fd 直接餵給 `instance_->eventLoop().addIOEvent()`，與原本 D-Bus fd 用法完全相同。

---

## 移除的元件

| 移除 | 替換為 |
|------|--------|
| `plugin/dbus_client.h/.cpp` | `plugin/audio_recorder.h/.cpp` + `plugin/whisper_context.h/.cpp` |
| `daemon/` 整個目錄 | 無（功能內嵌到 plugin） |
| `dbus/` 整個目錄 | 無 |
| `systemd/fcitx5-whispercpp-daemon.service` | 無（不需要 daemon） |
| Python 依賴（pyproject.toml、.venv、uv.lock） | 無 |
| `scripts/install.sh` D-Bus + daemon 安裝步驟 | 精簡化 |

---

## 新增檔案

```
plugin/
├── audio_recorder.h       ← PortAudio 錄音封裝
├── audio_recorder.cpp
├── whisper_context.h      ← whisper.cpp C API 封裝
├── whisper_context.cpp
├── whispercpp_engine.h    ← 更新（移除 DBusClient，整合新元件）
├── whispercpp_engine.cpp  ← 更新
└── CMakeLists.txt         ← 更新（移除 D-Bus，加入 whisper.cpp + PortAudio）

config/
└── whispercpp.conf.in     ← 新增 addon 設定（model 路徑、language）
```

---

## 實作步驟

### Phase 0：CMakeLists.txt 依賴替換

移除：
```cmake
pkg_check_modules(DBUS REQUIRED dbus-1)
```

新增：
```cmake
# whisper.cpp（FetchContent 或系統安裝）
include(FetchContent)
FetchContent_Declare(whisper
    GIT_REPOSITORY https://github.com/ggerganov/whisper.cpp.git
    GIT_TAG        v1.7.3
    GIT_SHALLOW    TRUE
)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(whisper)

# PortAudio
pkg_check_modules(PORTAUDIO REQUIRED portaudio-2.0)
```

target_link_libraries 改為：
```cmake
target_link_libraries(whispercpp
    Fcitx5::Core
    Fcitx5::Utils
    whisper
    ${PORTAUDIO_LIBRARIES}
)
```

可選後端（Vulkan / CUDA）透過 cmake -D 選項傳入，與 FetchContent 的 whisper.cpp 相容。

---

### Phase 1：audio_recorder.h/.cpp

```cpp
class AudioRecorder {
public:
    AudioRecorder();                      // 初始化 PortAudio
    ~AudioRecorder();

    void start();                         // 開始錄音（PortAudio stream open）
    std::vector<float> stop();            // 停止，回傳 16kHz mono f32 PCM

private:
    static int paCallback(const void*, void*, unsigned long,
                          const PaTimestamp*, void*);
    PaStream* stream_ = nullptr;
    std::vector<float> buffer_;
    std::mutex mu_;
};
```

重點：
- PortAudio 設定：16kHz、mono、paFloat32
- callback 用 mutex-protected `buffer_` 累積樣本
- 若設備採樣率不是 16kHz，用簡單線性插值重採樣（whisper.cpp 要求 16kHz f32）

---

### Phase 2：whisper_context.h/.cpp

```cpp
class WhisperContext {
public:
    using ResultCallback = std::function<void(const std::string& text)>;
    using ErrorCallback  = std::function<void(const std::string& msg)>;

    explicit WhisperContext(const std::string& model_path);
    ~WhisperContext();

    // 在 worker thread 執行，完成後透過 eventfd 通知
    void transcribeAsync(std::vector<float> pcm,
                         const std::string& language,
                         ResultCallback on_result,
                         ErrorCallback  on_error);

    int  eventFd() const { return event_fd_; }     // 給 addIOEvent()
    void drainEvents();                             // main thread 呼叫，消費 queue

private:
    whisper_context* ctx_ = nullptr;
    int event_fd_ = -1;
    std::thread worker_;
    std::mutex queue_mu_;
    std::queue<std::function<void()>> result_queue_;
};
```

`transcribeAsync` 在 `worker_` thread 執行 `whisper_full()`，完成後：
1. push result callback 到 `result_queue_`
2. `write(event_fd_, &one, 8)` 喚醒 fcitx5 event loop

`drainEvents` 由 `addIOEvent` handler 呼叫，`read(event_fd_)` 消費後執行 queue 裡的 callback。

whisper_full_params 設定：
- `language`（來自 addon config）
- `n_threads = std::thread::hardware_concurrency() / 2`（避免搶佔 fcitx5）
- `no_context = true`（每次獨立推理）
- `print_realtime = false`、`print_progress = false`

---

### Phase 3：更新 whispercpp_engine.h/.cpp

`whispercpp_engine.h` 變更：
```cpp
// 移除
#include "dbus_client.h"
std::unique_ptr<DBusClient> dbus_client_;
std::unique_ptr<EventSource> event_source_;

// 新增
#include "audio_recorder.h"
#include "whisper_context.h"
std::unique_ptr<AudioRecorder>   recorder_;
std::unique_ptr<WhisperContext>  whisper_;
std::unique_ptr<EventSource>     event_source_;  // 監聽 whisper eventFd
bool transcribing_ = false;
```

`whispercpp_engine.cpp` 建構子邏輯：
```cpp
WhisperCppEngine::WhisperCppEngine(Instance* instance) : instance_(instance) {
    std::string model = /* 從 addon config 讀取 */;
    recorder_ = std::make_unique<AudioRecorder>();
    whisper_  = std::make_unique<WhisperContext>(model);
    event_source_ = instance_->eventLoop().addIOEvent(
        whisper_->eventFd(), IOEventFlag::In,
        [this](EventSource*, int, IOEventFlags) {
            whisper_->drainEvents();
            return true;
        });
}
```

`toggleRecording` 新邏輯：
```cpp
void WhisperCppEngine::toggleRecording() {
    if (transcribing_) return;          // 推理中不接受新請求

    if (!recording_) {
        recorder_->start();
        setRecording(true);
    } else {
        auto pcm = recorder_->stop();
        setRecording(false);
        transcribing_ = true;
        showStatus("W: transcribing...");
        whisper_->transcribeAsync(std::move(pcm), language_,
            [this](auto& text){ onComplete(text, 0); },
            [this](auto& msg) { onError(msg); });
    }
}
```

`onComplete` / `onError` 在 main thread 執行（由 drainEvents 呼叫），邏輯與現有相同，
多一行 `transcribing_ = false`。

---

### Phase 4：Addon 設定（model 路徑、language）

新增 `config/whispercpp.conf.in`（fcitx5 addon config 格式）：
```
[WhisperCpp]
ModelPath=__MODEL__
Language=__LANGUAGE__
```

`WhisperCppEngine` 在建構時透過 `fcitx::RawConfig` 讀取，
或在 cmake configure_file 時替換 `__MODEL__` placeholder（與現有 systemd service 相同模式）。

---

### Phase 5：更新 scripts/install.sh

移除：
- `uv sync`、`uv pip install` 相關步驟
- systemd service 安裝步驟
- D-Bus XML 安裝步驟
- `tools/configure_fcitx5.py` 呼叫（改為 cmake install 直接放 conf 檔）

保留：
- cmake build + install
- `fcitx5-remote -r`（重新載入 fcitx5）

新增：
- 下載 whisper.cpp model（`curl` 或 `wget` 從 huggingface.co/ggerganov/whisper.cpp）

---

## 目錄結構（最終）

```
fcitx5-whispercpp/
├── plugin/
│   ├── audio_recorder.h/.cpp     （新增）
│   ├── whisper_context.h/.cpp    （新增）
│   ├── whispercpp_engine.h/.cpp  （更新）
│   ├── whispercpp_engine_factory.cpp （不變）
│   ├── whispercpp-addon.conf.in  （更新，加入 ModelPath/Language）
│   ├── whispercpp.conf           （不變）
│   └── CMakeLists.txt            （更新）
├── scripts/
│   ├── install.sh                （精簡化）
│   └── uninstall.sh              （小幅更新）
├── CMakeLists.txt                （頂層，移除 daemon subdirectory）
└── （移除 daemon/、dbus/、systemd/）
```

---

## 關鍵設計決策

| 決策 | 理由 |
|------|------|
| PortAudio 而非直接 PulseAudio/ALSA | 跨平台（macOS 未來重用）；透過 PulseAudio/PipeWire plugin 透明運作 |
| FetchContent 而非 find_package(whisper) | 確保版本一致；使用者不需另外安裝 whisper.cpp |
| eventfd 而非 pipe | 語義更精確（計數），fcitx5 addIOEvent 直接支援 |
| worker thread 做推理 | whisper_full() 阻塞數秒，不能在 main thread 執行 |
| lock-free ring buffer → 簡化為 mutex vector | Phase 1 先求正確，效能優化留後 |
| 不做 streaming（delta）| whisper.cpp full API 比 streaming 簡單；Phase 1 先求可用 |

---

## 風險

| 風險 | 緩解 |
|------|------|
| PortAudio 找不到 PipeWire/PulseAudio 設備 | install.sh 檢查 `pw-cli` / `pactl`，提示用戶安裝 portaudio-pw |
| FetchContent 網路失敗 | 支援 `WHISPER_CPP_SOURCE_DIR` cmake 變數指向本地路徑 |
| whisper.cpp 版本 API 變動 | 固定 GIT_TAG，更新時手動驗證 |
| 推理時間 > 30s 無回應 | transcribing_ flag + status bar 顯示進度；未來加 timeout |

---

## 驗證步驟

1. **編譯驗證**：
   ```bash
   cmake -B build -DCMAKE_BUILD_TYPE=Debug
   cmake --build build -j$(nproc)
   # 無 D-Bus 相關 linker error
   ```

2. **錄音驗證**：
   ```bash
   # 在 fcitx5 plugin 外單獨測試
   cd build && ./test_audio_recorder
   # 錄 3 秒，播放確認音質
   ```

3. **推理驗證**：
   ```bash
   cd build && ./test_whisper_context --model /path/to/ggml-base.bin
   # 輸入 16kHz f32 PCM，確認輸出文字
   ```

4. **整合驗證**：
   - 重啟 fcitx5，切換到 WhisperCpp 輸入法
   - Shift+Space 開始錄音（status bar 顯示 "W: recording..."）
   - 說話後再按 Shift+Space（顯示 "W: transcribing..."）
   - 確認文字 commit 到文字框
