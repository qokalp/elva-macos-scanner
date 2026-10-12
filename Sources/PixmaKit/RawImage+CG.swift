import Foundation
import CoreGraphics

extension PixmaRawImage {
    /// Creates a CGImage backed by the (memory-mapped) raw file.
    public func makeCGImage() throws -> CGImage {
        let data = try Data(contentsOf: fileURL, options: .alwaysMapped)
        guard data.count >= bytesPerRow * height,
              let provider = CGDataProvider(data: data as CFData) else {
            throw PixmaError.protocolError("Incomplete image data")
        }
        let space = channels == 3 ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceGray()
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 8 * channels, bytesPerRow: bytesPerRow,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else {
            throw PixmaError.protocolError("Cannot create image")
        }
        return image
    }

    public func removeFile() { try? FileManager.default.removeItem(at: fileURL) }
}
