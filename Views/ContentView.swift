//
//  ContentView.swift
//  EPUB Studio
//

import SwiftUI
import AppKit   // startAccessingSecurityScopedResource 用

/// アプリのメイン画面（EPUB Studio UI）
struct ContentView: View {

    /// アプリ全体の状態管理（進捗・ログ・フォルダ選択など）
    @StateObject private var state = AppState()

    /// フォルダ選択ダイアログの表示フラグ
    @State private var showingFolderPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ---------------------------------------------------------
            // タイトル
            // ---------------------------------------------------------
            Text("EPUB Studio")
                .font(.title)
                .bold()
                .padding(.top, 12)

            // ---------------------------------------------------------
            // 入力フォルダ表示 + 「フォルダ選択」ボタン
            // ---------------------------------------------------------
            HStack {
                Text("入力フォルダ")
                    .bold()

                Text(state.inputFolderDisplayPath)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("フォルダ選択") {
                    showingFolderPicker = true
                }
                .disabled(state.isProcessing)
            }

            // ---------------------------------------------------------
            // 進捗バー（冊ごとの 3 本 + 全体進捗 1 本）
            // ---------------------------------------------------------
            VStack(alignment: .leading, spacing: 8) {

                ProgressRow(
                    title: "画像準備（JPEG変換・情報収集）",
                    progress: state.step1Progress
                )

                ProgressRow(
                    title: "ページ構築（見開き判定・レイアウト）",
                    progress: state.step2Progress
                )

                ProgressRow(
                    title: "EPUB構築（パッケージング）",
                    progress: state.step3Progress
                )

                // ---- 全体進捗バー（4 本目）----
                let totalLabel: String = {
                    if state.currentVolumeTotal > 0 {
                        return "全体進捗（\(state.currentVolumeTotal) 冊）"
                    } else {
                        return "全体進捗"
                    }
                }()

                ProgressRow(
                    title: totalLabel,
                    progress: state.totalProgress
                )
            }

            // ---------------------------------------------------------
            // 一括生成：現在の巻数表示（バーの近く・右側）
            // ---------------------------------------------------------
            HStack {
                Spacer()
                if state.currentVolumeTotal > 1 {
                    Text("進行中：\(state.currentVolumeIndex)/\(state.currentVolumeTotal) 冊目  \(state.currentVolumeTitle)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else if state.currentVolumeTotal == 1 {
                    Text("進行中：1 冊  \(state.currentVolumeTitle)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            // ---------------------------------------------------------
            // EPUB 生成開始ボタン
            // ---------------------------------------------------------
            HStack {
                Spacer()
                Button(state.isProcessing ? "処理中…" : "EPUB 生成開始") {
                    startConvert()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.inputFolder == nil || state.isProcessing)
                Spacer()
            }
            .padding(.top, 4)

            // ---------------------------------------------------------
            // ログ見出し + 表示/非表示切り替えボタン
            // ---------------------------------------------------------
            HStack {
                Text("ログ")
                    .bold()
                Spacer()
                Button(state.isLogVisible ? "ログを隠す" : "ログを表示") {
                    state.isLogVisible.toggle()
                }
                .buttonStyle(.plain)
            }

            // ---------------------------------------------------------
            // ログビュー（LogView.swift を使用）
            // ---------------------------------------------------------
            if state.isLogVisible {
                LogView(text: state.logText)
                    .frame(minHeight: 200)
            }

            Spacer(minLength: 8)
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let folder = urls.first {
                    Task { @MainActor in
                        state.inputFolder = folder
                        state.currentVolumeIndex = 0
                        state.currentVolumeTotal = 0
                        state.currentVolumeTitle = ""
                        state.resetAllProgress()
                        state.logText = ""
                    }
                }

            case .failure(let error):
                print("フォルダ選択エラー: \(error)")
            }
        }
    }

    // MARK: - EPUB 生成開始処理

    private func startConvert() {
        guard let folder = state.inputFolder else { return }

        Task {
            // ★ セキュリティスコープ付き URL へのアクセス開始
            let granted = folder.startAccessingSecurityScopedResource()
            defer {
                // ★ 必ず対応する stop を呼ぶ
                if granted {
                    folder.stopAccessingSecurityScopedResource()
                }
            }

            do {
                try await Converter.run(inputFolder: folder, state: state)
            } catch {
                await MainActor.run {
                    state.appendLog("❌ エラー発生: \(error.localizedDescription)")
                    state.isProcessing = false
                }
            }
        }
    }
}

// MARK: - サブビュー（進捗バー 1 本）

private struct ProgressRow: View {
    let title: String
    let progress: Double  // 0〜1

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.subheadline)
            Spacer()
            ProgressView(value: progress)
                .frame(maxWidth: 350)
            Text(String(format: "%3.0f%%", progress * 100))
                .frame(width: 40, alignment: .trailing)
                .font(.footnote)
        }
    }
}
