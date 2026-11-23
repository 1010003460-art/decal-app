import Photos
import SwiftUI
import UIKit

// MARK: - 示例贴纸（代码生成，不依赖图片资源）

enum Decal {
    static func make(text: String = "MAX") -> UIImage {
        let size = CGSize(width: 640, height: 200)
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), cornerRadius: 34)
            UIColor(red: 0.05, green: 0.62, blue: 0.72, alpha: 0.95).setFill()
            path.fill()
            UIColor.white.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 6
            path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 126, weight: .heavy),
                .foregroundColor: UIColor.white,
            ]
            let s = NSAttributedString(string: text, attributes: attrs)
            let sz = s.size()
            s.draw(at: CGPoint(x: (size.width - sz.width) / 2, y: (size.height - sz.height) / 2))
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    private enum Stage { case pick, edit, done }

    @State private var stage: Stage = .pick
    @State private var original: UIImage?
    @State private var flat: UIImage?
    @State private var flatPixels: CGSize = .zero
    @State private var quad: [CGPoint] = []
    @State private var decal: UIImage = Decal.make()

    // 贴纸位置全部用「相对展平图宽高的比例」表示，屏幕和导出共用一套换算
    @State private var offsetRel: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var rotation: Angle = .zero
    @State private var baseRotation: Angle = .zero

    @State private var showPicker = false
    @State private var message: String?
    @State private var result: UIImage?
    @State private var busy = false
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .pick: pickView
                case .edit: editView
                case .done: doneView
                }
            }
            .navigationTitle("贴花")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if stage != .pick {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("换照片") { showPicker = true }
                    }
                }
            }
        }
        .sheet(isPresented: $showPicker) {
            PhotoPicker { img in load(img) }
                .ignoresSafeArea()
        }
        .alert("提示", isPresented: Binding(get: { message != nil },
                                            set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: 选照片

    private var pickView: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            Text("选一张有墙、海报或包装的照片")
                .font(.headline)
            Text("会自动找出画面里最大的平面，\n展开成正面后再往上贴。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                showPicker = true
            } label: {
                Text("选择照片")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
    }

    // MARK: 编辑

    private var editView: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let fit = fitted(flatPixels, in: geo.size)
                let dw = fit.width * 0.30
                let dh = dw * decal.size.height / max(decal.size.width, 1)
                ZStack {
                    if let flat {
                        Image(uiImage: flat)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fit.width, height: fit.height)
                    }
                    Image(uiImage: decal)
                        .resizable()
                        .frame(width: dw, height: dh)
                        .scaleEffect(scale)
                        .rotationEffect(rotation)
                        .offset(x: offsetRel.width * fit.width,
                                y: offsetRel.height * fit.height)
                        .gesture(dragGesture(fit))
                        .simultaneousGesture(magnifyGesture)
                        .simultaneousGesture(rotateGesture)
                }
                .frame(width: fit.width, height: fit.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            editBar
        }
    }

    private var editBar: some View {
        HStack {
            Button {
                resetDecal()
            } label: {
                Label("复位", systemImage: "arrow.counterclockwise")
            }
            Spacer()
            if busy {
                ProgressView()
            }
            Spacer()
            Button {
                export()
            } label: {
                Label("贴上去", systemImage: "checkmark.circle.fill")
                    .font(.headline)
            }
            .disabled(busy)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func dragGesture(_ fit: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { v in
                offsetRel = CGSize(
                    width: baseOffset.width + v.translation.width / max(fit.width, 1),
                    height: baseOffset.height + v.translation.height / max(fit.height, 1))
            }
            .onEnded { _ in baseOffset = offsetRel }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in scale = min(4, max(0.15, baseScale * v.magnification)) }
            .onEnded { _ in baseScale = scale }
    }

    private var rotateGesture: some Gesture {
        RotateGesture()
            .onChanged { v in rotation = baseRotation + v.rotation }
            .onEnded { _ in baseRotation = rotation }
    }

    // MARK: 结果

    private var doneView: some View {
        VStack(spacing: 14) {
            if let result {
                Image(uiImage: result)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 12)
            }
            HStack(spacing: 22) {
                Button {
                    saveToAlbum()
                } label: {
                    Label(saved ? "已保存" : "存相册", systemImage: "square.and.arrow.down")
                }
                if let result {
                    ShareLink(item: Image(uiImage: result),
                              preview: SharePreview("贴花", image: Image(uiImage: result))) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    restart()
                } label: {
                    Label("再贴一张", systemImage: "photo.badge.plus")
                }
            }
            .padding(.bottom, 18)
        }
    }

    // MARK: 流程

    private func load(_ img: UIImage) {
        let norm = normalized(img)
        guard let cg = norm.cgImage else {
            message = "无法读取这张照片"
            return
        }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let detected = RectDetector.detect(in: cg)
        // 找不到矩形就按「整张照片是一个平面」处理，别让用户卡住
        let q = detected ?? [
            CGPoint(x: w * 0.05, y: h * 0.95),
            CGPoint(x: w * 0.95, y: h * 0.95),
            CGPoint(x: w * 0.05, y: h * 0.05),
            CGPoint(x: w * 0.95, y: h * 0.05),
        ]
        guard let flatCG = Perspective.flatten(CIImage(cgImage: cg), quad: q) else {
            message = "这张照片展平失败，换一张试试"
            return
        }
        original = norm
        quad = q
        flat = UIImage(cgImage: flatCG)
        flatPixels = CGSize(width: flatCG.width, height: flatCG.height)
        resetDecal()
        result = nil
        saved = false
        stage = .edit
        if detected == nil { message = "没找到明显的矩形平面，先按整张照片处理" }
    }

    private func resetDecal() {
        offsetRel = .zero
        baseOffset = .zero
        scale = 1
        baseScale = 1
        rotation = .zero
        baseRotation = .zero
    }

    private func restart() {
        stage = .pick
        original = nil
        flat = nil
        result = nil
        quad = []
        saved = false
        showPicker = true
    }

    private func export() {
        guard let original, let flat else { return }
        busy = true
        let o = offsetRel, s = scale, r = rotation, d = decal, q = quad
        DispatchQueue.global(qos: .userInitiated).async {
            let out = compose(original: original, flat: flat, quad: q,
                              offsetRel: o, scale: s, rotation: r, decal: d)
            DispatchQueue.main.async {
                busy = false
                if let out {
                    result = out
                    saved = false
                    stage = .done
                } else {
                    message = "合成失败"
                }
            }
        }
    }

    private func compose(original: UIImage, flat: UIImage, quad: [CGPoint],
                         offsetRel: CGSize, scale: CGFloat, rotation: Angle,
                         decal: UIImage) -> UIImage? {
        guard let flatCG = flat.cgImage, let origCG = original.cgImage else { return nil }
        let fw = CGFloat(flatCG.width), fh = CGFloat(flatCG.height)
        let ow = CGFloat(origCG.width), oh = CGFloat(origCG.height)

        let dw = fw * 0.30 * scale
        let dh = dw * decal.size.height / max(decal.size.width, 1)
        let cx = fw * 0.5 + offsetRel.width * fw
        let cy = fh * 0.5 + offsetRel.height * fh

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true
        let merged = UIGraphicsImageRenderer(size: CGSize(width: fw, height: fh), format: fmt).image { ctx in
            flat.draw(in: CGRect(x: 0, y: 0, width: fw, height: fh))
            ctx.cgContext.translateBy(x: cx, y: cy)
            ctx.cgContext.rotate(by: CGFloat(rotation.radians))
            decal.draw(in: CGRect(x: -dw / 2, y: -dh / 2, width: dw, height: dh))
        }

        guard let mergedCG = merged.cgImage,
              let flatBuf = ImageBuffer(cgImage: mergedCG),
              let baseBuf = ImageBuffer(cgImage: origCG) else { return nil }

        // quad 存的是 CIImage 坐标（y 向上），这里换成像素坐标（y 向下）
        let q = quad.map { CGPoint(x: $0.x, y: oh - $0.y) }
        guard let ov = Perspective.overlay(flat: flatBuf, quad: q,
                                           canvasW: Int(ow), canvasH: Int(oh)) else { return nil }
        return Perspective.composite(base: baseBuf, overlay: ov)
    }

    private func saveToAlbum() {
        guard let result else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { message = "没有相册写入权限，去设置里打开" }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: result)
            } completionHandler: { ok, err in
                DispatchQueue.main.async {
                    if ok { saved = true } else { message = err?.localizedDescription ?? "保存失败" }
                }
            }
        }
    }

    // MARK: 小工具

    private func normalized(_ img: UIImage) -> UIImage {
        guard img.imageOrientation != .up else { return img }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: img.size, format: fmt).image { _ in
            img.draw(in: CGRect(origin: .zero, size: img.size))
        }
    }

    private func fitted(_ content: CGSize, in box: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0, box.width > 0, box.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        let k = min(box.width / content.width, box.height / content.height)
        return CGSize(width: content.width * k, height: content.height * k)
    }
}

#Preview {
    ContentView()
}
