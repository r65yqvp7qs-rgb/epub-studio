// Core/ImageConverter.swift

import Foundation
import AppKit

enum ImageConverterError: Error {
    case cannotLoadImage(URL)
    case cannotCreateJPEG(URL)
}

struct ImageConverter {

    static func convertToJPEG(
        src: URL,
        dst: URL,
        quality: CGFloat = 0.9
    ) throws -> URL {

        guard let image = NSImage(contentsOf: src) else {
            throw ImageConverterError.cannotLoadImage(src)
        }

        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let jpegData = rep.representation(
                using: .jpeg,
                properties: [.compressionFactor: quality]
              ) else {
            throw ImageConverterError.cannotCreateJPEG(src)
        }

        try jpegData.write(to: dst, options: .atomic)
        return dst
    }
}
