import AppKit

extension NSImage {
    /// NSImage → CGImage 変換
    func toCGImage() -> CGImage? {
        var rect = CGRect(origin: .zero, size: self.size)
        return self.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
