# YuVibeStick 唯讀探測工具

用來確認 YuVibeStick（ZMK 韌體）的 ZMK Studio RPC 介面與目前按鍵配置。**全部都只讀取，不會修改鍵盤。**

## 已確認的事實（2026-10-13 實機）

- 韌體：ZMK（`Manufacturer = "ZMK Project"`，VID/PID `0x1D50:0x615E`），BLE 連線。
- ZMK Studio RPC 服務 `00000000-0196-6107-c967-c5cfb1c2482a` 存在，`get_lock_state` 回報 UNLOCKED。
- `check_unsaved_changes` 回報 `true`：裝置上有尚未儲存的暫存變更。任何 `save_changes` 都會一起寫入這些變更。
- 另有賣家自訂服務 `1ACCAC91-73C2-41CA-AF88-7C02247CA900`（9 個特徵值），用途未知，本工具不碰。

## 檔案

| 檔案 | 用途 |
|---|---|
| `list_services.swift` | 列出裝置所有 GATT 服務與特徵值 |
| `rpc_readonly.swift` | 送出 ZMK Studio RPC 請求；內建白名單，只放行不改狀態的請求 |
| `decode_keymap.py` | 把 `get_keymap`、`get_physical_layouts` 的回應解碼成可讀配置 |

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
