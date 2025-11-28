
//  Views/AuthorInfoDialog.swift
//  EPUB Studio

import SwiftUI

struct AuthorInfoDialog: View {

    @Binding var author: String
    @Binding var publisher: String

    var onCancel: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("作者 / 出版社情報")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("作者（省略可）")
                    .font(.subheadline)
                TextField("例：山田 太郎", text: $author)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("出版社（省略可）")
                    .font(.subheadline)
                TextField("例：〇〇出版社", text: $publisher)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("キャンセル") {
                    onCancel()
                }
                Button("OK") {
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
