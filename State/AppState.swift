//  State/AppState.swift
//  EPUB Studio

import SwiftUI

/// アプリ全体の状態
@MainActor
final class AppState: ObservableObject {

    // MARK: - 入力フォルダ

    /// ユーザーが選択した画像フォルダ（親フォルダ or 単一巻フォルダ）
    @Published var inputFolder: URL?

    /// 「入力フォルダ」表示用文字列
    var inputFolderDisplayPath: String {
        guard let url = inputFolder else { return "未選択" }
        return url.path
    }

    // MARK: - 作者・出版社

    /// 作者名（ダイアログで入力）
    @Published var author: String = ""

    /// 出版社名（ダイアログで入力）
    @Published var publisher: String = ""

    // MARK: - 処理状態

    /// 処理中フラグ（EPUB 生成中は true）
    @Published var isProcessing: Bool = false

    // MARK: - 冊ごとの進捗（ステップ別）

    /// 画像準備（JPEG 変換・情報収集）の進捗（0.0〜1.0）
    @Published var step1Progress: Double = 0.0

    /// ページ構築（見開き判定・レイアウト）の進捗（0.0〜1.0）
    @Published var step2Progress: Double = 0.0

    /// EPUB 構築（パッケージング）の進捗（0.0〜1.0）
    @Published var step3Progress: Double = 0.0

    // MARK: - 全体進捗（全巻）

    /// 全体進捗（全巻トータルで 0.0〜1.0）
    @Published var totalProgress: Double = 0.0

    // MARK: - 一括生成時の巻数情報

    /// 今処理している巻（1 始まり）
    @Published var currentVolumeIndex: Int = 0

    /// 全巻数（一括生成時のみ有効）
    @Published var currentVolumeTotal: Int = 0

    /// 現在処理中の巻タイトル（フォルダ名）
    @Published var currentVolumeTitle: String = ""

    // MARK: - ログ

    /// ログ全文（Text でまとめて表示）
    @Published var logText: String = ""

    /// ログ表示 ON/OFF
    @Published var isLogVisible: Bool = true

    // MARK: - 進捗操作ヘルパ

    /// 1 冊分の 3 ステップ進捗を 0 にリセット
    func resetPerVolumeProgress() {
        step1Progress = 0.0
        step2Progress = 0.0
        step3Progress = 0.0
    }

    /// 全体進捗 + 1 冊分の進捗をまとめて 0 にリセット
    func resetAllProgress() {
        resetPerVolumeProgress()
        totalProgress = 0.0
    }

    func setStep1Progress(_ value: Double) {
        step1Progress = max(0.0, min(1.0, value))
    }

    func setStep2Progress(_ value: Double) {
        step2Progress = max(0.0, min(1.0, value))
    }

    func setStep3Progress(_ value: Double) {
        step3Progress = max(0.0, min(1.0, value))
    }

    func setTotalProgress(_ value: Double) {
        totalProgress = max(0.0, min(1.0, value))
    }

    // MARK: - ログ

    /// ログに 1 行追加
    func appendLog(_ line: String) {
        if !logText.isEmpty {
            logText.append("\n")
        }
        logText.append(line)
    }
}
