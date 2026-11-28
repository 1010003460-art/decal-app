// 用 Apple 官方的 Depth Anything V2 Small 在真实照片上跑一次，导出深度图。
// 只在 CI 的 macOS runner 上有意义（需要 Xcode + CoreML）；本地 Windows 跑不了。
//
// 用途：确认模型在真实素材上给出的深度是否可用，以及输出到底是「深度」还是「视差」。
// 数值范围决定要不要取倒数 —— 这一步猜错，后面的弧长扭曲会整个反向。

import Foundation
import CoreML
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let IW = 518, IH = 392          // 模型固定输入（宽 × 高），官方说图片会被拉伸到这个尺寸

func load(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func pixelBuffer(_ img: CGImage) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
    CVPixelBufferCreate(nil, IW, IH, kCVPixelFormatType_32BGRA, attrs, &pb)
    guard let buf = pb else { return nil }
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf),
                              width: IW, height: IH, bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: IW, height: IH))
    return buf
}

func writeGray(_ buf: [Float], w: Int, h: Int, path: String) {
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for i in 0..<(w * h) {
        let v = UInt8(max(0, min(255, buf[i] * 255)))
        px[i * 4 + 0] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
    }
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let cg = ctx.makeImage(),
          let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                    UTType.png.identifier as CFString, 1, nil)
    else { print("write failed \(path)"); return }
    CGImageDestinationAddImage(dst, cg, nil)
    CGImageDestinationFinalize(dst)
}

let pkg = URL(fileURLWithPath: "/tmp/model/DepthAnythingV2SmallF16.mlpackage")
let compiled = try MLModel.compileModel(at: pkg)
let cfg = MLModelConfiguration()
cfg.computeUnits = .cpuOnly
let model = try MLModel(contentsOf: compiled, configuration: cfg)

let root = ProcessInfo.processInfo.environment["DECAL_ROOT"] ?? "."
for name in ["bottle", "face", "building"] {
    guard let img = load("\(root)/test/\(name).png"),
          let pb = pixelBuffer(img) else { print("skip \(name)"); continue }
    let prov = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])
    let out = try model.prediction(from: prov)
    guard let ma = out.featureValue(for: "depth")?.multiArrayValue else {
        print("no depth output for \(name)"); continue
    }

    var vals = [Float](repeating: 0, count: ma.count)
    for i in 0..<ma.count { vals[i] = ma[i].floatValue }
    let sorted = vals.sorted()
    let mn = sorted.first!, mx = sorted.last!
    let p10 = sorted[ma.count / 10], p90 = sorted[ma.count * 9 / 10]
    print("\(name): shape=\(ma.shape) dtype=\(ma.dataType.rawValue) count=\(ma.count)")
    print("   min=\(mn) max=\(mx) p10=\(p10) p90=\(p90)")

    // 数值大 → 是「相对深度」（远处数值大）；取倒数变视差，近处亮
    let inverted = mx > 3.0
    var norm = vals
    if inverted { for i in 0..<norm.count { norm[i] = 1.0 / max(norm[i], 1e-6) } }
    let nmin = norm.min()!, nmax = norm.max()!
    for i in 0..<norm.count { norm[i] = (norm[i] - nmin) / max(nmax - nmin, 1e-6) }
    print("   inverted=\(inverted)")

    let w = ma.shape.last!.intValue
    let h = ma.shape[ma.shape.count - 2].intValue
    writeGray(norm, w: w, h: h, path: "/tmp/depth/\(name)_depth.png")
}
print("done")
