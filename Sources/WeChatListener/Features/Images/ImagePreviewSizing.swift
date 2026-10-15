import AppKit
import ImageIO
import SwiftUI

enum ImagePreviewSizing {
    static func size(width: Int, height: Int, displayScale: CGFloat, available: CGSize, fit: Bool, zoom: CGFloat)
        -> CGSize
    {
        let scale = max(1, displayScale)
        let w = CGFloat(width) / scale
        let h = CGFloat(height) / scale
        guard w > 0, h > 0 else { return .zero }
        let factor = fit ? min(1, max(1, available.width) / w, max(1, available.height) / h) : min(4, max(0.25, zoom))
        return CGSize(width: w * factor, height: h * factor)
    }
}
