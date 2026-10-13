import StickModel
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: StickViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            StickView(viewModel: viewModel)
                .opacity(viewModel.connectionStatus == .disconnected ? 0.4 : 1)
                .overlay(alignment: .top) {
                    if viewModel.connectionStatus == .disconnected {
                        Label("鍵盤未連線", systemImage: "bolt.horizontal.circle")
                            .font(.headline)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(Color.red.opacity(0.15)))
                            .padding(.top, 8)
                    }
                }
            StatusPanel(viewModel: viewModel).frame(width: 320)
        }
        .padding(28)
    }
}

/// 右側面板：配置讀取與監聽狀態、顯示層切換、圖例、最近事件。
struct StatusPanel: View {
    @ObservedObject var viewModel: StickViewModel

    static let EVENT_LOG_HEIGHT: CGFloat = 130

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("藍牙連線") {
                connectionRow
                Text("按鍵監聽：\(viewModel.hidStatus)").font(.caption).foregroundStyle(.secondary)
            }
            section("鍵盤配置") { keymapStatus }
            section("麥克風") { MicStatusView(viewModel: viewModel) }
            section("顯示層") { layerPicker }
            section("圖例") { legend }
            section("最近事件") { eventLog }
        }
    }

    private var connectionRow: some View {
        let (color, text): (Color, String) = switch viewModel.connectionStatus {
        case .checking: (.gray, "檢查中…")
        case .connected: (.green, "已連線")
        case .disconnected: (.red, "未連線：請確認鍵盤電源開啟並已在系統藍牙連線")
        case .unavailable: (.gray, "無法判斷：按鍵監聽沒有啟動")
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if let changedAt = viewModel.connectionChangedAt {
                    Text("\(changedAt) 起").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var keymapStatus: some View {
        switch viewModel.loadState {
        case .loading:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("透過藍牙讀取中…") }
        case .loaded:
            HStack {
                Text("已讀取 \(viewModel.keymap?.layers.count ?? 0) 層（唯讀）").font(.callout)
                Button("重新讀取") { viewModel.reload() }
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Text(reason).font(.callout).foregroundStyle(.red)
                Button("重試") { viewModel.reload() }
            }
        }
    }

    private var layerPicker: some View {
        Picker("", selection: $viewModel.layerOverride) {
            Text("自動（推論目前在 \(viewModel.layerName(index: viewModel.activeLayerIndex))）").tag(Int?.none)
            ForEach(Array((viewModel.keymap?.layers ?? []).enumerated()), id: \.offset) { index, layer in
                Text(layer.name).tag(Int?.some(index))
            }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(color: .green, dashed: false, text: "按下中（直接偵測）")
            legendRow(color: .red, dashed: false, text: "MIC 收音中（由自訂藍牙服務偵測）")
            legendRow(color: .orange, dashed: true, text: "推論被按住或撥著的切層鍵")
            Text("左側按鍵、背面開關不送出按鍵，只能從其他鍵推論。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func legendRow(color: Color, dashed: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(dashed ? 0.3 : 1))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : [])))
                .frame(width: 18, height: 14)
            Text(text).font(.callout)
        }
    }

    @ViewBuilder private var eventLog: some View {
        if viewModel.log.isEmpty {
            Text("按下鍵帽後會顯示在這裡").font(.callout).foregroundStyle(.secondary)
        } else {
            // 固定高度並可捲動，避免事件變多時撐高面板、超出視窗
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.log) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(entry.text).font(.callout).foregroundStyle(entry.isWarning ? Color.orange : Color.primary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: Self.EVENT_LOG_HEIGHT)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}

/// 麥克風區塊：自訂服務訂閱狀態、收音中的即時秒數與資料量、上一次收音摘要。
struct MicStatusView: View {
    @ObservedObject var viewModel: StickViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(indicatorColor).frame(width: 10, height: 10)
                Text(statusText).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            if let startedAt = viewModel.micSession.startedAt {
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    Text(String(format: "%.1f 秒 · %d 筆 · %.1f KB", context.date.timeIntervalSince1970 - startedAt,
                                viewModel.micSession.packetCount, kilobytes(viewModel.micSession.byteCount)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.red)
                }
            } else if let last = viewModel.micSession.lastSummary {
                Text(String(format: "上次收音 %.1f 秒 · %d 筆 · %.1f KB", last.duration, last.packetCount, kilobytes(last.byteCount)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                exportControls
            }
        }
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button("存成 WAV（實驗性）") { viewModel.exportLastRecording() }
                    .disabled(viewModel.lastRecordingByteCount == 0)
                if viewModel.exportedWav != nil {
                    Button("播放") { viewModel.playExported() }
                    Button("在 Finder 顯示") { viewModel.revealExported() }
                }
            }
            .controlSize(.small)
            Text("聲音編碼格式尚未解開，WAV 可能聽不出內容；原始 .adpcm 會一併保存。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = viewModel.exportMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var indicatorColor: Color {
        if viewModel.micSession.isRecording { return .red }
        return viewModel.micMonitorStatus == .subscribed ? .green : .gray
    }

    private var statusText: String {
        if viewModel.micSession.isRecording { return "收音中" }
        switch viewModel.micMonitorStatus {
        case .idle: return "未啟動"
        case .connecting: return "連線中…"
        case .subscribed: return "待命：在 L0 按住 MIC 開始收音"
        case .disconnected: return "鍵盤未連線"
        case .failed(let reason): return reason
        }
    }

    private func kilobytes(_ byteCount: Int) -> Double {
        Double(byteCount) / StickViewModel.BYTES_PER_KILOBYTE
    }
}
