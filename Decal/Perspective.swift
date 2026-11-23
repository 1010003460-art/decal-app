import CoreImage
import CoreGraphics
import UIKit

/// RGBA8 像素缓冲，行优先，y 轴向下（和 CGImage 一致）
struct ImageBuffer {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.pixels = [UInt8](repeating: 0, count: width * height * 4)
    }

    init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        // 指针只在 withUnsafeMutableBytes 期间有效，context 必须在这个闭包内用完
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.width = w
        self.height = h
        self.pixels = buf
    }

    func cgImage() -> CGImage? {
        var buf = pixels
        return buf.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }

    /// 双线性采样，返回 RGBA（0...255）
    func sample(_ x: Double, _ y: Double, into out: inout [Double]) {
        let fx = min(max(x, 0), Double(width - 1))
        let fy = min(max(y, 0), Double(height - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let tx = fx - Double(x0), ty = fy - Double(y0)
        let w00 = (1 - tx) * (1 - ty), w10 = tx * (1 - ty)
        let w01 = (1 - tx) * ty, w11 = tx * ty
        let i00 = (y0 * width + x0) * 4, i10 = (y0 * width + x1) * 4
        let i01 = (y1 * width + x0) * 4, i11 = (y1 * width + x1) * 4
        for c in 0..<4 {
            out[c] = Double(pixels[i00 + c]) * w00 + Double(pixels[i10 + c]) * w10
                   + Double(pixels[i01 + c]) * w01 + Double(pixels[i11 + c]) * w11
        }
    }
}

enum Perspective {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 把原图按四个角展平成正视图。quad 用 CIImage 坐标（y 向上），顺序 TL, TR, BL, BR
    static func flatten(_ image: CIImage, quad: [CGPoint]) -> CGImage? {
        guard quad.count == 4, let f = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        f.setValue(image, forKey: kCIInputImageKey)
        f.setValue(CIVector(cgPoint: quad[0]), forKey: "inputTopLeft")
        f.setValue(CIVector(cgPoint: quad[1]), forKey: "inputTopRight")
        f.setValue(CIVector(cgPoint: quad[2]), forKey: "inputBottomLeft")
        f.setValue(CIVector(cgPoint: quad[3]), forKey: "inputBottomRight")
        guard let out = f.outputImage else { return nil }
        return ciContext.createCGImage(out, from: out.extent)
    }

    /// 把「已贴好贴纸的展平图」反向映射回原图坐标，返回与原图同尺寸的 RGBA 覆盖层
    /// quad 是展平图四角在原图上的像素坐标（y 向下），顺序 TL, TR, BL, BR
    static func overlay(flat: ImageBuffer, quad: [CGPoint], canvasW: Int, canvasH: Int) -> ImageBuffer? {
        let fw = CGFloat(flat.width), fh = CGFloat(flat.height)
        let flatCorners = [CGPoint(x: 0, y: 0), CGPoint(x: fw, y: 0),
                           CGPoint(x: 0, y: fh), CGPoint(x: fw, y: fh)]
        guard let h = Homography.solve(from: flatCorners, to: quad),
              let inv = h.inverted() else { return nil }

        // 只遍历四边形包围盒，外面必然透明
        let xs = quad.map { $0.x }, ys = quad.map { $0.y }
        let x0 = max(0, Int(xs.min()!.rounded(.down)) - 1)
        let x1 = min(canvasW - 1, Int(xs.max()!.rounded(.up)) + 1)
        let y0 = max(0, Int(ys.min()!.rounded(.down)) - 1)
        let y1 = min(canvasH - 1, Int(ys.max()!.rounded(.up)) + 1)
        guard x1 >= x0, y1 >= y0 else { return nil }

        var out = ImageBuffer(width: canvasW, height: canvasH)
        var rgba = [Double](repeating: 0, count: 4)
        for y in y0...y1 {
            for x in x0...x1 {
                guard let q = inv.map(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) else { continue }
                guard q.x >= -1, q.x <= fw + 1, q.y >= -1, q.y <= fh + 1 else { continue }
                flat.sample(Double(q.x), Double(q.y), into: &rgba)
                if rgba[3] < 1 { continue }
                let o = (y * canvasW + x) * 4
                out.pixels[o]     = UInt8(min(255, max(0, rgba[0])))
                out.pixels[o + 1] = UInt8(min(255, max(0, rgba[1])))
                out.pixels[o + 2] = UInt8(min(255, max(0, rgba[2])))
                out.pixels[o + 3] = UInt8(min(255, max(0, rgba[3])))
            }
        }
        return out
    }

    /// 把覆盖层叠到原图上（两者都是 premultiplied RGBA）
    static func composite(base: ImageBuffer, overlay: ImageBuffer) -> UIImage? {
        guard base.width == overlay.width, base.height == overlay.height else { return nil }
        var out = base
        for i in stride(from: 0, to: out.pixels.count, by: 4) {
            let a = Double(overlay.pixels[i + 3]) / 255
            guard a > 0.002 else { continue }
            for c in 0..<3 {
                let v = Double(overlay.pixels[i + c]) + Double(out.pixels[i + c]) * (1 - a)
                out.pixels[i + c] = UInt8(min(255, max(0, v)))
            }
            out.pixels[i + 3] = 255
        }
        guard let cg = out.cgImage() else { return nil }
        return UIImage(cgImage: cg)
    }
}
