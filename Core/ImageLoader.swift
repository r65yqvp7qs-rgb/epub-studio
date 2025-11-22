//
//  ImageLoader.swift
//  EPUB Studio
//

import Foundation
import AppKit

struct ImageLoader {

    /// ファイルから NSImage を読み込む
    static func load(from url: URL) -> NSImage? {
        guard let img = NSImage(contentsOf: url) else {
            return nil
        }
        return img
    }
}
