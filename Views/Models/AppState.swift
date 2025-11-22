// Models/AppState.swift

import SwiftUI

@MainActor
final class AppState: ObservableObject {

    @Published var log: String = ""
    @Published var progress: Double = 0
    @Published var isProcessing: Bool = false

    // 入力フォルダ（ContentView ですでに使っているならそのまま）
    @Published var inputFolderURL: URL?

    func appendLog(_ text: String) {
        log += text + "\n"
    }

    func updateProgress(_ value: Double) {
        progress = value
    }

    func resetProgress() {
        progress = 0
    }

    func setProcessing(_ value: Bool) {
        isProcessing = value
    }
}
