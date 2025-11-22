//
//  Converter.swift
//  EPUB Studio
//

import Foundation
import AppKit
import ImageIO

// 対応する画像拡張子
private let validImageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "webp", "avif"
]

// ファイル名から見開き番号ペアを検出するための正規表現
// 例: 002_003.jpg, p0005-0006.png
private let spreadPairRegex =
    try! NSRegularExpression(pattern: #"(\d+)[-_](\d+)"#, options: [])

// 例: 001L.jpg, p0003R.png など
private let spreadLRRegex =
    try! NSRegularExpression(pattern: #"(\d+)\s*([LR])"#,
                              options: [.caseInsensitive])

/// 論理ページ（PageSide が付く前の段階）
enum LogicalItem {
    case spread(right: URL, left: URL) // すでに左右に分かれている
    case single(URL)                   // 単ページ
}

/// 画像フォルダ → EPUB 生成まで全部やる
struct Converter {

    /// メイン入口
    ///
    /// - フォルダ直下に画像がある場合 … 1冊だけ生成（今までと同じ）
    /// - 画像が無く、サブフォルダ内に画像がある場合 … そのサブフォルダごとに一括生成
    ///   EPUB の出力先は「選んだフォルダ直下」
    static func run(
        inputFolder: URL,
        state: AppState
    ) async throws {

        let fm = FileManager.default

        // まず、選んだフォルダ直下に画像があるかどうかを調べる
        let directImages = try collectImages(in: inputFolder, fm: fm)

        if !directImages.isEmpty {
            // ========= 単一フォルダモード =========
            await MainActor.run {
                state.isProcessing = true
                state.resetProgress()
                state.appendLog("=== EPUB 生成開始（単一フォルダ）===")
                state.appendLog("入力フォルダ: \(inputFolder.path)")
            }

            do {
                try await runOneVolume(
                    folder: inputFolder,
                    images: directImages,
                    outputRoot: inputFolder,      // 画像フォルダ内に出力
                    volumeIndex: nil,
                    totalVolumes: nil,
                    state: state,
                    overallBase: 0.0,
                    overallScale: 1.0
                )

                await MainActor.run {
                    state.updateProgress(1.0)
                    state.appendLog("✅ EPUB 生成完了")
                    state.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    state.appendLog("❌ エラー: \(error)")
                    state.isProcessing = false
                }
                throw error
            }

            return
        }

        // ========= 一括生成モード（親フォルダ） =========
        // サブフォルダのうち、画像を含むフォルダを探す
        let children = try fm.contentsOfDirectory(
            at: inputFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var volumes: [(folder: URL, images: [URL])] = []

        for url in children {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                let imgs = try collectImages(in: url, fm: fm)
                if !imgs.isEmpty {
                    volumes.append((url, imgs))
                }
            }
        }

        guard !volumes.isEmpty else {
            await MainActor.run {
                state.appendLog("⚠ 画像ファイルが見つかりませんでした。")
                state.appendLog("  （選んだフォルダにも、その直下のフォルダにも画像がありません）")
            }
            return
        }

        await MainActor.run {
            state.isProcessing = true
            state.resetProgress()
            state.appendLog("=== EPUB 一括生成開始（\(volumes.count) フォルダ）===")
            state.appendLog("親フォルダ: \(inputFolder.path)")
        }

        for (index, entry) in volumes.enumerated() {
            let base  = Double(index) / Double(volumes.count)
            let scale = 1.0 / Double(volumes.count)

            try await runOneVolume(
                folder: entry.folder,
                images: entry.images,
                outputRoot: inputFolder,           // ★ 親フォルダ直下に出力
                volumeIndex: index + 1,
                totalVolumes: volumes.count,
                state: state,
                overallBase: base,
                overallScale: scale
            )
        }

        await MainActor.run {
            state.updateProgress(1.0)
            state.appendLog("✅ すべての EPUB 生成完了（\(volumes.count) 冊）")
            state.isProcessing = false
        }
    }

    // MARK: - フォルダ内画像の取得（1階層のみ）

    private static func collectImages(
        in folder: URL,
        fm: FileManager
    ) throws -> [URL] {

        try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            validImageExtensions.contains(url.pathExtension.lowercased())
        }
        .sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
            == .orderedAscending
        }
    }

    // MARK: - 1冊分の実処理

    private static func runOneVolume(
        folder: URL,
        images: [URL],
        outputRoot: URL,
        volumeIndex: Int?,
        totalVolumes: Int?,
        state: AppState,
        overallBase: Double,
        overallScale: Double
    ) async throws {

        let fm = FileManager.default
        let files = images

        guard !files.isEmpty else {
            await MainActor.run {
                state.appendLog("⚠ \(folder.lastPathComponent): 画像がありません")
            }
            return
        }

        // ローカル → 全体進捗へのマッピング
        func updateProgress(_ local: Double) async {
            let clamped = max(0.0, min(1.0, local))
            let global  = overallBase + clamped * overallScale
            await MainActor.run {
                state.updateProgress(global)
            }
        }

        let title  = folder.lastPathComponent
        let author = "EPUB Studio"

        await MainActor.run {
            if let idx = volumeIndex, let total = totalVolumes {
                state.appendLog("")
                state.appendLog("=== [\(idx)/\(total)] \(title) ===")
            } else {
                state.appendLog("")
                state.appendLog("=== \(title) ===")
            }
            state.appendLog("画像枚数: \(files.count)")
        }

        // ================================
        // ① JPEG 化 & サイズ・spread情報収集（0.0〜0.25）
        // ================================
        var converted: [ConvertedImage] = []

        // 単ページ候補サイズの頻度（基準サイズ決定用）
        // key: "WxH", value: (count, size)
        var singleSizeCount: [String: (count: Int, size: CGSize)] = [:]

        // すべての JPEG を置く一時ディレクトリ
        let tempImagesRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_images_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempImagesRoot, withIntermediateDirectories: true)

        for (index, src) in files.enumerated() {

            let localProgress = Double(index) / Double(files.count) * 0.25
            await updateProgress(localProgress)

            await MainActor.run {
                state.appendLog("画像 \(index+1)/\(files.count): \(src.lastPathComponent)")
            }

            // JPEG へ変換
            let tmpName = String(format: "orig_%04d.jpg", index + 1)
            let tmpURL  = tempImagesRoot.appendingPathComponent(tmpName)

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
        } else if let first = converted.first?.pixelSize {
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

        // アップスケールが必要かどうか
        var needsUpScale = false
        for info in converted {
            if info.pixelSize.width < baseSize.width ||
                info.pixelSize.height < baseSize.height {
                needsUpScale = true
                break
            }
        }
        if needsUpScale {
            await MainActor.run {
                state.appendLog("※ 一部画像が基準サイズより小さいため、アップスケール対象があります")
            }
        }

        // ================================
        // ③ ConvertedImage → LogicalItem
        //    見開きは分割＋基準サイズにリサイズ（0.25〜0.60）
        // ================================
        var logicalItems: [LogicalItem] = []

        // 見開き分割・リサイズ後の JPEG 出力ディレクトリ
        let tempSpreadsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_spreads_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempSpreadsDir, withIntermediateDirectories: true)

        for (index, info) in converted.enumerated() {

            let localProgress = 0.25 + Double(index) / Double(converted.count) * 0.35
            await updateProgress(localProgress)

            await MainActor.run {
                state.appendLog("配置判定 \(index+1)/\(converted.count): \(info.fileName)")
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
                    in: tempSpreadsDir
                )
                logicalItems.append(.spread(right: r, left: l))

            } else if info.isWide {
                // 横長なので見開き
                await MainActor.run {
                    state.appendLog("  ↳ 見開き（横長）と判定")
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
                // 単ページ
                logicalItems.append(.single(info.jpegURL))
            }
        }

        // ================================
        // ④ 論理ページ → PageInfo 列へ（0.60〜0.70）
        // ================================
        let pages = makePageSequence(from: logicalItems) { message in
            Task { @MainActor in
                state.appendLog(message)
            }
        }

        await updateProgress(0.70)
        await MainActor.run {
            state.appendLog("最終ページ数（PageInfo）: \(pages.count)")
        }

        // ================================
        // ⑤ EPUB Builder 実行（0.70〜1.0）
        // ================================
        let outputURL = outputRoot.appendingPathComponent("\(title).epub")

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

        await updateProgress(1.0)
        await MainActor.run {
            state.appendLog("✅ EPUB Builder 完了: \(outputURL.lastPathComponent)")
        }
    }

    // MARK: - 画像サイズ・比率

    /// JPEGファイルからピクセルサイズを取得
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

    /// 横長かどうか（縦横比で判定）
    private static func isWideSize(_ size: CGSize) -> Bool {
        guard size.height > 0 else { return false }
        let ratio = size.width / size.height
        return ratio >= 1.2   // 適当な閾値
    }

    // MARK: - spread 判定

    /// ファイル名から「番号ペア見開き」を検出
    /// 戻り値: (小さい方の番号, 大きい方の番号)
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
            // 001L / 001R のようなものは「左右ペアの一部」だが、
            // ファイルが1枚だけだと判定しようがないのでここでは簡易に (n, n+1)
            return (n, n + 1)
        }

        return nil
    }

    // MARK: - 見開き分割（高画質版）

    /// 見開き画像を左右 2 枚に分割して保存
    /// - src: JPEG 画像（横長）
    /// - baseName: 保存ファイル名のベース
    /// - targetSize: 分割後の1ページの最終サイズ（例: 1440x2048）
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

        let leftRect = CGRect(
            x: 0,
            y: 0,
            width: halfWidth,
            height: fullHeight
        )

        let rightRect = CGRect(
            x: halfWidth,
            y: 0,
            width: halfWidth,
            height: fullHeight
        )

        guard
            let leftCG  = cgImage.cropping(to: leftRect),
            let rightCG = cgImage.cropping(to: rightRect)
        else {
            throw ImageConverterError.cannotCreateJPEG(src)
        }

        let targetW = Int(targetSize.width)
        let targetH = Int(targetSize.height)

        func resizeAndSave(_ cg: CGImage, suffix: String) throws -> URL {
            guard let resized = resizeCGImage(
                cgImage: cg,
                width: targetW,
                height: targetH
            ) else {
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

    /// CGImage を指定サイズに高品質リサイズ
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
            in: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(width),
                height: CGFloat(height)
            )
        )

        return ctx.makeImage()
    }

    // MARK: - PageInfo 列生成

    /// 論理ページ列 → PageInfo 列
    ///
    /// ルール：
    ///   - 先頭の single は「表紙」として単独の右ページ
    ///   - 2 枚目以降の single は、基本的に 2 枚で 1 見開き（右 + 左）
    ///   - spread はそのまま (right, left) として追加
    ///   - single が奇数枚だった場合、最後の 1 枚は右ページ単独
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
                // 途中で pendingSingle があれば先に処理
                if let wait = pendingSingle {
                    pages.append(PageInfo(imageFile: wait, side: .right))
                    pendingSingle = nil
                }
                pages.append(PageInfo(imageFile: r, side: .right))
                pages.append(PageInfo(imageFile: l, side: .left))
                firstSingleHandled = true

            case .single(let img):
                if !firstSingleHandled {
                    // 先頭 single = 表紙（右ページのみ）
                    log("表紙として単ページを配置: \(img.lastPathComponent)")
                    pages.append(PageInfo(imageFile: img, side: .right))
                    firstSingleHandled = true
                } else {
                    if let wait = pendingSingle {
                        // 2 枚そろったので見開き化
                        pages.append(PageInfo(imageFile: wait, side: .right))
                        pages.append(PageInfo(imageFile: img, side: .left))
                        pendingSingle = nil
                    } else {
                        pendingSingle = img
                    }
                }
            }
        }

        // single が奇数枚だった場合、最後の 1 枚を右ページとして追加
        if let wait = pendingSingle {
            pages.append(PageInfo(imageFile: wait, side: .right))
        }

        return pages
    }
}
