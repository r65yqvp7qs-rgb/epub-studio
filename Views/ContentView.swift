import SwiftUI
import AppKit

@MainActor
struct ContentView: View {

    @StateObject private var state = AppState()

    var body: some View {
        VStack(spacing: 20) {

            // ===== 入力フォルダ =====
            HStack {
                Text("入力フォルダ:")
                    .bold()

                if let url = state.inputFolderURL {
                    Text(url.path)
                        .font(.caption)
                        .lineLimit(1)
                } else {
                    Text("未選択")
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("フォルダ選択") {
                    pickFolder()
                }
                .disabled(state.isProcessing)
            }
            .padding(.horizontal)

            // ===== 進捗 =====
            if state.isProcessing {
                VStack(spacing: 10) {
                    ProgressView(value: state.progress)
                        .progressViewStyle(.linear)
                        .padding(.horizontal)

                    Text(String(format: "%.1f %%", state.progress * 100))
                        .font(.caption)
                }
            }

            // ===== 実行ボタン =====
            Button(action: {
                Task { await startConversion() }
            }) {
                Text(state.isProcessing ? "処理中…" : "EPUB 生成開始")
                    .bold()
                    .padding()
                    .frame(maxWidth: .infinity)
            }
            .background(state.isProcessing ? Color.gray : Color.blue)
            .foregroundColor(.white)
            .cornerRadius(8)
            .padding(.horizontal)
            .disabled(state.isProcessing || state.inputFolderURL == nil)

            // ===== ログ =====
            VStack(alignment: .leading, spacing: 8) {
                Text("ログ:")
                    .bold()
                ScrollView {
                    Text(state.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color(NSColor.textBackgroundColor))
                .border(Color.secondary, width: 1)
            }
            .padding()

            Spacer()
        }
        .frame(minWidth: 700, minHeight: 600)
    }

    // MARK: - フォルダ選択
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK {
            state.inputFolderURL = panel.url
        }
    }

    // MARK: - 変換開始（async/await & MainActor）
    @MainActor
    private func startConversion() async {
        guard let folderURL = state.inputFolderURL else { return }

        state.isProcessing = true
        state.resetProgress()
        state.appendLog("=== 変換開始 ===")

        do {
            // Converter.run は async → await 必須
            try await Converter.run(
                inputFolder: folderURL,
                state: state
            )
        } catch {
            state.appendLog("⚠ エラー: \(error.localizedDescription)")
        }

        state.isProcessing = false
        state.appendLog("=== 完了 ===")
    }
}
