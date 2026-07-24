//
//  UIImage+Attachment.swift
//  MobiCureVN
//

import UIKit

extension UIImage {
    /// Encodes an attached image for the chat pipeline, downscaling so the longest side is
    /// at most `maxDimension`. A raw camera photo is 12MP+ (~4–10 MB of JPEG); persisting
    /// that per message bloats SwiftData and risks memory pressure alongside the loaded LLM,
    /// while the vision model resizes to ~512px anyway — nothing above ~1024px is ever used.
    ///
    /// Always redraws into a `UIGraphicsImageRenderer` (even when no downscaling is needed)
    /// rather than ever calling `jpegData(compressionQuality:)` on `self` directly.
    /// `jpegData` does not bake `imageOrientation` into the encoded pixel buffer — it only
    /// writes an EXIF tag — so a bare call ships the raw, un-rotated sensor buffer to any
    /// consumer that decodes bitmaps without honoring EXIF (e.g. MLX-VLM's image
    /// preprocessing). See Docs/FE/imageOrientationBug.md.
    func attachmentJPEGData(maxDimension: CGFloat = 1024, quality: CGFloat = 0.8) -> Data? {
        let longestSide = max(size.width, size.height) * scale
        let targetLongestSide = min(longestSide, maxDimension)
        let ratio = targetLongestSide / longestSide
        let targetSize = CGSize(width: size.width * scale * ratio, height: size.height * scale * ratio)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return normalized.jpegData(compressionQuality: quality)
    }
}
