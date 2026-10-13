/// YuVibeStick 的實體按鈕。position 對應 ZMK keymap 的 key position。
public struct StickButton: Equatable, Identifiable, Sendable {
    public enum Role: Equatable, Sendable {
        case keycap
        case backSwitch
    }

    public let position: Int
    /// 鍵帽或機身上的印字，例如 MIC、APPR。
    public let legend: String
    public let title: String
    public let role: Role
    public var id: Int { position }
}

/// 依實機照片與 docs/button-map.md 的實測：正面四顆鍵帽由上到下是位置 0–3，背面層切換開關推論為位置 5。
/// 左側按鍵不在此列：它是 Studio 看不到的第 7 個韌體位置（2026-10-14 實測位置 4 沒有接到任何實體按鍵）。
/// 背面另有電源開關，不送出按鍵。
public enum StickProfile {
    public static let BUTTONS: [StickButton] = [
        StickButton(position: 0, legend: "MIC", title: "MIC 鍵帽", role: .keycap),
        StickButton(position: 1, legend: "APPR", title: "APPR 鍵帽", role: .keycap),
        StickButton(position: 2, legend: "REJ", title: "REJ 鍵帽", role: .keycap),
        StickButton(position: 3, legend: "OAI", title: "OAI 鍵帽", role: .keycap),
        StickButton(position: 5, legend: "層切換開關", title: "背面層切換開關", role: .backSwitch),
    ]

    public static func button(at position: Int) -> StickButton? {
        BUTTONS.first { $0.position == position }
    }

    /// 指定角色的按鈕位置，例如背面層切換開關。UI 依此找位置，不寫死數字。
    public static func position(of role: StickButton.Role) -> Int? {
        BUTTONS.first { $0.role == role }?.position
    }
}
