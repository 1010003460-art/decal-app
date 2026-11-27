import CoreGraphics
import Foundation
import Metal

// ============================================================================
// CGImage → Metal 纹理（RGBA8 + 预乘 alpha）
//
// 为什么不用 MTKTextureLoader：它按 CGImage 的 bitmapInfo 自己去推断像素格式，
// 推断不准的时候不报错、只是颜色不对。真机上出现过「照片整体发蓝、贴图发虚像透明的」，
// 而同一份代码在 Web 参考实现里是对的 —— 差异就落在这一层格式推断上。
// 这里用 CGBitmapContext 显式画成 R,G,B,A 字节序，格式只有一种答案。
//
// 行序：CGBitmapContext 的 buffer 第 0 行就是图像顶部，与 Metal 纹理 v=0（左上）一致，
// 不需要翻转。test/TextureCheck.swift 对这条做了断言。
// ============================================================================

enum TextureIO {

    static func rgba8(from cg: CGImage, device: MTLDevice) -> MTLTexture? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        // premultipliedLast + byteOrder32Big = 内存顺序 R,G,B,A，与 shader 的 .rgb/.a 一一对应
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
                 | CGBitmapInfo.byteOrder32Big.rawValue

        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                         width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        buf.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                      withBytes: raw.baseAddress!, bytesPerRow: w * 4)
        }
        return t
    }
}
