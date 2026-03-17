# fcitx5-whispercpp

由 [whisper.cpp](https://github.com/ggerganov/whisper.cpp) 驅動、透過 [pywhispercpp](https://github.com/abdeladim-s/pywhispercpp) 提供的本機語音轉文字 fcitx5 輸入法。

本專案受 [fcitx5-voice](https://github.com/gyu-don/fcitx5-voice) 啟發。

按下 `Shift+Space` 開始錄音，再按一次停止 — 轉錄的文字會自動提交到活躍的輸入欄位。

## 架構

三個元件透過 D-Bus 通訊：

1. **C++ 外掛** — fcitx5 輸入法引擎；處理鍵盤事件並將文字提交到活躍的輸入上下文
2. **Python daemon** — 透過 sounddevice 錄音並使用 pywhispercpp 執行本機 whisper 轉錄
3. **D-Bus 介面** — `org.fcitx.Fcitx5.WhisperCpp` 協調錄音控制和文字傳送

一切都在本機執行 — 轉錄不需要網路存取。

## 需求

- Linux + fcitx5
- C++ 編譯工具：`cmake`、`g++`、`pkg-config`、`libdbus-1-dev`、fcitx5 開發標頭檔
- Python 3.12+
- [`uv`](https://github.com/astral-sh/uv)

## 安裝

```bash
./scripts/install.sh
```

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `--model <name>` | `base` | 要使用的 Whisper 模型 |
| `--language <code>` | `zh` | 轉錄語言代碼 |

安裝路徑始終為 `~/.local`（不需要 sudo）。

**模型選項：**

```bash
# 內建 pywhispercpp 模型名稱
./scripts/install.sh --model base

# 本機 .gguf / .bin 檔案
./scripts/install.sh --model /path/to/model.gguf

# Hugging Face 儲存庫（自動選擇最佳 .gguf/.bin 檔案）
./scripts/install.sh --model username/repo

# Hugging Face 儲存庫的特定檔案
./scripts/install.sh --model username/repo@ggml-model-q5_k.gguf
```

下載的 HF 模型快取在 `~/.cache/fcitx5-whispercpp/models/`。

**GPU 加速：**

```bash
GGML_VULKAN=1 ./scripts/install.sh      # Vulkan (AMD / Intel)
GGML_CUDA=1   ./scripts/install.sh      # CUDA (NVIDIA)
WHISPER_CUDA=1 ./scripts/install.sh     # GGML_CUDA 的別名
```

**Whisper 提示詞：**

在執行安裝前編輯 `prompt.md` 以設定轉錄提示詞，可包含範例句子或詞彙。該檔案會複製到 `~/.config/fcitx5-whispercpp/prompt.md` 並在每次轉錄時作為 `initial_prompt` 傳給 whisper。

## 安裝後

1. 開啟 fcitx5 設定 → **輸入法**。
2. 新增 **fcitx5-whispercpp**。
3. 切換到此輸入法。
4. 按 **Shift+Space** 開始錄音；再按一次停止並提交。

輸入欄位中的狀態指示器顯示目前狀態：

| 顯示 | 狀態 |
|------|------|
| `W: Shift+Space to start` | 閒置，等待中 |
| `W: recording...` | 錄音中 |
| `W: stopped` | 處理中 |
| `W: text committed` | 完成 |

## 解除安裝

```bash
./scripts/uninstall.sh
```

移除：外掛檔案、systemd 服務、D-Bus 介面檔案、daemon 符號連結、`~/.config/fcitx5-whispercpp/`，以及 `~/.config/fcitx5/profile` 中的 whispercpp 項目。

## 目錄結構

```text
fcitx5-whispercpp/
├── CMakeLists.txt                       C++ 編譯根目錄
├── daemon/                              Python D-Bus daemon
│   ├── __init__.py
│   ├── dbus_service.py                  錄音機 + WhisperCppService
│   └── main.py                          進入點 (CLI)
├── dbus/
│   └── org.fcitx.Fcitx5.WhisperCpp.xml D-Bus 介面定義
├── plugin/                              C++ fcitx5 外掛
│   ├── CMakeLists.txt
│   ├── dbus_client.cpp / .h             低層 D-Bus 用戶端
│   ├── whispercpp_engine.cpp / .h       輸入法引擎
│   ├── whispercpp_engine_factory.cpp
│   ├── whispercpp-addon.conf.in         外掛設定範本
│   └── whispercpp.conf                  輸入法註冊檔
├── prompt.md                            預設 whisper 初始提示詞
├── pyproject.toml
├── scripts/
│   ├── install.sh
│   └── uninstall.sh
├── systemd/
│   └── fcitx5-whispercpp-daemon.service Systemd 使用者服務範本
├── tools/                               安裝/解除安裝輔助程式
│   ├── configure_fcitx5.py              寫入 fcitx5 設定檔 + 熱鍵設定
│   ├── deconfigure_fcitx5.py            從 fcitx5 設定檔移除 whispercpp
│   └── resolve_hf_model.py              從 Hugging Face 下載模型
└── uv.lock
```

## 開發

使用專案環境執行 lint/format 檢查：

```bash
uv run ruff check daemon tools
uv run ruff format daemon tools
uv run shellcheck -x scripts/*.sh
```

## 自動化

- **CI (`.github/workflows/ci.yml`)**: 在推送/PR 到 `main` 時執行，檢查 Python lint/format、shell 腳本和工作流程語法。
- **CodeQL (`.github/workflows/codeql.yml`)**: 在推送/PR 到 `main` 和每週執行 Python/C++ 靜態分析。
- **Dependabot (`.github/dependabot.yml`)**: 每週更新 GitHub Actions 和 Python 依賴。
- **Release (`.github/workflows/release.yml`)**: 推送像 `v0.1.0` 的標籤以建立自動生成說明的 GitHub Release。
- **Release message 範本 (`.github/release.yml`)**: 透過 PR 標籤控制 release 說明類別。

## License

本專案採用 Apache License 2.0。詳見 [LICENSE](LICENSE) 檔案。
