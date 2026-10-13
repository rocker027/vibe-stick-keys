# vibe-stick-keys

YuVibeStick 小鍵盤的專屬改鍵工具。這台鍵盤跑 ZMK 韌體並開啟 ZMK Studio；`vibe-keys` 在 macOS 透過藍牙呼叫 Studio RPC，修改按鍵並存進鍵盤。

> ⚠️ `save` 會寫入鍵盤的永久設定，而且會**一併寫入所有暫存變更**，不只是你剛改的那一鍵。存檔前先用 `probe/` 讀回目前配置。

## 建置與測試

```sh
swift build                # 產生 .build/debug/vibe-keys
./scripts/test.sh          # 協定函式庫的單元與契約測試
```

第一次連線時，macOS 可能要求終端機取得藍牙權限。鍵盤必須已在系統藍牙中連線。

## 用法

```sh
# 改一個鍵（只改執行中的配置，尚未存檔）
.build/debug/vibe-keys set <layer> <position> <behavior> <param1> [param2]

# 存進鍵盤（依序：檢查暫存變更 → 存檔 → 再檢查一次）
.build/debug/vibe-keys save

# 只印出要送的位元組，不連線
.build/debug/vibe-keys set 0 3 8 0x0807002B --dry-run
```

- `position`：0–5，對應實體 6 個鍵。
- `behavior`：裝置本地的 behavior ID，例如 `8` = Key Press。完整清單見 `probe/README.md`。
- Key Press 的 `param1` = `(修飾鍵 << 24) | (HID page << 16) | HID usage`。修飾鍵位元：LCtrl `0x01`、LShift `0x02`、LAlt `0x04`、LGUI(Cmd) `0x08`。例：Cmd+Tab = `0x0807002B`。

工具只能送出 `set_layer_binding`、`save_changes`、`check_unsaved_changes` 三種請求；不提供 discard、reset 或 layer 增刪。

## 讀回與還原

- 讀回目前配置：見 `probe/README.md` 的用法。
- 還原單一鍵：用 `set` 寫回舊值再 `save`。改鍵前的完整配置在 `snapshots/2026-10-13-before.txt`。

## 結構

| 路徑 | 內容 |
|---|---|
| `Sources/StudioProtocol/` | 框架、protobuf 編解碼、回應解析、參數檢查（純邏輯，有測試） |
| `Sources/vibe-keys/` | CoreBluetooth 傳輸與命令列 |
| `probe/` | 唯讀探測與解碼工具 |
| `snapshots/` | 改鍵前後的配置快照 |
