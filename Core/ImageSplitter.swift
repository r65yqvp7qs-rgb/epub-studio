// Core/ImageSplitter.swift

import Foundation
import AppKit

struct ImageSplitter {

    static func splitVertical(image: NSImage) -> (NSImage, NSImage)? {
        guard let cgImage = image.toCGImage() else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 1 else { return nil }

        let evenWidth = width - (width % 2)
        let half = evenWidth / 2

        let rightRect = CGRect(x: half, y: 0,
                               width: half, height: height)
        let leftRect  = CGRect(x: 0,    y: 0,
                               width: half, height: height)

        guard
            let rightCG = cgImage.cropping(to: rightRect),
            let leftCG  = cgImage.cropping(to: leftRect)
        else {
            return nil
        }

        let rightImage = NSImage(
            cgImage: rightCG,
            size: NSSize(width: rightCG.width, height: rightCG.height)
        )
        let leftImage  = NSImage(
            cgImage: leftCG,
            size: NSSize(width: leftCG.width, height: leftCG.height)
        )

        return (rightImage, leftImage)
    }
}
