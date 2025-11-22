// Core/Converter.swift
//
// EPUB Studio - 画像フォルダ → EPUB3 固定レイアウト
// Swift 6 concurrency 対応版

import Foundation
import AppKit
import ImageIO

// 対象とする画像拡張子
private let validImageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "webp", "avif"
]

// ファイル名ペア i-002_003.jpg など
private let spreadPairRegex =
    try! NSRegularExpression(pattern: #"(\d+)[-_](\d+)"#, options: [])

// 001L.jpg / 001R.png など
private let spreadLRRegex =
    try! NSRegularExpression(pattern: #"(\d+)\s*([LR])"#,
                             options: [.caseInsensitive])

/// 論理ページ（PageSide が確定する前）
private enum LogicalItem {
    case spread(right: URL, left: URL) // 見開きの左右
    case single(URL)                   // 単ページ
}

/// JPEG 変換後の1枚ぶん情報
private struct ConvertedImage {
    let originalURL: URL        // 元ファイル
    let jpegURL: URL            // 一時 JPEG
    let pixelSize: CGSize       // ピクセルサイズ
    let fileName: String        // 元ファイル名
    let spreadPair: (Int, Int)? // ファイル名から判定したペア番号
    let isWide: Bool            // 横長（見開き候補）
}

/// 画像フォルダ → EPUB 生成まで全部やる
struct Converter {

    /// メイン処理
    static func run(inputFolder: URL, state: AppState) async throws {

        let fm = FileManager.default

        await MainActor.run {
            state.isProcessing = true
            state.resetProgress()
            state.appendLog("=== EPUB 生成開始 ===")
        }

        // 出力先のベース（タイトル）
        let title  = inputFolder.lastPathComponent
        let author = "EPUB Studio"

        // 一時 JPEG 保存ディレクトリ（元画像 → JPEG）
        let tempSrcDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_src_\(UUID().uuidString)")
        try? fm.removeItem(at: tempSrcDir)
        try fm.createDirectory(at: tempSrcDir, withIntermediateDirectories: true)

        // 画像ファイル一覧
        let files = try fm.contentsOfDirectory(
            at: inputFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            validImageExtensions.contains(url.pathExtension.lowercased())
        }
        .sorted { a, b in
            a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }

        guard !files.isEmpty else {
            await MainActor.run {
                state.appendLog("⚠ 画像ファイルが見つかりませんでした。")
                state.isProcessing = false
            }
            return
        }

        await MainActor.run {
            state.appendLog("画像枚数: \(files.count)")
        }

        // ================================
        // ① JPEG 化 & サイズ・spread情報収集
        // ================================
        var converted: [ConvertedImage] = []

        // 単ページ候補サイズの頻度（基準サイズ決定用）
        // key: "WxH", value: (count, size)
        var singleSizeCount: [String: (count: Int, size: CGSize)] = [:]

        for (index, src) in files.enumerated() {

            let progress = Double(index) / Double(files.count) * 0.25
            await MainActor.run {
                state.updateProgress(progress)
                state.appendLog("画像 \(index + 1)/\(files.count): \(src.lastPathComponent)")
            }

            // JPEG へ変換
            let tmpName = "orig_\(String(format: "%04d", index + 1)).jpg"
            let tmpURL = tempSrcDir.appendingPathComponent(tmpName)

            try ImageConverter.convertToJPEG(src: src, dst: tmpURL)

            // ピクセルサイズ
            let size = try imagePixelSize(for: tmpURL)

            // spread 判定
            let pair = detectSpreadPair(from: src.lastPathComponent)
            let wide = isWideSize(size)

            let info = ConvertedImage(
                originalURL: src,
                jpegURL: tmpURL,
                pixelSize: size,
                fileName: src.lastPathComponent,
                spreadPair: pair,
                isWide: wide
            )
            converted.append(info)

            // 単ページ候補サイズをカウント
            if pair == nil && !wide {
                let key = "\(Int(size.width))x\(Int(size.height))"
                let current = singleSizeCount[key] ?? (0, size)
                singleSizeCount[key] = (current.count + 1, size)
            }
        }

        // 以降では不変の配列として扱う（Swift 6 の並行アクセスエラー回避）
        let convertedImages = converted

        // ================================
        // ② 基準単ページサイズを決定
        //    （フォルダ内で一番多いサイズ）
        // ================================
        let baseSize: CGSize

        if let best = singleSizeCount.values.max(by: { $0.count < $1.count }) {
            baseSize = best.size
            await MainActor.run {
                state.appendLog("基準単ページサイズ（最頻）: \(Int(baseSize.width))x\(Int(baseSize.height))")
            }
        } else if let first = convertedImages.first?.pixelSize {
            baseSize = first
            await MainActor.run {
                state.appendLog("単ページ候補がないため、先頭画像サイズを基準に: \(Int(baseSize.width))x\(Int(baseSize.height))")
            }
        } else {
            // ほぼ来ない想定
            baseSize = CGSize(width: 1440, height: 2048)
            await MainActor.run {
                state.appendLog("⚠ 基準サイズ決定に失敗。デフォルト 1440x2048 を使用")
            }
        }

        // アップスケールが必要か？（基準サイズより小さい画像があるか）
        var needsUpScale = false
        for info in convertedImages {
            if info.pixelSize.width < baseSize.width ||
               info.pixelSize.height < baseSize.height {
                needsUpScale = true
                break
            }
        }

        // ================================
        // ③ ConvertedImage → LogicalItem
        //    見開きは分割＋基準サイズにリサイズ
        // ================================
        var logicalItems: [LogicalItem] = []

        // 分割後 JPEG を置く一時ディレクトリ
        let tempImagesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_images_\(UUID().uuidString)")
        try? fm.removeItem(at: tempImagesDir)
        try fm.createDirectory(at: tempImagesDir, withIntermediateDirectories: true)

        let totalConverted = convertedImages.count

        for (index, info) in convertedImages.enumerated() {

            let progress = 0.25 + Double(index) / Double(totalConverted) * 0.35
            await MainActor.run {
                state.updateProgress(progress)
                state.appendLog("配置判定 \(index + 1)/\(totalConverted): \(info.fileName)")
            }

            if let pair = info.spreadPair {
                // ファイル名ペアでの見開き
                await MainActor.run {
                    state.appendLog("  ↳ 見開き（番号ペア）検出: \(pair.0)-\(pair.1)")
                }
                let baseName = "spread_\(pair.0)_\(pair.1)"
                let (r, l) = try splitSpreadImage(
                    src: info.jpegURL,
                    baseName: baseName,
                    targetSize: baseSize,
                    in: tempImagesDir
                )
                logicalItems.append(.spread(right: r, left: l))

            } else if info.isWide {
                // 横長なので見開き
                await MainActor.run {
                    state.appendLog("  ↳ 見開き（横長）と判定")
                }
                let baseName = "spread_\(index + 1)"
                let (r, l) = try splitSpreadImage(
                    src: info.jpegURL,
                    baseName: baseName,
                    targetSize: baseSize,
                    in: tempImagesDir
                )
                logicalItems.append(.spread(right: r, left: l))

            } else {
                // 単ページ
                logicalItems.append(.single(info.jpegURL))
            }
        }

        // ================================
        // ④ 論理ページ → PageInfo 列へ
        // ================================
        let pages = makePageSequence(from: logicalItems) { message in
            Task { @MainActor in
                state.appendLog(message)
            }
        }

        await MainActor.run {
            state.appendLog("最終ページ数（PageInfo）: \(pages.count)")
            state.updateProgress(0.7)
        }

        // ================================
        // ⑤ EPUB Builder 実行
        // ================================

        // アップスケール付きならファイル名を拡張
        let baseDir = inputFolder.deletingLastPathComponent()
        let epubNameBase: String = {
            if needsUpScale {
                return "\(title)_UpScale(\(Int(baseSize.width))x\(Int(baseSize.height)))"
            } else {
                return title
            }
        }()

        let outputURL = baseDir.appendingPathComponent("\(epubNameBase).epub")

        await MainActor.run {
            state.appendLog("EPUB 出力先: \(outputURL.path)")
        }

        let builder = EPUBBuilder(
            title: title,
            author: author,
            outputURL: outputURL,
            pages: pages,
            pageSize: baseSize,
            log: { message in
                Task { @MainActor in
                    state.appendLog(message)
                }
            }
        )

        try builder.build()

        await MainActor.run {
            state.updateProgress(1.0)
            state.appendLog("✅ EPUB 生成完了: \(outputURL.path)")
            state.isProcessing = false
        }
    }

    // MARK: - 画像サイズ・比率

    private static func imagePixelSize(for url: URL) throws -> CGSize {
        guard
            let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int,
            let h = props[kCGImagePropertyPixelHeight] as? Int
        else {
            throw ImageConverterError.cannotLoadImage(url)
        }
        return CGSize(width: w, height: h)
    }

    private static func isWideSize(_ size: CGSize) -> Bool {
        guard size.height > 0 else { return false }
        let ratio = size.width / size.height
        return ratio >= 1.2
    }

    // MARK: - spread 判定

    private static func detectSpreadPair(from fileName: String) -> (Int, Int)? {
        let fullRange = NSRange(location: 0, length: fileName.utf16.count)

        if let m = spreadPairRegex.firstMatch(in: fileName, options: [], range: fullRange),
           m.numberOfRanges >= 3,
           let r1 = Range(m.range(at: 1), in: fileName),
           let r2 = Range(m.range(at: 2), in: fileName),
           let n1 = Int(fileName[r1]),
           let n2 = Int(fileName[r2]),
           n1 != n2 {
            return (min(n1, n2), max(n1, n2))
        }

        if let m = spreadLRRegex.firstMatch(in: fileName, options: [], range: fullRange),
           m.numberOfRanges >= 3,
           let r = Range(m.range(at: 1), in: fileName),
           let n = Int(fileName[r]) {
            // 001L / 001R → ざっくり (n, n+1) として扱う
            return (n, n + 1)
        }

        return nil
    }

    // MARK: - 見開き分割（高画質）

    private static func splitSpreadImage(
        src: URL,
        baseName: String,
        targetSize: CGSize,
        in dir: URL
    ) throws -> (URL, URL) {

        guard let nsImage = NSImage(contentsOf: src),
              var cgImage = nsImage.toCGImage() else {
            throw ImageConverterError.cannotLoadImage(src)
        }

        let srcWidth  = cgImage.width
        let srcHeight = cgImage.height

        guard srcWidth > 1 else {
            throw ImageConverterError.cannotCreateJPEG(src)
        }

        // 幅が奇数なら 1px 落として偶数に（中央線バグ対策）
        let evenWidth = srcWidth - (srcWidth % 2)
        if evenWidth != srcWidth {
            let cropRect = CGRect(x: 0, y: 0, width: evenWidth, height: srcHeight)
            if let cropped = cgImage.cropping(to: cropRect) {
                cgImage = cropped
            }
        }

        let halfWidth  = cgImage.width / 2
        let fullHeight = cgImage.height

        let leftRect = CGRect(x: 0,
                              y: 0,
                              width: halfWidth,
                              height: fullHeight)

        let rightRect = CGRect(x: halfWidth,
                               y: 0,
                               width: halfWidth,
                               height: fullHeight)

        guard
            let leftCG  = cgImage.cropping(to: leftRect),
            let rightCG = cgImage.cropping(to: rightRect)
        else {
            throw ImageConverterError.cannotCreateJPEG(src)
        }

        let targetW = Int(targetSize.width)
        let targetH = Int(targetSize.height)

        func resizeAndSave(_ cg: CGImage, suffix: String) throws -> URL {
            guard let resized = resizeCGImage(cgImage: cg,
                                              width: targetW,
                                              height: targetH) else {
                throw ImageConverterError.cannotCreateJPEG(src)
            }

            let rep = NSBitmapImageRep(cgImage: resized)
            guard let jpegData = rep.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.9]
            ) else {
                throw ImageConverterError.cannotCreateJPEG(src)
            }

            let name = "\(baseName)_\(suffix).jpg"
            let dst  = dir.appendingPathComponent(name)
            try jpegData.write(to: dst, options: .atomic)
            return dst
        }

        // 右ページ → page-spread-right
        let rightURL = try resizeAndSave(rightCG, suffix: "R")
        // 左ページ → page-spread-left
        let leftURL  = try resizeAndSave(leftCG,  suffix: "L")

        return (rightURL, leftURL)
    }

    private static func resizeCGImage(
        cgImage: CGImage,
        width: Int,
        height: Int
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        ctx.interpolationQuality = .high
        ctx.draw(
            cgImage,
            in: CGRect(x: 0, y: 0,
                       width: CGFloat(width),
                       height: CGFloat(height))
        )

        return ctx.makeImage()
    }

    // MARK: - PageInfo 列生成

    private static func makePageSequence(
        from logical: [LogicalItem],
        log: (String) -> Void
    ) -> [PageInfo] {

        var pages: [PageInfo] = []
        var firstSingleHandled = false
        var pendingSingle: URL?

        for item in logical {
            switch item {
            case .spread(let r, let l):
                if let wait = pendingSingle {
                    pages.append(PageInfo(imageFile: wait, side: .right))
                    pendingSingle = nil
                }
                pages.append(PageInfo(imageFile: r, side: .right))
                pages.append(PageInfo(imageFile: l, side: .left))
                firstSingleHandled = true

            case .single(let img):
                if !firstSingleHandled {
                    log("表紙として単ページを配置: \(img.lastPathComponent)")
                    pages.append(PageInfo(imageFile: img, side: .right))
                    firstSingleHandled = true
                } else {
                    if let wait = pendingSingle {
                        pages.append(PageInfo(imageFile: wait, side: .right))
                        pages.append(PageInfo(imageFile: img, side: .left))
                        pendingSingle = nil
                    } else {
                        pendingSingle = img
                    }
                }
            }
        }

        if let wait = pendingSingle {
            pages.append(PageInfo(imageFile: wait, side: .right))
        }

        return pages
    }
}

// NSImage → CGImage 変換（このプロジェクト内では 1 箇所だけ定義する）
extension NSImage {
    func toCGImage() -> CGImage? {
        var rect = NSRect(origin: .zero, size: self.size)
        return self.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
