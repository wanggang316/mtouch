import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure image operations for `screenshot`: PNG encoding and the all-black
/// backstop. Both are total over any `CGImage` and free of AX/SCK/TCC, so they
/// are unit-testable with hand-built images.
public enum ScreenCaptureImage {
    /// Encodes `image` as PNG bytes — ALWAYS PNG, independent of any output
    /// filename/extension the caller chose (`--out shot.jpg` still gets PNG
    /// bytes). Nil only when the ImageIO destination cannot be created/finalized.
    public static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Whether `image` is effectively all-black/empty — the signature of a failed
    /// capture (a denied or empty SCK frame) rather than real content.
    ///
    /// The image is downsampled into a small RGB grid and declared blank only
    /// when EVERY sampled cell is exactly zero in all colour channels. Averaging
    /// means any real content — a menu bar, a caret, text, wallpaper — leaves at
    /// least one non-zero cell, so a legitimately dark (even dark-mode) capture
    /// is never rejected; only a wholly black/transparent frame trips it.
    public static func isEffectivelyBlank(_ image: CGImage, gridSize: Int = 16) -> Bool {
        let side = max(1, gridSize)
        let bytesPerPixel = 4
        let bytesPerRow = side * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: side, height: side,
                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            // Cannot decide ⇒ do not wrongly reject a real capture.
            return false
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var index = 0
        while index < pixels.count {
            if pixels[index] != 0 || pixels[index + 1] != 0 || pixels[index + 2] != 0 {
                return false
            }
            index += bytesPerPixel
        }
        return true
    }
}
