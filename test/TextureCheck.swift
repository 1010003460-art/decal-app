// 验证 CGImage → Metal 纹理这一步的通道顺序与行序：
//   swiftc -O Decal/TextureIO.swift test/TextureCheck.swift -o /tmp/tcheck && /tmp/tcheck
//
// 真机上报过「照片发蓝、贴图发虚」，最可能就是这一层把 BGR/A 位序搞错了。
// 这里造一张「上半纯红、下半纯蓝」的探针图，上传后直接读回纹理字节断言：
//   row 0 必须是红   → 行序没错（row 0 = 图像顶部）
//   R 通道必须是 255 → 通道没错（没有 R/B 互换）
// macOS 与 iOS 走同一套 Metal，这条断言在 CI 上就有意义。

import CoreGraphics
import Foundation
import Metal

@main
struct TextureCheck {
    static var fail = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS  " : "FAIL  ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        if !ok { fail += 1 }
    }

    /// 上半纯红、下半纯蓝、全不透明。注意 CGContext 的 y 轴向上，y 大的那一半是图像顶部。
    static func makeProbe(_ w: Int, _ h: Int) -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h / 2, width: w, height: h / 2))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
        return ctx.makeImage()
    }

    static func main() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("FAIL  没有可用的 Metal 设备"); exit(1)
        }

        let w = 8, h = 8
        guard let probe = makeProbe(w, h) else {
            print("FAIL  探针图造不出来"); exit(1)
        }
        guard let tex = TextureIO.rgba8(from: probe, device: device) else {
            print("FAIL  TextureIO.rgba8 返回 nil"); exit(1)
        }

        var out = [UInt8](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }

        // 取每行第 3 个像素，避开边缘插值影响
        func px(_ row: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let o = row * w * 4 + 2 * 4
            return (Int(out[o]), Int(out[o + 1]), Int(out[o + 2]), Int(out[o + 3]))
        }

        let top = px(0)
        let bottom = px(h - 1)

        check("行序 row0 = 顶部（红）", top.r > 200 && top.b < 60, "rgb=\(top.r),\(top.g),\(top.b)")
        check("通道没有 R/B 互换", top.r > 200 && top.b < 60, "r=\(top.r) b=\(top.b)")
        check("行序 lastRow = 底部（蓝）", bottom.b > 200 && bottom.r < 60,
              "rgb=\(bottom.r),\(bottom.g),\(bottom.b)")
        check("alpha 不透明 = 255", top.a == 255, "a=\(top.a)")

        // 半透明白：验证预乘没有被写坏（预乘后 rgb≈a）
        if let half = CGContext(data: nil, width: 4, height: 4,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue) {
            half.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.5))
            half.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            if let cg = half.makeImage(), let t2 = TextureIO.rgba8(from: cg, device: device) {
                var b2 = [UInt8](repeating: 0, count: 4 * 4 * 4)
                b2.withUnsafeMutableBytes { raw in
                    t2.getBytes(raw.baseAddress!, bytesPerRow: 16,
                                from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
                }
                let o = 5 * 4
                let a = Int(b2[o + 3]), r = Int(b2[o])
                check("50% 白是预乘的（r≈a≈128）",
                      abs(a - 128) <= 4 && abs(r - a) <= 6, "r=\(r) a=\(a)")
            }
        }

        print(fail == 0 ? "\n全部通过" : "\n\(fail) 项失败")
        exit(fail == 0 ? 0 : 1)
    }
}
