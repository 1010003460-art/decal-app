import CoreVideo
import ImageIO
import Metal
import MetalKit
import Photos
import SwiftUI
import UIKit
import Vision

// ============================================================================
// 贴花渲染的全部状态与数学，都在这里。
//
// 对应的 Web 版是 decal.html 里的 700 行 JS，这里做的是「同一件事的 Swift 版」：
//   单应（Homography.swift） → 平面 uv → 贴花坐标 → 亮度融合 → 接触阴影
// 几何约定：
//   · corners / center 都是「图像像素」与「uv」，与屏幕尺寸无关
//   · k/ox/oy 只负责把图像坐标摆到屏幕上（逻辑点）
//   · 送进 shader 的 scale/offset 才乘 contentScaleFactor，换成设备像素
// ============================================================================

/// 与 Shaders.metal 的 struct Uniforms 逐字段同序
struct Uniforms {
    var canvas: SIMD2<Float>
    var img: SIMD2<Float>
    var offset: SIMD2<Float>
    var center: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var scale: Float
    var rot: Float
    var shade: Float
    var contact: Float
    var contactPx: Float
    var anchor: Float
    var hinv: simd_float3x3
}

enum Tool { case corner, decal }

private enum DragOp {
    case corner(Int)
    case decal(uv0: CGPoint, c0: CGPoint)
}

final class Editor: ObservableObject {

    /// 贴花半宽的合法区间：下限是看得见，上限是 decalHalf() 里防出平面的 clamp。
    /// 滑杆和双指捏合都指这里，免得两处各写一套数字。
    static let huRange: ClosedRange<Double> = 0.06...0.46

    // ---- UI 绑定 ----
    @Published var mode: Tool = .corner
    @Published var hu: Double = 0.30
    @Published var rot: Double = 0          // 度
    @Published var shade: Double = 0.75
    @Published var contact: Double = 0.5
    @Published var hint: String = ""
    @Published var hasPhoto = false
    @Published var busy = false
    @Published var toast: String = ""
    @Published var corners: [CGPoint] = []
    @Published var center: CGPoint = CGPoint(x: 0.5, y: 0.5)

    // ---- 渲染资源 ----
    var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var sampler: MTLSamplerState?
    private var photoTex: MTLTexture?
    private var decalTex: MTLTexture?
    private(set) var initError: String?

    // ---- 遮挡剔除 ----
    /// 用户开关。默认关：系统分割可能把「墙上那张海报」本身判成前景，
    /// 那样贴花会被自己挡掉，这个功能必须能一键退回。
    @Published var occlEnabled = false
    /// 1×1 全白：没开遮挡 / 分割失败时绑它，shader 采样恒为 1
    private var occlOnes: MTLTexture?
    /// 前景分割结果（照片尺寸，r8Unorm）。nil = 分割没跑出来
    private var occlMask: MTLTexture?
    /// 实际绑给 texture(2) 的那张
    private var occlTex: MTLTexture? { occlEnabled ? (occlMask ?? occlOnes) : occlOnes }

    // ---- 光照场（texture(3)）----
    /// 低频亮度图（32px 宽，r8Unorm）。贴花的不透明感靠它。
    /// 用逐像素亮度做融合，贴花会把底下的砖缝、手写字、毛孔一起搬上来 ——
    /// 那是半透明叠加，不是印刷。实测贴花区内的高频残差 std ≈ 0.10~0.13，
    /// 在浅色/白色贴花上肉眼一眼能看出来。不透明贴纸只跟随「这块表面的整体受光」。
    private var lightTex: MTLTexture?
    /// 1×1 中灰（51/255 = 0.2 = anchor 的初值）兜底：光照场没建出来时
    /// kk = 0.2/0.2 = 1，贴花原样显示，不会整块变黑
    private var lightFallback: MTLTexture?
    private var lightOn: MTLTexture? { lightTex ?? lightFallback }

    // ---- 几何 ----
    private(set) var imgW: Double = 0
    private(set) var imgH: Double = 0
    private var hMat: Mat3?
    private var hInv: Mat3?
    private var jac = CGPoint(x: 1, y: 1)
    private var anchor: Double = 0.2
    private var decalAspect: Double = 340.0 / 1024.0

    private(set) var stageSize: CGSize = .zero
    private var k: CGFloat = 1
    private var ox: CGFloat = 0
    private var oy: CGFloat = 0

    private weak var view: MTKView?
    private var drag: DragOp?
    private var touched = false
    /// 捏合开始那一刻的 hu。每帧都重置基准会让缩放速率失真（越捏越快/越慢）
    private var pinchBase: Double?
    private(set) var pinching = false
    /// 贴花已经顶到平面边界（用来只在刚撞上时震一次，不要一路抖）
    private var hitEdge = false

    // 触觉：拖到角上给一次轻震，存相册成功/失败给成功/失败反馈
    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let notify = UINotificationFeedbackGenerator()

    // 锚点亮度用的低分辨率灰度图（替代 Web 版的 128px 盒式模糊）
    private var lowLum: [Double] = []
    private var lowW = 32
    private var lowH = 1

    // ---------------------------------------------------------------- 初始化

    init() {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            initError = "这台设备不支持 Metal"
            return
        }
        device = dev
        queue = dev.makeCommandQueue()

        guard let lib = dev.makeDefaultLibrary(),
              let vfn = lib.makeFunction(name: "vs_main"),
              let ffn = lib.makeFunction(name: "fs_main") else {
            initError = "着色器没编进包里（检查 Shaders.metal 是否在 target 里）"
            return
        }

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try dev.makeRenderPipelineState(descriptor: pd)
        } catch {
            initError = "管线创建失败：\(error.localizedDescription)"
            return
        }

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        sampler = dev.makeSamplerState(descriptor: sd)

        // 1×1 全白：shader 里 texture(2) 永远有东西可采，开关只换绑哪张图
        occlOnes = TextureIO.solid(255, device: dev)
        if occlOnes == nil { initError = "遮挡用的默认纹理创建失败" }
        lightFallback = TextureIO.solid(51, device: dev)   // 0.2 → kk 恒为 1

        if let def = Editor.makeDefaultDecal() { setDecalCG(def) }
    }

    func attach(_ v: MTKView) { view = v }
    func invalidate() { view?.setNeedsDisplay() }

    // ---------------------------------------------------------------- 照片

    func setPhoto(_ data: Data) {
        guard !busy else { toast = "上一张还在处理，稍等"; return }
        busy = true
        // 48MP HEIC 的 ImageIO 解码能到 500ms，放主线程 = 点完选图界面僵住没反馈
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let cg = Editor.decode(data, maxPixel: 4096)
            // 顺手让 Vision 找画面里最明显的矩形：找到就直接把四角摆上去
            let quad = cg.flatMap { Editor.detectQuad($0) }
            // 遮挡分割跟解码共用同一张图，不额外解码一遍
            let mask = cg.flatMap { self.makeOcclusionMask($0) }
            DispatchQueue.main.async { self.applyPhoto(cg, quad, mask) }
        }
    }

    /// 前景实例分割 → r8 遮挡 mask（照片像素尺寸）。
    /// 模拟器、老设备、系统限制等情况下 Vision 会失败，返回 nil 即可 —— 上层退化成「无遮挡」。
    private func makeOcclusionMask(_ cg: CGImage) -> MTLTexture? {
        guard let device else { return nil }
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else { return nil }
        // 这张 mask 是「照片像素尺寸」，跟 shader 里按照片 uv 采样的 t 天然对齐
        guard let buf = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances,
                                                            from: handler) else { return nil }

        CVPixelBufferLockBaseAddress(buf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        return TextureIO.r8(bytes: UnsafeRawPointer(base),
                            width: CVPixelBufferGetWidth(buf),
                            height: CVPixelBufferGetHeight(buf),
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                            device: device)
    }

    private func applyPhoto(_ cg: CGImage?, _ quad: [CGPoint]?, _ mask: MTLTexture?) {
        defer { busy = false }
        guard let cg else { toast = "这张图片读不出来"; return }
        imgW = Double(cg.width)
        imgH = Double(cg.height)
        photoTex = tex(cg)
        occlMask = mask
        buildLowLum(cg)

        corners = quad ?? defaultCorners()
        center = CGPoint(x: 0.5, y: 0.5)
        hu = 0.30
        rot = 0
        hasPhoto = true
        layout()
        rebuild()
        // 自动找到平面就直接进「拖贴花」：用户选完照片下一步一定是摆贴花，
        // 停在「四点」模式里拖哪儿都没反应，看起来就像整个 App 卡死了
        if quad != nil {
            mode = .decal
            hint = "已自动贴到平面 · 拖贴花挪位置，拖四角微调"
        } else {
            mode = .corner
            hint = "四个角在画面边缘，先拖到你要贴的那个平面上"
        }
        // 开着遮挡换图但分割没结果 → 明确说一声，否则「开了没效果」看起来像 bug
        if occlEnabled && mask == nil { toast = "这张照片没分出前景，遮挡暂时不生效" }
    }

    private func defaultCorners() -> [CGPoint] {
        let ix = imgW * 0.04, iy = imgH * 0.04
        return [CGPoint(x: ix, y: iy),
                CGPoint(x: imgW - ix, y: iy),
                CGPoint(x: imgW - ix, y: imgH - iy),
                CGPoint(x: ix, y: imgH - iy)]
    }

    /// Vision 找最明显的矩形，返回四个「图像像素」角点（左上原点）。
    /// observation 是归一化 + 左下原点，转像素要翻 y。
    private static func detectQuad(_ cg: CGImage) -> [CGPoint]? {
        let req = VNDetectRectanglesRequest()
        req.maximumObservations = 1
        req.minimumConfidence = 0.55
        req.minimumAspectRatio = 0.15
        req.quadratureTolerance = 35
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        } catch {
            return nil
        }
        guard let r = req.results?.first else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: (1 - p.y) * h) }
        return [px(r.topLeft), px(r.topRight), px(r.bottomRight), px(r.bottomLeft)]
    }

    func setDecal(_ data: Data) {
        guard let cg = Editor.decode(data, maxPixel: 2048) else { toast = "这张贴图读不出来"; return }
        setDecalCG(cg)
        recomputeJ()
        invalidate()
    }

    private func setDecalCG(_ cg: CGImage) {
        decalAspect = Double(cg.height) / Double(cg.width)
        decalTex = tex(cg)
    }

    /// 解码并「烘焙」EXIF 方向，同时把最长边压到 maxPixel。
    ///
    /// 不直接用 `UIImage.cgImage`：那是没转过的原始像素，手机竖拍（Orientation 6/8）
    /// 会横躺且宽高颠倒；而 CGImageSource 的 thumbnail 路径能一次把方向转正 + 降采样，
    /// 顺带省掉一张全尺寸中间图（4800 万像素的图直接吃 190MB）。
    private static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opt: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opt as CFDictionary)
    }

    #if DEBUG
    /// 只为 UI 测试截图用：生成一张「左红右蓝、顶部一条白」的探针图，走正常的 setPhoto 链路。
    /// 截图里如果左半是蓝的，就是通道互换；如果白条跑到下面，就是行序翻了。
    static func probePhotoData(w: Int = 600, h: Int = 400) -> Data? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = TextureIO.makeContext(width: w, height: h, space: cs,
                                              info: TextureIO.nativeInfo()) else { return nil }
        // CGContext 的 y 轴向上：y=0 是图像底部
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 40, width: w, height: 40))
        guard let img = ctx.makeImage() else { return nil }
        return UIImage(cgImage: img).jpegData(compressionQuality: 0.95)
    }

    /// 贴花探针：不透明橙底 + 中间一个全透明的洞。
    /// 橙底变半透明 = alpha 错；洞被填满 = alpha 丢了。截图上一眼能看出来。
    static func probeDecalData(w: Int = 320, h: Int = 200) -> Data? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = TextureIO.makeContext(width: w, height: h, space: cs,
                                              info: TextureIO.nativeInfo()) else { return nil }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.clear(CGRect(x: w / 3, y: h / 3, width: w / 3, height: h / 3))
        guard let img = ctx.makeImage() else { return nil }
        return UIImage(cgImage: img).pngData()   // PNG 才带 alpha
    }

    /// 合成遮挡 mask 供 CI 截图断言：左半全黑（挡住）、右半全白（可画）。
    /// 真机的 mask 来自 Vision，模拟器上不一定跑得出来 —— 所以用确定的数据单独验 shader 那段逻辑。
    func setProbeOcclusion() {
        guard let device else { return }
        let w = 64, h = 64
        var bytes = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<(w / 2) { bytes[y * w + x] = 0 }
        }
        occlMask = bytes.withUnsafeBytes { raw in
            TextureIO.r8(bytes: raw.baseAddress!, width: w, height: h,
                         bytesPerRow: w, device: device)
        }
        occlEnabled = true
        invalidate()
    }
    #endif

    /// 纹理统一走 TextureIO：显式按 RGBA8 画一遍再上传。
    /// 不用 MTKTextureLoader —— 它按 CGImage 的 bitmapInfo 自己猜格式，猜错时不报错，
    /// 只是照片整体发蓝、贴图发虚像透明的（真机上报过）。
    private func tex(_ cg: CGImage) -> MTLTexture? {
        guard let device else { return nil }
        return TextureIO.bgra8(from: cg, device: device)
    }

    // ---------------------------------------------------------------- 布局

    func setStage(_ size: CGSize) {
        guard size != stageSize else { return }
        stageSize = size
        layout()
    }

    private func layout() {
        let cw = stageSize.width, ch = stageSize.height
        guard cw > 1, ch > 1, imgW > 0, imgH > 0 else { return }
        k = min(cw / CGFloat(imgW), ch / CGFloat(imgH))
        ox = (cw - CGFloat(imgW) * k) / 2
        oy = (ch - CGFloat(imgH) * k) / 2
        invalidate()
    }

    func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * k + ox, y: p.y * k + oy)
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - ox) / k, y: (p.y - oy) / k)
    }

    // ---------------------------------------------------------------- 几何

    func rebuild() {
        hMat = Homography.solve(corners)
        hInv = hMat?.inverse
        if hMat != nil {
            recomputeJ()
            recomputeAnchor()
        }
        invalidate()
    }

    /// 拖乱了 / 自动找的平面不对时的一键退路：四角回满幅、贴花回中心、大小角度归位
    func reset() {
        guard hasPhoto, imgW > 0, imgH > 0 else { return }
        corners = defaultCorners()
        center = CGPoint(x: 0.5, y: 0.5)
        hu = 0.30
        rot = 0
        rebuild()
        impact.impactOccurred()
        toast = "已重置"
    }

    private func recomputeJ() {
        guard let hMat else { return }
        let e = 1e-3
        guard let p0 = hMat.map(Double(center.x), Double(center.y)),
              let p1 = hMat.map(Double(center.x) + e, Double(center.y)),
              let p2 = hMat.map(Double(center.x), Double(center.y) + e) else { return }
        jac = CGPoint(x: max(1e-6, hypot(Double(p1.x - p0.x), Double(p1.y - p0.y)) / e),
                      y: max(1e-6, hypot(Double(p2.x - p0.x), Double(p2.y - p0.y)) / e))
    }

    /// uv 单位下的贴花半宽/半高。用雅可比还原贴花图自身宽高比，
    /// 这样 1024×340 的贴纸贴上去还是 3:1，不被平面长宽比拉扁。
    ///
    /// hu 的语义是「较长那条边的一半」：宽扁贴花（比如 3:1）如果按短边算，
    /// 长边早就顶到 0.46 上限，滑杆后面一多半行程是死的 —— 真机上就是「拖到某个位置就没反应」。
    func decalHalf() -> (Double, Double) {
        let ratio = (Double(jac.x) / Double(jac.y)) * decalAspect   // b / a
        var a = hu
        var b = hu * ratio
        if ratio > 1 {          // 长边在 b 上：让 b 就是 hu，a 按比例缩回去
            b = hu
            a = hu / ratio
        }
        let mx = max(a, b)
        if mx > Editor.huRange.upperBound {
            let f = Editor.huRange.upperBound / mx
            a *= f
            b *= f
        }
        return (a, b)
    }

    func decalQuadImage() -> [CGPoint] {
        guard let hMat else { return [] }
        let (hu2, hv2) = decalHalf()
        let rad = rot * .pi / 180
        let c = cos(rad), s = sin(rad)
        let unit: [(Double, Double)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        return unit.compactMap { pair -> CGPoint? in
            let (a, b) = pair
            let du = a * hu2 * c - b * hv2 * s
            let dv = a * hu2 * s + b * hv2 * c
            return hMat.map(Double(center.x) + du, Double(center.y) + dv)
        }
    }

    func decalQuadScreen() -> [CGPoint] {
        decalQuadImage().map(toScreen)
    }

    private func contactImgPx() -> Double {
        // 用「图像像素」定义阴影宽度，预览和全分辨率导出才一致
        4.0 * max(imgW, imgH) / 1000.0
    }

    // ---------------------------------------------------------------- 锚点亮度

    /// Web 版是 128px 图 + 3 次盒式模糊后取一个点。这里用 32px 图 + 3×3 平均，
    /// 两者在「图宽的 4~5%」这个尺度上等价，而这个尺度是调参出来的主观量，
    /// 不需要逐位一致。（要严格一致就把 128px 模糊搬过来，但多 60 行。）
    private func buildLowLum(_ cg: CGImage) {
        lowW = 32
        lowH = max(1, Int((32.0 * imgH / max(1, imgW)).rounded()))
        var buf = [UInt8](repeating: 0, count: lowW * lowH * 4)
        var out = [Double](repeating: 0.2, count: lowW * lowH)

        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: lowW, height: lowH,
                                      bitsPerComponent: 8, bytesPerRow: lowW * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: lowW, height: lowH))
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<(lowW * lowH) {
                let o = i * 4
                out[i] = (0.2126 * Double(p[o]) + 0.7152 * Double(p[o + 1]) + 0.0722 * Double(p[o + 2])) / 255.0
            }
        }
        lowLum = out
        buildLightTex()
    }

    /// lowLum → 光照场纹理。
    /// 直接拿 32px 的 lowLum 当纹理会在贴花上出斑块：CGContext 缩小 100 倍以上是**稀疏采样**
    /// 不是面积平均（原来的 3×3 只覆盖锚点那一个点，全图没处理过）。
    /// 全图 3×3 模糊一遍，32×21×9 ≈ 6k 次浮点，只在换照片时跑一次。
    private func buildLightTex() {
        guard let device, lowW > 0, lowH > 0, lowLum.count >= lowW * lowH else { return }
        var px = [UInt8](repeating: 0, count: lowW * lowH)
        for y in 0..<lowH {
            for x in 0..<lowW {
                var s = 0.0, n = 0.0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx, yy = y + dy
                        guard xx >= 0, xx < lowW, yy >= 0, yy < lowH else { continue }
                        s += lowLum[yy * lowW + xx]; n += 1
                    }
                }
                px[y * lowW + x] = UInt8(max(0, min(255, ((s / n) * 255).rounded())))
            }
        }
        lightTex = px.withUnsafeBytes { raw in
            TextureIO.r8(bytes: raw.baseAddress!, width: lowW, height: lowH,
                         bytesPerRow: lowW, device: device)
        }
    }

    private func recomputeAnchor() {
        guard !lowLum.isEmpty, let hMat, imgW > 0, imgH > 0 else { anchor = 0.2; return }
        guard let p = hMat.map(Double(center.x), Double(center.y)),
              p.x.isFinite, p.y.isFinite else { return }

        let bx = min(lowW - 1, max(0, Int((Double(p.x) / imgW * Double(lowW - 1)).rounded())))
        let byTop = min(lowH - 1, max(0, Int((Double(p.y) / imgH * Double(lowH - 1)).rounded())))
        let by = byTop     // CGBitmapContext 的 data row 0 就是图像顶部（与 canvas getImageData 同）；
                           // 原点在左下只影响 draw 的 rect 解释，不影响存储行序 —— 不要再翻一次

        var sum = 0.0, n = 0.0
        for dy in -1...1 {
            for dx in -1...1 {
                let x = bx + dx, y = by + dy
                guard x >= 0, x < lowW, y >= 0, y < lowH else { continue }
                sum += lowLum[y * lowW + x]
                n += 1
            }
        }
        anchor = max(0.03, n > 0 ? sum / n : 0.2)
    }

    // ---------------------------------------------------------------- 手势

    var isTouching: Bool { touched }

    func setMode(_ m: Tool) {
        mode = m
        // 角点任何时候都能拖（见 touchStart），这个模式实际只决定「贴花能不能拖」
        hint = m == .decal
            ? "拖贴花挪位置 · 四个角点也随时能拖"
            : "拖四个角点框住平面 · 点「贴花」才能拖贴花"
        invalidate()
    }

    /// 遮挡开关。没有分割结果时直接说清楚，否则「开了但没变化」看起来像坏了
    func toggleOcclusion() {
        guard hasPhoto else { return }
        guard occlMask != nil else {
            toast = "这张照片没分出前景，遮挡用不了"
            return
        }
        occlEnabled.toggle()
        if occlEnabled { toast = "遮挡已开 · 被前景挡住的部分不画" }
        invalidate()
    }

    /// 双指捏合改贴花大小。DragGesture 只会跟第一根手指，所以捏合时中心不会跟着漂；
    /// 但第一根手指落下时可能已经触发过一次 touchStart，这里在 pinch 开始时把它清掉。
    func pinch(_ magnification: Double) {
        guard hasPhoto, !busy, hMat != nil else { return }
        if pinchBase == nil {
            pinchBase = hu
            pinching = true
            drag = nil
            touched = false
            impact.impactOccurred()
            if !hint.isEmpty { hint = "" }
        }
        hu = min(Editor.huRange.upperBound,
                 max(Editor.huRange.lowerBound, (pinchBase ?? hu) * Double(magnification)))
        invalidate()
    }

    func touchStart(_ loc: CGPoint) {
        guard !pinching else { return }
        touched = true
        guard hasPhoto, hMat != nil else { return }
        let ip = toImage(loc)

        // 角点优先：手指落在角点附近就是要拖角，不管当前是哪个模式。
        // 以前只在「四点」模式下能拖角，切到「贴花」后点框就"没反应"了。
        var bi = -1
        var bd = Double.greatestFiniteMagnitude
        for (i, c) in corners.enumerated() {
            let d = hypot(Double(c.x - ip.x), Double(c.y - ip.y))
            if d < bd { bd = d; bi = i }
        }
        if bd * Double(k) <= 44 {
            drag = .corner(bi)
            impact.impactOccurred()          // 抓到角了，给一次轻震
            if !hint.isEmpty { hint = "" }   // 一动手就把提示收掉，别一直压在照片上
            return
        }

        // 没点中角点：只有「贴花」模式才拖贴花，避免在调四角时把贴花拖跑
        if mode == .decal,
           pointInPoly(ip, decalQuadImage()),
           let uv0 = hInv?.map(Double(ip.x), Double(ip.y)) {
            drag = .decal(uv0: uv0, c0: center)
        }
    }

    func touchMove(_ loc: CGPoint) {
        guard let drag else { return }
        let ip = toImage(loc)

        switch drag {
        case .corner(let i):
            guard corners.indices.contains(i) else { return }
            // 限制在照片范围内，别把角拖到画布外丢了
            let nc = CGPoint(x: min(max(ip.x, 0), CGFloat(imgW)),
                             y: min(max(ip.y, 0), CGFloat(imgH)))
            // 两个角拖到一起 / 三点共线 → 单应无解 → shader 整屏早退，画面空白。
            // 无解就拒绝这次移动，角停在上一帧有效位置。
            var trial = corners
            trial[i] = nc
            guard Homography.solve(trial) != nil else { return }
            corners = trial
            rebuild()

        case .decal(let uv0, let c0):
            guard let uv1 = hInv?.map(Double(ip.x), Double(ip.y)) else { return }
            let nx = Double(c0.x) + Double(uv1.x) - Double(uv0.x)
            let ny = Double(c0.y) + Double(uv1.y) - Double(uv0.y)
            // 贴花只能在平面内挪：出了平面 shader 直接裁掉，看起来像"贴花没了"。
            // 所以这里夹住，撞到边界震一下 —— 让人知道是到头了，不是卡住了。
            let cx = min(max(nx, -0.2), 1.2)
            let cy = min(max(ny, -0.2), 1.2)
            let atEdge = (cx != nx) || (cy != ny)
            if atEdge && !hitEdge { impact.impactOccurred() }
            hitEdge = atEdge
            center = CGPoint(x: cx, y: cy)
            recomputeJ()
            // 拖动中不更新锚点：基准跟着位置变，整张贴花会忽明忽暗。松手再算（见 touchEnd）
            invalidate()
        }
    }

    func touchEnd() {
        drag = nil
        touched = false
        hitEdge = false
        // 捏合被打断（来电/切后台）不一定有 onEnded，复位放这里一处管住
        pinchBase = nil
        pinching = false
        // 松手才定锚点，避免拖动时整张贴花亮度跳
        if hasPhoto, hMat != nil { recomputeAnchor(); invalidate() }
    }

    private func pointInPoly(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let xi = poly[i].x, yi = poly[i].y
            let xj = poly[j].x, yj = poly[j].y
            if (yi > p.y) != (yj > p.y),
               p.x < (xj - xi) * (p.y - yi) / (yj - yi + 1e-12) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // ---------------------------------------------------------------- 渲染

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let queue, let pipeline,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        if let photoTex, let hInv, let occl = occlTex, let light = lightOn, imgW > 0 {
            let cs = view.contentScaleFactor
            let (hu2, hv2) = decalHalf()
            var u = Uniforms(
                canvas: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                img: SIMD2(Float(imgW), Float(imgH)),
                offset: SIMD2(Float(ox * cs), Float(oy * cs)),
                center: SIMD2(Float(center.x), Float(center.y)),
                halfSize: SIMD2(Float(hu2), Float(hv2)),
                scale: Float(k * cs),
                rot: Float(rot * .pi / 180),
                shade: Float(shade),
                contact: Float(contact),
                contactPx: Float(contactImgPx() * Double(k * cs)),
                anchor: Float(anchor),
                hinv: hInv.msl
            )
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(photoTex, index: 0)
            enc.setFragmentTexture(decalTex, index: 1)
            enc.setFragmentTexture(occl, index: 2)
            enc.setFragmentTexture(light, index: 3)
            if let s = sampler { enc.setFragmentSamplerState(s, index: 0) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    // ---------------------------------------------------------------- 导出

    func exportImage() -> UIImage? {
        guard let photoTex, let hInv, let occl = occlTex, let light = lightOn, imgW > 0,
              let device, let queue, let pipeline else { return nil }

        var w = Int(imgW), h = Int(imgH)
        let maxD = 4096
        if max(w, h) > maxD {
            let f = Double(maxD) / Double(max(w, h))
            w = Int((Double(w) * f).rounded())
            h = Int((Double(h) * f).rounded())
        }

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                         width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        guard let target = device.makeTexture(descriptor: d) else { return nil }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.043, 0.047, 0.055, 1)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }

        let (hu2, hv2) = decalHalf()
        let scale = Double(w) / imgW
        var u = Uniforms(
            canvas: SIMD2(Float(w), Float(h)),
            img: SIMD2(Float(imgW), Float(imgH)),
            offset: SIMD2(0, 0),
            center: SIMD2(Float(center.x), Float(center.y)),
            halfSize: SIMD2(Float(hu2), Float(hv2)),
            scale: Float(scale),
            rot: Float(rot * .pi / 180),
            shade: Float(shade),
            contact: Float(contact),
            contactPx: Float(contactImgPx() * scale),
            anchor: Float(anchor),
            hinv: hInv.msl
        )
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.setFragmentTexture(photoTex, index: 0)
        enc.setFragmentTexture(decalTex, index: 1)
        enc.setFragmentTexture(occl, index: 2)
        enc.setFragmentTexture(light, index: 3)
        if let s = sampler { enc.setFragmentSamplerState(s, index: 0) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        let rowBytes = w * 4
        var buf = [UInt8](repeating: 0, count: rowBytes * h)
        buf.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: rowBytes,
                            from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }

        guard let provider = CGDataProvider(data: Data(buf) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                        | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }

    func saveToAlbum() {
        guard !busy else { return }
        busy = true
        // 4096 离屏渲染 + 67MB getBytes + 组图，主线程做会冻住界面
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = CACurrentMediaTime()
            let img = self.exportImage()
            let ms = Int((CACurrentMediaTime() - t0) * 1000)
            DispatchQueue.main.async { self.finishSave(img, ms: ms) }
        }
    }

    private func finishSave(_ img: UIImage?, ms: Int) {
        guard let img else {
            busy = false
            toast = "导出失败"
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] st in
            guard st == .authorized || st == .limited else {
                DispatchQueue.main.async {
                    self?.busy = false
                    self?.toast = "没有相册写入权限，去「设置 → 贴花」打开"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            } completionHandler: { ok, err in
                DispatchQueue.main.async {
                    self?.busy = false
                    self?.toast = ok ? "已存入相册 · \(ms)ms"
                                     : (err?.localizedDescription ?? "保存失败")
                    self?.notify.notificationOccurred(ok ? .success : .error)
                }
            }
        }
    }

    // ---------------------------------------------------------------- 默认贴花

    static func makeDefaultDecal() -> CGImage? {
        let w: CGFloat = 1024, h: CGFloat = 340
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
            let pad: CGFloat = 8
            let rect = CGRect(x: pad, y: pad, width: w - pad * 2, height: h - pad * 2)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 40)
            UIColor(red: 0.051, green: 0.588, blue: 0.686, alpha: 0.96).setFill()
            path.fill()
            UIColor.white.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 7
            path.stroke()

            let p = NSMutableParagraphStyle()
            p.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 152, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: p,
            ]
            let s = "MAX" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(in: CGRect(x: 0, y: (h - size.height) / 2 + 8, width: w, height: size.height),
                   withAttributes: attrs)
        }.cgImage
    }
}

// ============================================================================
// MTKView 包装：按需重绘（参数不变就不耗电）
// ============================================================================

struct MetalView: UIViewRepresentable {
    let ed: Editor

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = ed.device
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.isOpaque = true
        v.clearColor = MTLClearColorMake(0.043, 0.047, 0.055, 1)
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        // 画布本身不需要自己的交互：拖拽/捏合都由上层 SwiftUI 手势处理。
        // 留着默认的 true，这个铺满全屏的 UIView 会参与 UIKit 命中测试，把上层控件的点击吃掉。
        v.isUserInteractionEnabled = false
        v.delegate = context.coordinator
        ed.attach(v)
        return v
    }

    func updateUIView(_ v: MTKView, context: Context) {
        v.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator { Coordinator(ed: ed) }

    final class Coordinator: NSObject, MTKViewDelegate {
        let ed: Editor
        init(ed: Editor) { self.ed = ed }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) { ed.draw(in: view) }
    }
}
