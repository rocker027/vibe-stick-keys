# YuVibeStick 唯讀探測工具

用來確認 YuVibeStick（ZMK 韌體）的 ZMK Studio RPC 介面、目前按鍵配置與自訂服務。**都不會修改按鍵設定**；只有 `vendor_notify.swift` 會開關通知訂閱（CCCD），結束前會關回去。

## 已確認的事實（2026-10-13 實機）

- 韌體：ZMK（`Manufacturer = "ZMK Project"`，VID/PID `0x1D50:0x615E`），BLE 連線。
- ZMK Studio RPC 服務 `00000000-0196-6107-c967-c5cfb1c2482a` 存在，`get_lock_state` 回報 UNLOCKED。
- `check_unsaved_changes` 回報 `true`：裝置上有尚未儲存的暫存變更。任何 `save_changes` 都會一起寫入這些變更。
- 另有賣家自訂服務 `1ACCAC91-73C2-41CA-AF88-7C02247CA900`（9 個特徵值）。按下 MIC 時會經此服務串流聲音，詳見 `docs/button-map.md`。探測工具只讀取或訂閱通知，從不寫入它的特徵值。

## 檔案

| 檔案 | 用途 |
|---|---|
| `list_services.swift` | 列出裝置所有 GATT 服務與特徵值 |
| `rpc_readonly.swift` | 送出 ZMK Studio RPC 請求；內建白名單，只放行不改狀態的請求 |
| `decode_keymap.py` | 把 `get_keymap`、`get_physical_layouts` 的回應解碼成可讀配置 |
| `hid_listen.swift` | 監聽鍵盤送出的 HID 按鍵事件（需輸入監控權限） |
| `vendor_service.swift` | 唯讀列出賣家自訂服務與 Device Information 的特徵值、描述、可讀值 |
| `vendor_notify.swift` | 訂閱自訂服務的通知（只寫 CCCD，結束前取消），用來觀察 MIC 收音串流 |
| `analyze_adpcm.py` | 用 IMA ADPCM 各種變體解碼收音原始資料並輸出 WAV 比較（格式未解開） |
| `wrap_ogg_opus.py` | 把收音原始資料包成 Ogg Opus 驗證 Opus 假設（已排除：多數封包不是合法 Opus） |

## 用法

第一次執行時，macOS 可能要求終端機取得藍牙權限。

```sh
swiftc -O rpc_readonly.swift -o /tmp/rpc_readonly

# 依序：get_device_info、get_lock_state、get_keymap、get_physical_layouts、check_unsaved_changes
/tmp/rpc_readonly 08011A020801 08021A021001 08032A020801 08042A023001 08062A021801 | tee run.txt

KM=$(grep -A1 '^>> 08032A020801' run.txt | grep '^<<' | cut -c4-)
PL=$(grep -A1 '^>> 08042A023001' run.txt | grep '^<<' | cut -c4-)
python3 -I decode_keymap.py "$KM" "$PL"
```

請求 payload 是手工編碼的 protobuf `zmk.studio.Request`，欄位編號見 [zmk-studio-messages](https://github.com/zmkfirmware/zmk-studio-messages)。

## 已知問題

- 在 zsh 用變數組多個請求時，要用陣列 `"${args[@]}"` 傳入；zsh 不會切開未加引號的 `$args`。舊版因此崩潰（exit 133），現版改為拒絕並 exit 4。
- `decode_keymap.py` 的 behavior 名稱對照表寫死在程式裡；換韌體後要重新讀取。
