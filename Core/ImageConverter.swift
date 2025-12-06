//
//  Core/ImageConverter.swift
//  EPUB Studio
//

import Foundation
import CoreGraphics
import ImageIO
import AppKit

struct ImageConverter {

    /// PNG / WebP / HEIF / BMP など → JPEG 変換
    static func convertToJPEG(src: URL, dst: URL) throws {

        guard let srcImage = NSImage(contentsOf: src) else {
            throw NSError(domain: "ImageLoad", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "画像を読み込めません: \(src.lastPathComponent)"])
        }

        guard let tiff = srcImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            throw NSError(domain: "Bitmap", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "画像をビットマップ化できません"])
        }

        guard let jpegData = bitmap.representation(using: .jpeg,
                                                   properties: [.compressionFactor: 0.92]) else {
            throw NSError(domain: "JPEG", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "JPEG生成に失敗"])
        }

        try jpegData.write(to: dst, options: .atomic)
    }
}
