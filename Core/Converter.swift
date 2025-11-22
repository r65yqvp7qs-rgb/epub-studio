// Core/Converter.swift

import Foundation
import AppKit
import ImageIO

// 対応画像拡張子
private let validImageExtensions: Set<String> =
    ["jpg", "jpeg", "png", "webp", "avif"]

// 例: 002-003.jpg, 002_003.png
private let spreadPairRegex =
    try! NSRegularExpression(pattern: #"(\d+)[-_](\d+)"#, options: [])

// 例: 001L.jpg, 001R.jpg
private let spreadLRRegex =
    try! NSRegularExpression(pattern: #"(\d+)\s*([LR])"#, options: [.caseInsensitive])

/// 見開き or 単ページ（PageInfo 生成前の段階）
private enum LogicalItem {
    case spread(right: URL, left: URL)
    case single(URL)
}

/// Converter：画像 → 見開き判断 → PageInfo → EPUB
struct Converter {

    // ===============================================================
    // MARK: - メイン処理
    // ===============================================================
    static func run(
        inputFolder: URL,
        state: AppState
    ) async throws {

        let fm = FileManager.default

        await MainActor.run {
            state.isProcessing = true
            state.resetProgress()
            state.appendLog("=== EPUB 生成開始 ===")
            state.appendLog("入力フォルダ: \(inputFolder.path)")
        }

        // 本のタイトル
        let title = inputFolder.lastPathComponent
        let author = "EPUB Studio"

        // ---------------------------
        // 画像ファイル一覧を取得
        // ---------------------------
        let files = try fm.contentsOfDirectory(
            at: inputFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { validImageExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { a, b in
            a.lastPathComponent.localizedStandardCompare(b.lastPathComponent)
                == .orderedAscending
        }

        guard !files.isEmpty else {
            await MainActor.run {
                state.appendLog("⚠ 画像ファイルが見つかりません")
                state.isProcessing = false
            }
            return
        }

        await MainActor.run {
            state.appendLog("画像枚数: \(files.count)")
        }

        // ===============================================================
        // MARK: ① JPEG 化 ＆ 情報収集（0〜0.25）
        // ===============================================================
        var converted: [ConvertedImage] = []

        var singleSizeCount: [String: (count: Int, size: CGSize)] = [:]

        let tempImagesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_images_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempImagesRoot, withIntermediateDirectories: true)

        for (index, src) in files.enumerated() {

            let progress = Double(index) / Double(files.count) * 0.25
            await MainActor.run {
                state.updateProgress(progress)
                state.appendLog("画像 \(index+1)/\(files.count): \(src.lastPathComponent)")
            }

            // JPEG 化
            let tmpName = String(format: "orig_%04d.jpg", index + 1)
            let tmpURL = tempImagesRoot.appendingPathComponent(tmpName)
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

            if pair == nil && !wide {
                let key = "\(Int(size.width))x\(Int(size.height))"
                let current = singleSizeCount[key] ?? (0, size)
                singleSizeCount[key] = (current.count + 1, size)
            }
        }

        // ===============================================================
        // MARK: ② 基準単ページサイズ（最頻値）を決定
        // ===============================================================
        let baseSize: CGSize

        if let best = singleSizeCount.values.max(by: { $0.count < $1.count }) {
            baseSize = best.size
            await MainActor.run {
                state.appendLog("基準サイズ（最頻）: \(Int(baseSize.width))x\(Int(baseSize.height))")
            }
        } else if let first = converted.first?.pixelSize {
            baseSize = first
            await MainActor.run {
                state.appendLog("単ページ候補がないため先頭画像を基準に: \(baseSize)")
            }
        } else {
            baseSize = CGSize(width: 1440, height: 2048)
            await MainActor.run {
                state.appendLog("⚠ 基準サイズ決定失敗 → 1440x2048 を使用")
            }
        }

        // ===============================================================
        // MARK: ③ 見開き判定 → 分割 → LogicalItem 化（0.25〜0.60）
        // ===============================================================
        var logicalItems: [LogicalItem] = []

        let tempSpreadsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_spreads_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempSpreadsDir, withIntermediateDirectories: true)

        for (index, info) in converted.enumerated() {

            let progress = 0.25 + Double(index) / Double(converted.count) * 0.35
            await MainActor.run {
                state.updateProgress(progress)
                state.appendLog("配置判定 \(index+1)/\(converted.count): \(info.fileName)")
            }

            if let pair = info.spreadPair {
                await MainActor.run {
                    state.appendLog("↳ 見開き（番号ペア）: \(pair.0)-\(pair.1)")
                }
                let baseName = "spread_\(pair.0)_\(pair.1)"
                let (r, l) = try splitSpreadImage(
                    src: info.jpegURL,
                    baseName: baseName,
                    targetSize: baseSize,
                    in: tempSpreadsDir
                )
                logicalItems.append(.spread(right: r, left: l))

            } else if info.isWide {
                await MainActor.run {
                    state.appendLog("↳ 見開き（横長）")
                }
                let baseName = "spread_\(index+1)"
                let (r, l) = try splitSpreadImage(
                    src: info.jpegURL,
                    baseName: baseName,
                    targetSize: baseSize,
                    in: tempSpreadsDir
                )
                logicalItems.append(.spread(right: r, left: l))

            } else {
                logicalItems.append(.single(info.jpegURL))
            }
        }

        // ===============================================================
        // MARK: ④ LogicalItem → PageInfo（0.60〜0.70）
        // ===============================================================
        let pages = makePageSequence(from: logicalItems) { message in
            Task { @MainActor in
                state.appendLog(message)
            }
        }

        await MainActor.run {
            state.appendLog("最終ページ数: \(pages.count)")
            state.updateProgress(0.7)
        }

        // ===============================================================
        // MARK: ⑤ EPUB Builder 実行（0.70〜1.0）
        // ===============================================================
        // ★★ Sandbox 対策：EPUB は inputFolder の中に作る
        let outputURL = inputFolder.appendingPathComponent("\(title).epub")

        await MainActor.run {
            state.appendLog("EPUB 出力先: \(outputURL.path)")
        }

        let builder = EPUBBuilder(
            title: title,
            author: author,
            outputURL: outputURL,
            pages: pages,
            pageSize: baseSize,
            log: { msg in Task { @MainActor in state.appendLog(msg) } }
        )

        try builder.build()

        await MainActor.run {
            state.updateProgress(1.0)
            state.appendLog("✅ EPUB 生成完了: \(outputURL.lastPathComponent)")
            state.isProcessing = false
        }
    }

    // ===============================================================
    // MARK: - 画像メタ情報
    // ===============================================================
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

    private static func isWideSize(_ s: CGSize) -> Bool {
        guard s.height > 0 else { return false }
        return (s.width / s.height) >= 1.2
    }

    // ===============================================================
    // MARK: - spread 判定（ファイル名から）
    // ===============================================================
    private static func detectSpreadPair(from fileName: String) -> (Int, Int)? {
        let range = NSRange(location: 0, length: fileName.utf16.count)

        if let m = spreadPairRegex.firstMatch(in: fileName, options: [], range: range),
           m.numberOfRanges >= 3,
           let r1 = Range(m.range(at: 1), in: fileName),
           let r2 = Range(m.range(at: 2), in: fileName),
           let n1 = Int(fileName[r1]),
           let n2 = Int(fileName[r2]),
           n1 != n2 {
            return (min(n1, n2), max(n1, n2))
        }

        if let m = spreadLRRegex.firstMatch(in: fileName, options: [], range: range),
           m.numberOfRanges >= 3,
           let r = Range(m.range(at: 1), in: fileName),
           let n = Int(fileName[r]) {
            return (n, n+1)
        }

        return nil
    }

    // ===============================================================
    // MARK: - 見開き画像分割（高品質）
    // ===============================================================
    private static func splitSpreadImage(
        src: URL,
        baseName: String,
        targetSize: CGSize,
        in dir: URL
    ) throws -> (URL, URL) {

        guard let nsImg = NSImage(contentsOf: src),
              var cgImage = nsImg.toCGImage()
        else {
            throw ImageConverterError.cannotLoadImage(src)
        }

        let w = cgImage.width
        let h = cgImage.height
        guard w > 1 else { throw ImageConverterError.cannotCreateJPEG(src) }

        // 幅が奇数 → 偶数へ補正
        let evenW = w - (w % 2)
        if evenW != w {
            let rect = CGRect(x: 0, y: 0, width: evenW, height: h)
            if let cropped = cgImage.cropping(to: rect) {
                cgImage = cropped
            }
        }

        let half = cgImage.width / 2
        let fullH = cgImage.height

        let leftRect  = CGRect(x: 0,      y: 0, width: half, height: fullH)
        let rightRect = CGRect(x: half,   y: 0, width: half, height: fullH)

        guard
            let leftCG  = cgImage.cropping(to: leftRect),
            let rightCG = cgImage.cropping(to: rightRect)
        else {
            throw ImageConverterError.cannotCreateJPEG(src)
        }

        let targetW = Int(targetSize.width)
        let targetH = Int(targetSize.height)

        func resizeAndSave(_ cg: CGImage, suffix: String) throws -> URL {
            guard let resized = resizeCGImage(cgImage: cg, width: targetW, height: targetH)
            else { throw ImageConverterError.cannotCreateJPEG(src) }

            let rep = NSBitmapImageRep(cgImage: resized)
            guard let data = rep.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.9]
            ) else {
                throw ImageConverterError.cannotCreateJPEG(src)
            }

            let name = "\(baseName)_\(suffix).jpg"
            let dst = dir.appendingPathComponent(name)
            try data.write(to: dst, options: .atomic)
            return dst
        }

        let rURL = try resizeAndSave(rightCG, suffix: "R")
        let lURL = try resizeAndSave(leftCG,  suffix: "L")
        return (rURL, lURL)
    }

    // ===============================================================
    // MARK: - CGImageリサイズ
    // ===============================================================
    private static func resizeCGImage(
        cgImage: CGImage,
        width: Int,
        height: Int
    ) -> CGImage? {

        guard width > 0 && height > 0 else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: info
        ) else {
            return nil
        }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0,
                                    width: CGFloat(width),
                                    height: CGFloat(height)))
        return ctx.makeImage()
    }

    // ===============================================================
    // MARK: - PageInfo 列作成
    // ===============================================================
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
                    log("表紙: \(img.lastPathComponent)")
                    pages.append(PageInfo(imageFile: img, side: .right))
                    firstSingleHandled = true
                } else {
                    if let wait = pendingSingle {
                        pages.append(PageInfo(imageFile: wait, side: .right))
                        pages.append(PageInfo(imageFile: img,  side: .left))
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
