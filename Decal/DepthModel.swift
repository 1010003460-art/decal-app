import CoreGraphics
import CoreML
import CoreVideo
import Foundation

// ============================================================================
// Depth Anything V2 Small（Apple 官方 CoreML 包）的薄封装。
//
// 模型契约来自 CI 探针实测（`.github/workflows/probe-depth.yml` + `test/run_depth.swift`）：
//   · 输入 `image`，固定 518×392（宽×高）
//   · 输出 `depth` 是 **image 类型**，不是 MLMultiArray —— 一开始按数组去取，
//     结果拿到 nil，白跑了两轮 CI。518×392，值域 0~1，1 = 近
//   · 是**相对深度**（up-to-scale），不是米制。所以只能用来算梯度/曲率，
//     不能直接当位移量：绝对尺度要靠用户标的四角平面拟合掉
//
// 这个文件只依赖 CoreML + CoreGraphics + CoreVideo + Foundation，
// 不碰 UIKit —— 这样 CI 里能用 swiftc 直接编进去做 boot check，
// 不用起模拟器就能验证「模型能加载、能推理、输出形状对」。
// ============================================================================

final class DepthModel {

    /// 模型固定输入尺寸。换模型必须改这里，并且重新跑 boot check。
    static let inputW = 518
    static let inputH = 392

    /// 打包进 bundle 的目录名（CI 用 coremlcompiler 从 mlpackage 编译成 mlmodelc）
    static let resourceName = "DepthAnythingV2SmallF16"

    struct Depth {
        /// 行主序，第 0 行是图像顶部（和 CGBitmapContext 一致，别再翻）
        let values: [Float]
        let width: Int
        let height: Int

        func at(x: Int, y: Int) -> Float {
            let cx = min(max(x, 0), width - 1)
            let cy = min(max(y, 0), height - 1)
            return values[cy * width + cx]
        }
    }

    static let shared = DepthModel(url: DepthModel.bundleURL())

    private let model: MLModel?
    private let inputName: String
    private let outputName: String

    /// 唯一的 designated init。url 为 nil 或加载失败都得到「空模型」，
    /// 上层只看 `isAvailable`，不写满 optional 判断。
    private init(url: URL?) {
        guard let url, let m = DepthModel.load(url) else {
            model = nil; inputName = ""; outputName = ""
            return
        }
        model = m
        inputName = DepthModel.pickInput(m)
        outputName = DepthModel.pickOutput(m)
    }

    /// 命令行 / 测试用：从指定 .mlmodelc 加载，加载不到就返回 nil
    convenience init?(compiledURL url: URL) {
        self.init(url: url)
        if model == nil { return nil }
    }

    var isAvailable: Bool { model != nil }

    // ---------------------------------------------------------------- 推理

    /// 一张照片 → 深度图。任何一步失败都返回 nil，上层退化成「没有深度」，
    /// 不能让 App 崩、也不能静默给一张全零的图（那会让弧长扭曲变成一条直线）。
    func infer(_ cg: CGImage) -> Depth? {
        guard let model, let pb = DepthModel.pixelBuffer(from: cg) else { return nil }
        // MLDictionaryFeatureProvider 的构造器本身是 throwing（会校验 feature 名）
        guard let input = try? MLDictionaryFeatureProvider(
                dictionary: [inputName: MLFeatureValue(pixelBuffer: pb)]),
              let out = try? model.prediction(from: input) else { return nil }

        // 输出名字理论上就是 "depth"，但如果换包了，退化成「第一个能读成灰度的输出」
        if let fv = out.featureValue(for: outputName), let d = DepthModel.depth(from: fv) { return d }
        for name in out.featureNames {
            if let fv = out.featureValue(for: name), let d = DepthModel.depth(from: fv) { return d }
        }
        return nil
    }

    // ---------------------------------------------------------------- 内部

    private static func bundleURL() -> URL? {
        if let u = Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc") { return u }
        // 被放进子目录时的兜底（XcodeGen 的 folder 引用通常是摊平到 bundle 根）
        return Bundle.main.url(forResource: resourceName, withExtension: "mlmodelc",
                               subdirectory: "Model")
    }

    private static func load(_ url: URL) -> MLModel? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all      // 真机走 ANE；模拟器/老设备 CoreML 自动降级
        return try? MLModel(contentsOf: url, configuration: cfg)
    }

    private static func pickInput(_ m: MLModel) -> String {
        m.modelDescription.inputDescriptionsByName.keys.sorted().first ?? "image"
    }

    private static func pickOutput(_ m: MLModel) -> String {
        m.modelDescription.outputDescriptionsByName.keys.sorted().first ?? "depth"
    }

    /// CGImage → 518×392 BGRA pixel buffer。
    ///
    /// 这里是**直接拉伸**，不做 letterbox。理由：深度只用来算梯度，
    /// 横向缩放对每一行都是同一个常数，弧长积分只取横向 dz/dx，
    /// 常数倍只等比例影响「扭曲强度」，不影响形状。letterbox 的黑边反而会
    /// 在边界造出巨大的假梯度，那才真的会坏。
    private static func pixelBuffer(from cg: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            // 没有 IOSurface 时 CoreML 可能走慢路径
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any]() as CFDictionary,
        ]
        guard CVPixelBufferCreate(nil, inputW, inputH, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }

        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf),
                                  width: inputW, height: inputH, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: inputW, height: inputH))
        return buf
    }

    /// 输出可能是 32Float / 16Half / 32BGRA / 8 位单通道，四种都要认。
    /// 不在这里做 min/max 归一化：那张图的价值是**绝对**的远近关系，
    /// 归一化会把「几乎全平」的照片放大成假曲率。可视化时才拉伸。
    private static func depth(from fv: MLFeatureValue) -> Depth? {
        if let ma = fv.multiArrayValue {
            var vals = [Float](repeating: 0, count: ma.count)
            for i in 0..<ma.count { vals[i] = ma[i].floatValue }
            let w = ma.shape.last?.intValue ?? 0
            let h = ma.shape.count >= 2 ? ma.shape[ma.shape.count - 2].intValue : 1
            guard w > 0, h > 0, w * h == ma.count else { return nil }
            return Depth(values: vals, width: w, height: h)
        }

        guard let pb = fv.imageBufferValue else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(pb) else { return nil }

        let fmt = CVPixelBufferGetPixelFormatType(pb)
        var vals = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr)
            switch fmt {
            case kCVPixelFormatType_OneComponent32Float:
                let p = row.bindMemory(to: Float.self, capacity: w)
                for x in 0..<w { vals[y * w + x] = p[x] }
            case kCVPixelFormatType_OneComponent16Half:
                let p = row.bindMemory(to: UInt16.self, capacity: w)
                for x in 0..<w { vals[y * w + x] = Float(Float16(bitPattern: p[x])) }
            case kCVPixelFormatType_OneComponent8:
                let p = row.bindMemory(to: UInt8.self, capacity: w)
                for x in 0..<w { vals[y * w + x] = Float(p[x]) / 255.0 }
            default:
                // 32BGRA / 32ARGB：三通道相同，取第一通道
                let p = row.bindMemory(to: UInt8.self, capacity: w * 4)
                for x in 0..<w { vals[y * w + x] = Float(p[x * 4]) / 255.0 }
            }
        }
        return Depth(values: vals, width: w, height: h)
    }
}
