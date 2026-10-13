import StickModel
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: StickViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            StickView(viewModel: viewModel)
            StatusPanel(viewModel: viewModel).frame(width: 320)
        }
        .padding(28)
    }
}

/// 右側面板：配置讀取與監聽狀態、顯示層切換、圖例、最近事件。
struct StatusPanel: View {
    @ObservedObject var viewModel: StickViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("鍵盤配置") { keymapStatus }
            section("按鍵監聽") { Text(viewModel.hidStatus).font(.callout) }
            section("顯示層") { layerPicker }
            section("圖例") { legend }
            section("最近事件") { eventLog }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: StickView.BODY_SIZE.height, alignment: .top)
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
            legendRow(color: .orange, dashed: true, text: "推論被按住或撥著的切層鍵")
            Text("MIC 的 vibe_ptt、左側按鍵、背面開關不送出按鍵，無法直接偵測。")
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
            VStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.log) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(entry.text).font(.callout).foregroundStyle(entry.isUnmatched ? Color.orange : Color.primary)
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }
}
