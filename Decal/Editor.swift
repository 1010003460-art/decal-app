import ImageIO
import Metal
import MetalKit
import Photos
import SwiftUI
import UIKit

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
    private var loader: MTKTextureLoader?
    private var photoTex: MTLTexture?
    private var decalTex: MTLTexture?
    private(set) var initError: String?

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
        loader = MTKTextureLoader(device: dev)

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

        if let def = Editor.makeDefaultDecal() { setDecalCG(def) }
    }

    func attach(_ v: MTKView) { view = v }
    func invalidate() { view?.setNeedsDisplay() }

    // ---------------------------------------------------------------- 照片

    func setPhoto(_ data: Data) {
        guard let cg = Editor.decode(data, maxPixel: 4096) else { toast = "这张图片读不出来"; return }
        imgW = Double(cg.width)
        imgH = Double(cg.height)
        photoTex = tex(cg)
        buildLowLum(cg)

        let ix = imgW * 0.04, iy = imgH * 0.04
        corners = [CGPoint(x: ix, y: iy),
                   CGPoint(x: imgW - ix, y: iy),
                   CGPoint(x: imgW - ix, y: imgH - iy),
                   CGPoint(x: ix, y: imgH - iy)]
        center = CGPoint(x: 0.5, y: 0.5)
        hu = 0.30
        rot = 0
        hasPhoto = true
        layout()
        rebuild()
        mode = .corner
        hint = "四个角已放在画面边缘，把它们拖到你真正要贴的那个平面上"
    }

    func setDecal(_ data: Data) {
        if let cg = Editor.decode(data, maxPixel: 2048) { setDecalCG(cg) }
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

    private func tex(_ cg: CGImage) -> MTLTexture? {
        guard let loader else { return nil }
        // SRGB:false → 保持 8bit 数值，跟 WebGL 版颜色一致
        let opt: [MTKTextureLoader.Option: Any] = [.SRGB: NSNumber(value: false)]
        return try? loader.newTexture(cgImage: cg, options: opt)
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
    func decalHalf() -> (Double, Double) {
        var a = hu
        var b = hu * (Double(jac.x) / Double(jac.y)) * decalAspect
        let mx = max(a, b)
        if mx > 0.46 {
            let f = 0.46 / mx
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
    }

    private func recomputeAnchor() {
        guard !lowLum.isEmpty, let hMat, imgW > 0, imgH > 0 else { anchor = 0.2; return }
        guard let p = hMat.map(Double(center.x), Double(center.y)),
              p.x.isFinite, p.y.isFinite else { return }

        let bx = min(lowW - 1, max(0, Int((Double(p.x) / imgW * Double(lowW - 1)).rounded())))
        let byTop = min(lowH - 1, max(0, Int((Double(p.y) / imgH * Double(lowH - 1)).rounded())))
        let by = lowH - 1 - byTop     // CGContext 原点在左下，行要翻过来

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
        hint = m == .corner
            ? "把四个角拖到平面的四个角上"
            : "拖动贴花移动位置，用上面的滑杆调大小和角度"
        invalidate()
    }

    func touchStart(_ loc: CGPoint) {
        touched = true
        guard hasPhoto, hMat != nil else { return }
        let ip = toImage(loc)

        if mode == .corner {
            var bi = -1
            var bd = Double.greatestFiniteMagnitude
            for (i, c) in corners.enumerated() {
                let d = hypot(Double(c.x - ip.x), Double(c.y - ip.y))
                if d < bd { bd = d; bi = i }
            }
            if bd * Double(k) <= 38 {
                drag = .corner(bi)
                if !hint.isEmpty { hint = "" }   // 一动手就把提示收掉，别一直压在照片上
            }
        } else {
            if pointInPoly(ip, decalQuadImage()), let uv0 = hInv?.map(Double(ip.x), Double(ip.y)) {
                drag = .decal(uv0: uv0, c0: center)
            }
        }
    }

    func touchMove(_ loc: CGPoint) {
        guard let drag else { return }
        let ip = toImage(loc)

        switch drag {
        case .corner(let i):
            guard corners.indices.contains(i) else { return }
            // 限制在照片范围内，别把角拖到画布外丢了
            corners[i] = CGPoint(x: min(max(ip.x, 0), CGFloat(imgW)),
                                 y: min(max(ip.y, 0), CGFloat(imgH)))
            rebuild()

        case .decal(let uv0, let c0):
            guard let uv1 = hInv?.map(Double(ip.x), Double(ip.y)) else { return }
            center = CGPoint(x: min(max(Double(c0.x) + Double(uv1.x) - Double(uv0.x), -0.2), 1.2),
                             y: min(max(Double(c0.y) + Double(uv1.y) - Double(uv0.y), -0.2), 1.2))
            recomputeJ()
            recomputeAnchor()
            invalidate()
        }
    }

    func touchEnd() {
        drag = nil
        touched = false
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

        if let photoTex, let hInv, imgW > 0 {
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
            if let s = sampler { enc.setFragmentSamplerState(s, index: 0) }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    // ---------------------------------------------------------------- 导出

    func exportImage() -> UIImage? {
        guard let photoTex, let hInv, imgW > 0,
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
        let t0 = CACurrentMediaTime()
        guard let img = exportImage() else {
            busy = false
            toast = "导出失败"
            return
        }
        let ms = Int((CACurrentMediaTime() - t0) * 1000)

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
