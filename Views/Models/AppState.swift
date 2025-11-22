// Views/Models/AppState.swift

import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    // ===== 状態 =====
    @Published var log: String = ""
    @Published var progress: Double = 0          // 0.0 ... 1.0
    @Published var isProcessing: Bool = false
    @Published var inputFolderURL: URL?

    // ===== ログ操作 =====
    func appendLog(_ text: String) {
        log += text + "\n"
    }

    func updateProgress(_ value: Double) {
        // 0〜1 にクランプ
        progress = max(0, min(1, value))
    }

    func resetProgress() {
        progress = 0
    }

    // ===== 工程別の進捗（プランB：3工程） =====
    //
    // Converter.swift の進捗割り当てをもとに計算:
    //   0.00〜0.25 : 画像準備（JPEG化・情報収集）
    //   0.25〜0.70: ページ構築（見開き判定・レイアウト）
    //   0.70〜1.00: EPUB構築（パッケージング）

    /// 画像準備（JPEG変換・情報収集）
    var phase1Progress: Double {
        let local = progress / 0.25
        return max(0, min(1, local))
    }

    /// ページ構築（見開き判定・レイアウト）
    var phase2Progress: Double {
        guard progress > 0.25 else { return 0 }
        let local = (progress - 0.25) / (0.70 - 0.25)
        return max(0, min(1, local))
    }

    /// EPUB構築（パッケージング）
    var phase3Progress: Double {
        guard progress > 0.70 else { return 0 }
        let local = (progress - 0.70) / (1.0 - 0.70)
        return max(0, min(1, local))
    }
}
