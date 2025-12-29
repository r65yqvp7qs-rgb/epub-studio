//  Views/ContentView.swift
//  EPUB Studio
//

import SwiftUI
import AppKit   // セキュリティスコープ用

struct ContentView: View {

    @StateObject private var state = AppState()

    @State private var showingFolderPicker = false
    @State private var showingAuthorDialog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // MARK: - タイトル
            Text("EPUB Studio")
                .font(.title)
                .bold()
                .padding(.top, 12)

            // MARK: - 入力フォルダ
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

            Text("※ フォルダをこのウィンドウにドラッグ＆ドロップして選択することもできます")
                .font(.caption)
                .foregroundColor(.secondary)

            // MARK: - 進捗バー（3本＋全体）
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

            // MARK: - 今処理中の巻
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

            // MARK: - EPUB 生成開始ボタン
            HStack {
                Spacer()
                Button(state.isProcessing ? "処理中…" : "EPUB 生成開始") {
                    // まず作者・出版社入力ダイアログを出す
                    showingAuthorDialog = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.inputFolder == nil || state.isProcessing)
                Spacer()
            }
            .padding(.top, 4)

            // ContentView 内のどこか（ログの上あたり）に追加するイメージ
            VStack(alignment: .leading, spacing: 8) {
                Text("全体の進捗")
                    .font(.title3.bold())

                ProgressView(value: state.totalProgress)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(y: 2.0, anchor: .center)           // ← 他より明らかに太く
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .animation(.easeInOut(duration: 0.2), value: state.totalProgress)

                Text(String(format: "%3.0f%% 完了", state.totalProgress * 100))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)

            // MARK: - ログ見出し
            HStack {
                Text("ログ")
                    .bold()
                Spacer()
                Button(state.isLogVisible ? "ログを隠す" : "ログを表示") {
                    state.isLogVisible.toggle()
                }
                .buttonStyle(.plain)
            }

            // MARK: - ログビュー
            if state.isLogVisible {
                LogView(text: state.logText)
                    .frame(minHeight: 200)
            }

            Spacer(minLength: 8)
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
        // フォルダ選択（ファイル選択パネル）
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
        // フォルダのドラッグ＆ドロップ対応
        .onDrop(of: ["public.file-url"], isTargeted: nil, perform: handleDrop)
        // 作者・出版社入力ダイアログ
        .sheet(isPresented: $showingAuthorDialog) {
            AuthorInfoDialog(
                author: $state.author,
                publisher: $state.publisher,
                onCancel: {
                    showingAuthorDialog = false
                },
                onDone: {
                    showingAuthorDialog = false
                    startConvert()
                }
            )
        }
    }

    // MARK: - EPUB 生成開始処理

    private func startConvert() {
        guard let folder = state.inputFolder else { return }

        Task {
            // セキュリティスコープ付き URL へのアクセス開始
            let granted = folder.startAccessingSecurityScopedResource()
            defer {
                if granted { folder.stopAccessingSecurityScopedResource() }
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

    // MARK: - ドラッグ＆ドロップ処理

    /// Finder からフォルダをドロップしたときに入力フォルダとしてセットする
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let item = providers.first else { return false }

        item.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
            var url: URL?

            if let d = data as? Data {
                url = URL(dataRepresentation: d, relativeTo: nil)
            } else {
                url = data as? URL
            }

            guard let droppedURL = url else { return }

            // ディレクトリかどうか確認
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: droppedURL.path, isDirectory: &isDir),
                  isDir.boolValue else {
                return
            }

            // UI 更新はメインアクターで
            Task { @MainActor in
                state.inputFolder = droppedURL
                state.currentVolumeIndex = 0
                state.currentVolumeTotal = 0
                state.currentVolumeTitle = ""
                state.resetAllProgress()
                state.logText = ""
                state.appendLog("ドラッグ＆ドロップでフォルダ選択: \(droppedURL.path)")
            }
        }

        return true
    }
}

// MARK: - 進捗バー 1本

struct ProgressRow: View {
    let title: String
    let progress: Double

    var body: some View {
        HStack(spacing: 12) {                         // ← 間隔を明示的に小さく
            Text(title)
                .font(.headline)                      // ← 項目名を大きめに
                .frame(width: 140, alignment: .leading)

            ProgressView(value: progress)
                .frame(maxWidth: .infinity)           // ← 画面幅いっぱい使う
                .scaleEffect(y: 1.3, anchor: .center) // ← 細すぎない程度に太く
                .animation(.easeInOut(duration: 0.2), value: progress)

            Text(String(format: "%3.0f%%", progress * 100))
                .font(.subheadline.monospacedDigit()) // ← 数字は等幅で読みやすく
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}
