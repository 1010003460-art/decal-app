import XCTest
import Metal
import CoreGraphics
@testable import Decal

// 这些断言必须在 iOS 上跑，不能只在 macOS 上跑：
// macOS 的 CGBitmapContext 支持的格式是 iOS 的超集，macOS 上能建成功的位图上下文，
// iOS 上可能直接返回 nil。而返回 nil 的后果不是报错，是照片整块不画、
// 屏幕上只剩 clearColor 的深蓝灰 —— 真机报的「照片变成蓝色」就是这个现象。
final class TextureIOSTests: XCTestCase {

    /// 平台到底支持哪些位图格式组合
    func testBitmapFormatSupport() {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bgra = TextureIO.makeContext(width: 8, height: 8, space: cs, info: TextureIO.nativeInfo())
        let rgba = TextureIO.makeContext(width: 8, height: 8, space: cs,
                                         info: CGImageAlphaInfo.premultipliedLast.rawValue
                                             | CGBitmapInfo.byteOrder32Big.rawValue)
        print("BGRA(premultipliedFirst|32Little) -> \(bgra != nil ? "支持" : "nil")")
        print("RGBA(premultipliedLast|32Big)       -> \(rgba != nil ? "支持" : "nil")")
        XCTAssertNotNil(bgra, "iOS 拒绝了 BGRA 位图上下文，纹理链路整条不能用了")
    }

    /// 通道顺序 + 行序：上半红、下半蓝的探针图，上传后直接读回纹理字节
    func testTextureChannelAndRowOrder() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "没有 Metal 设备")
        let w = 8, h = 8
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(TextureIO.makeContext(width: w, height: h, space: cs,
                                                      info: TextureIO.nativeInfo()))

        // CGContext 的 y 轴向上：y 大的那一半是图像顶部
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
        let cg = try XCTUnwrap(ctx.makeImage())

        let tex = try XCTUnwrap(TextureIO.bgra8(from: cg, device: device),
                                "纹理上传返回 nil → 照片会整块不画，屏幕上只剩 clearColor")
        XCTAssertEqual(tex.pixelFormat, .bgra8Unorm)

        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }

        // BGRA 字节序：B,G,R,A
        func px(_ row: Int) -> (b: Int, g: Int, r: Int, a: Int) {
            let o = row * w * 4 + 2 * 4
            return (Int(out[o]), Int(out[o + 1]), Int(out[o + 2]), Int(out[o + 3]))
        }
        let top = px(0)
        let bottom = px(h - 1)

        XCTAssertGreaterThan(top.r, 200, "row0 应是红（图像顶部），实际 r=\(top.r) b=\(top.b) g=\(top.g)")
        XCTAssertLessThan(top.b, 60, "row0 蓝通道不该高，实际 b=\(top.b)")
        XCTAssertGreaterThan(bottom.b, 200, "最后一行应是蓝（图像底部），实际 r=\(bottom.r) b=\(bottom.b)")
        XCTAssertLessThan(bottom.r, 60, "最后一行红通道不该高，实际 r=\(bottom.r)")
        XCTAssertEqual(top.a, 255, "不透明像素的 alpha 应为 255")
    }

    /// 预乘 alpha：50% 白，预乘后 r ≈ a ≈ 128；shader 里 dt.rgb /= dt.a 才能还原成白
    func testPremultipliedAlpha() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(TextureIO.makeContext(width: 4, height: 4, space: cs,
                                                      info: TextureIO.nativeInfo()))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let cg = try XCTUnwrap(ctx.makeImage())

        let tex = try XCTUnwrap(TextureIO.bgra8(from: cg, device: device))
        var out = [UInt8](repeating: 0, count: 4 * 4 * 4)
        out.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: 16,
                         from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        }
        let o = 5 * 4
        let r = Int(out[o + 2]), a = Int(out[o + 3])
        XCTAssertEqual(a, 128, accuracy: 4, "50% 白的 alpha 应为 128，实际 \(a)")
        XCTAssertEqual(r, a, accuracy: 6, "预乘后 r 应接近 a（r=\(r) a=\(a)）")
    }
}
