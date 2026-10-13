import StickModel
import SwiftUI

/// 按鈕的顯示狀態：按下中（HID 直接偵測到）或推論被按住（切層鍵，HID 看不到本身）。
enum KeyVisualState: Equatable {
    case idle
    case pressed
    case inferred
}

/// 依實機正面照片畫出 YuVibeStick：直立機身、頂部格柵、右側四顆鍵帽、左側層切換按鍵，
/// 左方另外標示看不到的背面開關。
struct StickView: View {
    @ObservedObject var viewModel: StickViewModel

    static let LEFT_MARGIN: CGFloat = 230
    static let BODY_SIZE = CGSize(width: 150, height: 560)
    static let KEYCAP_SIZE: CGFloat = 104
    static let KEYCAP_SPACING: CGFloat = 8
    static let KEYCAPS_ORIGIN = CGPoint(x: LEFT_MARGIN + 72, y: 112)
    static let SIDE_BUTTON_ORIGIN = CGPoint(x: LEFT_MARGIN - 10, y: 72)
    static let CALLOUT_WIDTH: CGFloat = 250
    static let KEYCAP_ICONS = ["MIC": "mic", "APPR": "checkmark.circle", "REJ": "xmark.circle", "OAI": "sparkles"]

    var body: some View {
        ZStack(alignment: .topLeading) {
            StickBody().offset(x: Self.LEFT_MARGIN)
            SideButton(state: state(for: 4)).offset(x: Self.SIDE_BUTTON_ORIGIN.x, y: Self.SIDE_BUTTON_ORIGIN.y)
            sideButtonCallout.offset(y: Self.SIDE_BUTTON_ORIGIN.y + 8)
            BackPanel(viewModel: viewModel).offset(y: 300)
            keycapColumn.offset(x: Self.KEYCAPS_ORIGIN.x, y: Self.KEYCAPS_ORIGIN.y)
        }
        .frame(width: Self.KEYCAPS_ORIGIN.x + Self.KEYCAP_SIZE + 20 + Self.CALLOUT_WIDTH,
               height: Self.BODY_SIZE.height, alignment: .topLeading)
    }

    private var keycapColumn: some View {
        VStack(alignment: .leading, spacing: Self.KEYCAP_SPACING) {
            ForEach(StickProfile.BUTTONS.filter { $0.role == .keycap }) { button in
                HStack(spacing: 20) {
                    KeycapView(legend: button.legend, icon: Self.KEYCAP_ICONS[button.legend] ?? "circle",
                               state: state(for: button.position))
                    KeyCallout(title: viewModel.label(position: button.position, layerIndex: viewModel.displayedLayerIndex),
                               caption: layerSummary(position: button.position), state: state(for: button.position))
                }
            }
        }
    }

    private var sideButtonCallout: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(viewModel.label(position: 4, layerIndex: viewModel.displayedLayerIndex))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(state(for: 4) == .inferred ? Color.orange : Color.primary)
            Text("左側層切換按鍵 · 位置 4").font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: Self.LEFT_MARGIN - 30, alignment: .trailing)
    }

    /// 其他層的對應，讓使用者一眼看到這顆鍵在各層的功能。
    private func layerSummary(position: Int) -> String {
        let layerCount = viewModel.keymap?.layers.count ?? 0
        let parts = (0..<layerCount).map { "L\($0) \(viewModel.label(position: position, layerIndex: $0))" }
        return (["位置 \(position)"] + parts).joined(separator: " · ")
    }

    private func state(for position: Int) -> KeyVisualState {
        if viewModel.pressedPositions.contains(position) { return .pressed }
        if viewModel.inferredLayerKeys.contains(position) { return .inferred }
        return .idle
    }
}

struct StickBody: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.99), Color(white: 0.88)], startPoint: .leading, endPoint: .trailing))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.black.opacity(0.15)))
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(white: 0.84))
                    .frame(width: 96, height: 44)
                    .overlay(HStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in Circle().fill(Color(white: 0.3)).frame(width: 14, height: 14) }
                    })
                    .padding(.top, 36)
            }
            .frame(width: StickView.BODY_SIZE.width, height: StickView.BODY_SIZE.height)
    }
}

struct KeycapView: View {
    let legend: String
    let icon: String
    let state: KeyVisualState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return shape
            .fill(state == .pressed ? Color.green : Color.white)
            .overlay(shape.stroke(Color.black.opacity(0.12)))
            .overlay(VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 26, weight: .medium))
                Text(legend).font(.system(size: 13, weight: .heavy))
            }.foregroundStyle(state == .pressed ? Color.white : Color(white: 0.2)))
            .shadow(color: state == .pressed ? Color.green.opacity(0.8) : Color.black.opacity(0.18),
                    radius: state == .pressed ? 16 : 3, y: 2)
            .scaleEffect(state == .pressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: state)
            .frame(width: StickView.KEYCAP_SIZE, height: StickView.KEYCAP_SIZE)
    }
}

struct SideButton: View {
    let state: KeyVisualState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return shape
            .fill(state == .inferred ? Color.orange.opacity(0.35) : Color.white)
            .overlay(shape.stroke(state == .inferred ? Color.orange : Color.black.opacity(0.25),
                                  style: StrokeStyle(lineWidth: state == .inferred ? 2 : 1, dash: state == .inferred ? [4, 3] : [])))
            .frame(width: 18, height: 64)
    }
}

struct KeyCallout: View {
    let title: String
    let caption: String
    let state: KeyVisualState

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 22, height: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(state == .pressed ? Color.green : Color.primary)
                Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: StickView.CALLOUT_WIDTH, alignment: .leading)
    }
}

/// 背面的兩個開關從正面看不到，另外用面板表示。層切換開關只能從收到的按鍵推論；電源開關無法偵測。
struct BackPanel: View {
    @ObservedObject var viewModel: StickViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("背面").font(.headline)
            HStack(spacing: 10) {
                SwitchGlyph(isOn: switchState == .layerOne, isInferred: viewModel.inferredLayerKeys.contains(5))
                VStack(alignment: .leading, spacing: 2) {
                    Text("層切換開關 · 位置 5").font(.subheadline.weight(.semibold))
                    Text(switchDescription).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                SwitchGlyph(isOn: true, isInferred: false).opacity(0.4)
                VStack(alignment: .leading, spacing: 2) {
                    Text("電源開關").font(.subheadline.weight(.semibold))
                    Text("硬體開關，不送出按鍵，無法偵測").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: StickView.LEFT_MARGIN - 30, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private enum SwitchState { case unknown, layerZero, layerOne }

    private var switchState: SwitchState {
        if viewModel.activeLayerIndex == 1 { return .layerOne }
        return viewModel.hasObservedKey && viewModel.activeLayerIndex == 0 ? .layerZero : .unknown
    }

    private var switchDescription: String {
        switch switchState {
        case .unknown: return "未知；按任一鍵帽後推論"
        case .layerZero: return "推論在 \(viewModel.layerName(index: 0))"
        case .layerOne: return "推論在 \(viewModel.layerName(index: 1))"
        }
    }
}

struct SwitchGlyph: View {
    let isOn: Bool
    let isInferred: Bool

    var body: some View {
        Capsule()
            .fill(isInferred ? Color.orange.opacity(0.35) : Color.secondary.opacity(0.2))
            .overlay(Capsule().stroke(isInferred ? Color.orange : Color.secondary.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 1.5, dash: isInferred ? [4, 3] : [])))
            .overlay(alignment: isOn ? .bottom : .top) {
                Circle().fill(Color.primary.opacity(0.7)).frame(width: 12, height: 12).padding(3)
            }
            .frame(width: 18, height: 40)
    }
}
