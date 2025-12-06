//
//  Views/LogView.swift
//  EPUB Studio
//

import SwiftUI

/// ログ表示ビュー（ContentView から分離した独立コンポーネント）
struct LogView: View {

    /// 表示するログテキスト全体
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {

                // テキスト本体 + 下端スクロール用ダミーノード
                VStack(alignment: .leading, spacing: 4) {

                    Text(text.isEmpty ? "（ログはまだありません）" : text)
                        .font(.system(size: 12, design: .monospaced))   // ★ 少し大きめ
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // ▼ 自動スクロールのための不可視アンカー
                    Color.clear
                        .frame(height: 1)
                        .id("LOG_BOTTOM")
                }
                .padding(6)
            }
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 1)
            )

            // -----------------------------------------------------
            // 新しいログが追加される度に自動で最下部へスクロール
            // -----------------------------------------------------
            .onChange(of: text) { _, _ in
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("LOG_BOTTOM", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
