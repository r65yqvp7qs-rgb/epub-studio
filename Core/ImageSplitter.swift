//
//  ImageSplitter.swift
//  EPUB Studio
//

import Foundation
import CoreGraphics
import ImageIO
import AppKit

struct ImageSplitter {

    /// 見開き画像を左右へ分割して、それぞれ JPEG で書き出す
    static func split(
        src: URL,
        rightOut: URL,
        leftOut: URL,
        targetSize: CGSize
    ) throws {

        guard let nsImage = NSImage(contentsOf: src),
              var cgImage = nsImage.toCGImage() else {
            throw NSError(domain: "Split", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "画像を読み込めません: \(src.lastPathComponent)"])
        }

        let w = cgImage.width
        let h = cgImage.height

        guard w > 1 else {
            throw NSError(domain: "Split", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "画像幅が不足"])
        }

        // ─────────────────────────────────────────────
        // 幅が奇数 → 1px落として Apple Books の中央線バグ対策
        // ─────────────────────────────────────────────
        let evenW = w - (w % 2)
        if evenW != w {
            let cropRect = CGRect(x: 0, y: 0, width: evenW, height: h)
            if let cropped = cgImage.cropping(to: cropRect) {
                cgImage = cropped
            }
        }

        let half = cgImage.width / 2

        // 左
        let leftRect = CGRect(x: 0, y: 0, width: half, height: h)
        guard let leftCG = cgImage.cropping(to: leftRect) else {
            throw NSError(domain: "Split", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "左ページの切り出し失敗"])
        }

        // 右
        let rightRect = CGRect(x: half, y: 0, width: half, height: h)
        guard let rightCG = cgImage.cropping(to: rightRect) else {
            throw NSError(domain: "Split", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "右ページの切り出し失敗"])
        }

        // ─────────────────────────────────────────────
        // 高品質リサイズして JPEG 化
        // ─────────────────────────────────────────────
        let targetW = Int(targetSize.width)
        let targetH = Int(targetSize.height)

        func resizeAndSave(_ srcCG: CGImage, to url: URL) throws {
            guard let resized = resizeCGImage(srcCG, width: targetW, height: targetH) else {
                throw NSError(domain: "Split", code: -5,
                              userInfo: [NSLocalizedDescriptionKey: "リサイズ失敗"])
            }

            let rep = NSBitmapImageRep(cgImage: resized)
            guard let jpeg = rep.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.92]
            ) else {
                throw NSError(domain: "Split", code: -6,
                              userInfo: [NSLocalizedDescriptionKey: "JPEG出力失敗"])
            }

            try jpeg.write(to: url, options: .atomic)
        }

        try resizeAndSave(rightCG, to: rightOut)
        try resizeAndSave(leftCG, to: leftOut)
    }

    // MARK: - 高品質リサイズ
    private static func resizeCGImage(
        _ cgImage: CGImage,
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
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(
            cgImage,
            in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        )

        return ctx.makeImage()
    }
}


// MARK: - NSImage → CGImage 変換
extension NSImage {
    func toCGImage() -> CGImage? {
        var rect = CGRect(origin: .zero, size: self.size)
        return self.cgImage(
            forProposedRect: &rect,
            context: nil,
            hints: nil
        )
    }
}
