// Views/ContentView.swift

import SwiftUI
import AppKit

@MainActor
struct ContentView: View {

    @StateObject private var state = AppState()
    @State private var isLogVisible: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // タイトル
            Text("EPUB Studio")
                .font(.title2)
                .bold()
                .padding(.top, 8)

            // ===== 入力フォルダ =====
            HStack(spacing: 12) {
                Text("入力フォルダ")
                    .font(.headline)

                if let url = state.inputFolderURL {
                    Text(url.path)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("未選択")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("フォルダ選択") {
                    pickFolder()
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(state.isProcessing)
            }

            Divider()

            // ===== 工程別 進行状況（プランB：3工程） =====
            VStack(alignment: .leading, spacing: 10) {
                Text("進行状況")
                    .font(.headline)

                ProgressRow(
                    title: "画像準備（JPEG変換・情報収集）",
                    progress: state.phase1Progress
                )

                ProgressRow(
                    title: "ページ構築（見開き判定・レイアウト）",
                    progress: state.phase2Progress
                )

                ProgressRow(
                    title: "EPUB構築（パッケージング）",
                    progress: state.phase3Progress
                )
            }

            Divider()

            // ===== 実行ボタン ＋ ログ表示切り替え =====
            HStack(spacing: 12) {
                Button(action: startConversion) {
                    Text(state.isProcessing ? "処理中…" : "EPUB 生成開始")
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.isProcessing || state.inputFolderURL == nil)

                Button {
                    isLogVisible.toggle()
                } label: {
                    Label(isLogVisible ? "ログを隠す" : "ログを表示", systemImage: "text.bubble")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }

            // ===== ログ =====
            if isLogVisible {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ログ")
                        .font(.headline)

                    LogView(text: state.log)
                        .frame(minHeight: 160)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                        )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 620)
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

    // MARK: - 変換開始

    private func startConversion() {
        guard let url = state.inputFolderURL else { return }

        Task {
            do {
                state.isProcessing = true
                state.resetProgress()
                state.appendLog("=== 変換開始 ===")

                try await Converter.run(inputFolder: url, state: state)
            } catch {
                state.appendLog("⚠ エラー: \(error.localizedDescription)")
                state.isProcessing = false
            }
        }
    }
}

// MARK: - 進捗行（1工程ぶん）

struct ProgressRow: View {

    let title: String
    let progress: Double   // 0.0 ... 1.0

    private var statusText: String {
        if progress <= 0 {
            return "待機中"
        } else if progress < 1 {
            return "処理中"
        } else {
            return "完了"
        }
    }

    private var statusSymbol: String {
        if progress <= 0 {
            return "circle"
        } else if progress < 1 {
            return "arrow.triangle.2.circlepath.circle"
        } else {
            return "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {

            Image(systemName: statusSymbol)
                .foregroundColor(progress >= 1 ? .green : .accentColor)
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text(String(format: "%.0f%%", progress * 100))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - ログビュー（自動スクロール付き）

struct LogView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {

                    Text(text.isEmpty ? "（ログがまだありません）" : text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)

                    // 余白を大きめに（これが重要）
                    Color.clear
                        .frame(height: 30)
                        .id("LOG_BOTTOM")
                }
            }
            .onChange(of: text) { _, _ in
                // レイアウト確定後にスクロール
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("LOG_BOTTOM", anchor: .bottom)
                    }
                }
            }
        }
    }
}
