import CoreGraphics
import Foundation
import Metal

// ============================================================================
// CGImage → Metal 纹理
//
// 为什么不用 MTKTextureLoader：它按 CGImage 的 bitmapInfo 自己去推断像素格式，
// 推断不准的时候不报错、只是颜色不对。真机上出现过「照片整体发蓝、贴图发虚像透明的」，
// 而同一份代码在 Web 参考实现里是对的 —— 差异就落在这一层格式推断上。
//
// 为什么是 BGRA 而不是 RGBA：CGBitmapContext 在 iOS 上原生就是 BGRA
// （premultipliedFirst + byteOrder32Little）。写 premultipliedLast + byteOrder32Big（RGBA）
// 时 CGContext 可能直接返回 nil，于是纹理变 nil、整块照片不画，屏幕上只剩 clearColor 的
// 深蓝灰 —— 这正好就是「照片变成蓝色」那个现象。
//
// 行序：CGBitmapContext 的 buffer 第 0 行就是图像顶部，与 Metal 纹理 v=0（左上）一致，
// 不需要翻转。DecalTests/TextureIOSTests.swift 在 iOS 模拟器上对这两条都做了断言。
// ============================================================================

enum TextureIO {

    static func bgra8(from cg: CGImage, device: MTLDevice) -> MTLTexture? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let info = CGImageAlphaInfo.premultipliedFirst.rawValue
                 | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = makeContext(width: w, height: h, space: cs, info: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let buf = ctx.data else { return nil }

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                         width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                  withBytes: buf, bytesPerRow: w * 4)
        return t
    }

    /// 自己分配内存的 CGBitmapContext（data: nil 交给 CoreGraphics 管）
    static func makeContext(width: Int, height: Int,
                            space: CGColorSpace, info: UInt32) -> CGContext? {
        CGContext(data: nil, width: width, height: height,
                  bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: info)
    }

    /// iOS 上可用的位图格式组合（单元测试用它判断平台支持面）
    static func nativeInfo() -> UInt32 {
        CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    }
}
