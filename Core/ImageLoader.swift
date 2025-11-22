import Foundation
import AppKit

struct ImageLoader {
    
    // 画像読み込み（AVIF / PNG / JPG / HEIC 対応）
    static func loadImage(url: URL, log: (String) -> Void) -> NSImage? {
        
        // 1. iCloud ファイルの場合、未ダウンロードならダウンロード
        if isICloudFile(url: url) {
            log("iCloud ファイル検出：\(url.lastPathComponent)")
            if !downloadFromICloud(url: url, log: log) {
                log("❌ iCloud ダウンロード失敗：\(url.lastPathComponent)")
                return nil
            }
        }
        
        // 2. NSImage で読み込み（macOS 13+ は AVIF もネイティブ対応）
        guard let image = NSImage(contentsOf: url) else {
            log("❌ 画像読み込み失敗：\(url.lastPathComponent)")
            return nil
        }
        
        log("✓ 画像読み込み成功：\(url.lastPathComponent)")
        return image
    }
    
    
    // ------------------------------------------------------------
    // MARK: - iCloud 関連処理
    // ------------------------------------------------------------
    
    private static func isICloudFile(url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey])
        return values?.isUbiquitousItem ?? false
    }
    
    private static func downloadFromICloud(url: URL, log: (String) -> Void) -> Bool {
        let fm = FileManager.default
        
        log("iCloud → ローカルへダウンロード開始…")
        
        // ダウンロード要求
        do {
            try fm.startDownloadingUbiquitousItem(at: url)
        } catch {
            log("❌ iCloud ダウンロード開始に失敗: \(error.localizedDescription)")
            return false
        }
        
        // 最大30秒間、ローカルダウンロード完了を待つ
        let timeout = Date().addingTimeInterval(30)
        while Date() < timeout {
            if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               values.ubiquitousItemDownloadingStatus == .current {
                
                log("✓ iCloud ダウンロード完了")
                return true
            }
            
            // 0.2秒待つ（CPU負荷を避ける）
            Thread.sleep(forTimeInterval: 0.2)
        }
        
        log("⚠️ iCloud ダウンロードがタイムアウトしました")
        return false
    }
}
