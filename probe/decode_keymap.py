"""把 rpc_readonly 輸出的 get_keymap / get_physical_layouts 回應（hex）解碼成可讀文字。

BEHAVIORS 對照表是 2026-10-13 從 YuVibeStick 實機 get_behavior_details 讀出，換韌體後要重讀。
"""
import sys

BEHAVIORS = {1: "Mouse Key Press", 2: "mouse_move", 3: "mouse_scroll", 4: "Bluetooth", 5: "Bootloader",
             6: "Caps Word", 7: "External Power", 8: "Key Press", 9: "Grave/Escape", 10: "Key Repeat",
             11: "Key Toggle", 12: "Momentary Layer", 13: "Layer-Tap", 14: "Mod-Tap", 15: "None",
             16: "Output Selection", 17: "Sticky Key", 18: "Sticky Layer", 19: "Studio Unlock", 20: "Reset",
             21: "To Layer", 22: "Toggle Layer", 23: "z_so_off", 24: "Transparent", 25: "vibe_ptt"}
KBD = {0x28: "Enter", 0x29: "Esc", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space", 0x4F: "Right", 0x50: "Left",
       0x51: "Down", 0x52: "Up", 0x4A: "Home", 0x4D: "End", 0x4B: "PgUp", 0x4E: "PgDn", 0x4C: "Delete"}
KBD.update({0x04 + i: chr(ord("A") + i) for i in range(26)})
KBD.update({0x1E + i: str((i + 1) % 10) for i in range(10)})
CONS = {0xCD: "Play/Pause", 0xB5: "Next", 0xB6: "Prev", 0xE9: "Vol+", 0xEA: "Vol-", 0xE2: "Mute"}
MODS = ["LCtrl", "LShift", "LAlt", "LGUI", "RCtrl", "RShift", "RAlt", "RGUI"]


def varint(b, i):
    r = s = 0
    while True:
        byte = b[i]; i += 1; r |= (byte & 0x7F) << s; s += 7
        if not byte & 0x80:
            return r, i


def fields(b):
    i, out = 0, []
    while i < len(b):
        k, i = varint(b, i)
        f, wt = k >> 3, k & 7
        if wt == 0:
            v, i = varint(b, i)
        elif wt == 2:
            n, i = varint(b, i); v = b[i:i + n]; i += n
        else:
            raise ValueError(wt)
        out.append((f, v))
    return out


def zz(n):
    return (n >> 1) ^ -(n & 1)


def first(fs, n, default=None):
    return next((v for f, v in fs if f == n), default)


def usage(p):
    page, uid, mods = (p >> 16) & 0xFF, p & 0xFFFF, (p >> 24) & 0xFF
    name = (KBD if page == 7 else CONS if page == 12 else {}).get(uid, f"page{page}:0x{uid:02X}")
    mod = "+".join(m for i, m in enumerate(MODS) if mods & (1 << i))
    return f"{mod}+{name}" if mod else name


def binding(bb):
    fs = fields(bb)
    bid, p1, p2 = zz(first(fs, 1, 0)), first(fs, 2, 0), first(fs, 3, 0)
    name = BEHAVIORS.get(bid, f"behavior#{bid}")
    if bid in (8, 11, 17):
        return f"{name}({usage(p1)})"
    if bid == 14:
        return f"{name}(hold={usage(p1)}, tap={usage(p2)})"
    if bid == 13:
        return f"{name}(layer={p1}, tap={usage(p2)})"
    if bid in (12, 18, 21, 22):
        return f"{name}(layer={p1})"
    return name + (f"(p1={p1}, p2={p2})" if p1 or p2 else "")


def resp_inner(hexstr):
    rr = first(fields(bytes.fromhex(hexstr)), 1)        # Response.request_response 欄位
    return fields(first(fields(rr), 5))  # keymap.Response 欄位


def main(keymap_hex, layouts_hex):
    km = first(resp_inner(keymap_hex), 1)
    kfs = fields(km)
    print(f"available_layers={first(kfs, 2, 0)} max_layer_name_length={first(kfs, 3, 0)}")
    for f, layer in kfs:
        if f != 1:
            continue
        lf = fields(layer)
        print(f"\nLayer id={first(lf, 1, 0)} name={first(lf, 2, b'').decode()!r}")
        for pos, bb in enumerate(v for f2, v in lf if f2 == 3):
            print(f"  key_position {pos}: {binding(bb)}")
    pl = fields(first(resp_inner(layouts_hex), 6))
    print(f"\nactive_layout_index={first(pl, 1, 0)}")
    for f, lay in pl:
        if f != 2:
            continue
        lf = fields(lay)
        print(f"layout {first(lf, 1, b'').decode()!r}:")
        for pos, k in enumerate(v for f2, v in lf if f2 == 2):
            a = {n: zz(v) for n, v in fields(k)}
            print(f"  key {pos}: w={a.get(1, 0)} h={a.get(2, 0)} x={a.get(3, 0)} y={a.get(4, 0)}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
