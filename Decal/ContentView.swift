import PhotosUI
import SwiftUI
import UIKit

// ============================================================================
// 界面层：画布（Metal）+ 手柄（Canvas 叠加）+ 底部面板（SwiftUI 原生控件）
// 所有状态都在 Editor 里，这里只负责摆放和转发手势。
// ============================================================================

private let cBg      = Color(red: 0.067, green: 0.075, blue: 0.086)
private let cPanel   = Color(red: 0.106, green: 0.118, blue: 0.137)
private let cChip    = Color(red: 0.145, green: 0.165, blue: 0.192)
private let cLine    = Color(red: 0.173, green: 0.192, blue: 0.220)
private let cDim     = Color(red: 0.545, green: 0.576, blue: 0.620)
private let cAccent  = Color(red: 0.184, green: 0.714, blue: 0.784)
private let cAccent2 = Color(red: 0.478, green: 0.910, blue: 0.980)

struct ContentView: View {
    @StateObject private var ed = Editor()
    @State private var photoItem: PhotosPickerItem?
    @State private var decalItem: PhotosPickerItem?
    @State private var showCamera = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            stage
            if ed.hasPhoto { controlBar }
        }
        .background(cBg)
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) { toastView }
        .onChange(of: photoItem) { _, item in load(item, isPhoto: true) }
        .onChange(of: decalItem) { _, item in load(item, isPhoto: false) }
        .onChange(of: ed.toast) { _, t in autoHide(t) }
        // 手势被来电/切后台打断时不会走 onEnded，touched 会永久卡住 → 之后再也拖不动
        .onChange(of: scenePhase) { _, p in if p != .active { ed.touchEnd() } }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in ed.setPhoto(data) }
                .ignoresSafeArea()
        }
    }

    // ---------------------------------------------------------------- 画布

    private var stage: some View {
        GeometryReader { geo in
            ZStack {
                MetalView(ed: ed)
                Handles(ed: ed).allowsHitTesting(false)
                if !ed.hasPhoto { emptyState }
                if let err = ed.initError {
                    Text(err).font(.system(size: 13))
                        .foregroundStyle(.white).padding(24)
                        .multilineTextAlignment(.center)
                }
                hintView
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            // including: .none —— 没照片时这层手势会把空态里的「选择照片」按钮吃掉；
            // busy（解码/导出）时也关掉，导出读的是同一份状态，别让拖动改到一半
            .gesture(dragGesture, including: (ed.hasPhoto && !ed.busy) ? .all : .none)
            // 捏合与单指拖同时挂着：SwiftUI 里并存的两个手势只有 simultaneousGesture 能都收到
            .simultaneousGesture(magnifyGesture)
            .onAppear { ed.setStage(geo.size) }
            .onChange(of: geo.size) { _, s in ed.setStage(s) }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if ed.isTouching { ed.touchMove(v.location) } else { ed.touchStart(v.location) }
            }
            .onEnded { _ in ed.touchEnd() }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { v in ed.pinch(Double(v.magnification)) }
            .onEnded { _ in ed.touchEnd() }      // 复位走同一个入口
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("▣").font(.system(size: 38)).opacity(0.85)
            Text("选一张有平面的照片").font(.system(size: 17, weight: .semibold))
            Text("墙、海报、包装、纸箱、屏幕都行。\n把四个角拖到那个平面的四个角上，再贴。")
                .font(.system(size: 13)).foregroundStyle(cDim)
                .multilineTextAlignment(.center).lineSpacing(4)
            HStack(spacing: 10) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Text("选择照片").primaryBG()
                }
                Button { openCamera() } label: {
                    Text("拍一张")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(cLine))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(26)
    }

    private var hintView: some View {
        VStack {
            if ed.hasPhoto && !ed.hint.isEmpty {
                Text(ed.hint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(red: 0.89, green: 0.91, blue: 0.93))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .shadow(color: .black.opacity(0.9), radius: 4, y: 1)
                    .padding(.top, 10)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var toastView: some View {
        Group {
            if !ed.toast.isEmpty {
                Text(ed.toast)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Color(red: 0.078, green: 0.094, blue: 0.110).opacity(0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(cLine))
                    .padding(.bottom, ed.hasPhoto ? 132 : 40)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: ed.toast)
    }

    // ---------------------------------------------------------------- 面板

    private var controlBar: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                slider("大小", value: pbind(\.hu), range: Editor.huRange) { "\(Int($0 * 100))" }
                slider("旋转", value: pbind(\.rot), range: -60...60) { "\(Int($0))°" }
            }
            HStack(spacing: 10) {
                slider("表面融合", value: pbind(\.shade), range: 0...1) { "\(Int($0 * 100))%" }
                slider("接触阴影", value: pbind(\.contact), range: 0...1) { "\(Int($0 * 100))%" }
            }
            HStack(spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Text("照片").chipBG()
                }
                Button { openCamera() } label: {
                    Text("拍").chipBG()
                }
                .buttonStyle(.plain)
                PhotosPicker(selection: $decalItem, matching: .images) {
                    Text("贴图").chipBG()
                }
                Button { ed.reset() } label: {
                    Text("重置").chipBG()
                }
                .buttonStyle(.plain)
                Button { ed.setMode(.corner) } label: {
                    Text("四点").chipBG(ed.mode == .corner)
                }
                .buttonStyle(.plain)
                Button { ed.setMode(.decal) } label: {
                    Text("贴花").chipBG(ed.mode == .decal)
                }
                .buttonStyle(.plain)
                Button { ed.saveToAlbum() } label: {
                    Text(ed.busy ? "…" : "保存")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(red: 0.016, green: 0.133, blue: 0.165))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(cAccent).clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .disabled(ed.busy)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(cPanel)
        .disabled(ed.busy)      // 解码/导出中别改参数，后台读的是同一份状态
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>,
                        fmt: @escaping (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(cDim)
                Spacer(minLength: 0)
                Text(fmt(value.wrappedValue)).foregroundStyle(.white)
            }
            .font(.system(size: 11))
            Slider(value: value, in: range)
        }
        .frame(maxWidth: .infinity)
    }

    /// 参数改动后重绘（几何只在拖中心时变，滑块只影响 uniform）
    private func pbind(_ path: ReferenceWritableKeyPath<Editor, Double>) -> Binding<Double> {
        Binding(get: { ed[keyPath: path] },
                set: { ed[keyPath: path] = $0; ed.invalidate() })
    }

    // ---------------------------------------------------------------- 选图 / 拍照

    private func openCamera() {
        // 模拟器、iPad 无相机、家长控制禁用相机时 isSourceTypeAvailable 为 false
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            ed.toast = "这台设备没有可用相机"
            return
        }
        showCamera = true
    }

    private func load(_ item: PhotosPickerItem?, isPhoto: Bool) {
        guard let item else { return }
        Task { @MainActor in
            if let data = try? await item.loadTransferable(type: Data.self) {
                if isPhoto { ed.setPhoto(data) } else { ed.setDecal(data) }
            } else {
                ed.toast = "这张图片读不出来"
            }
            if isPhoto { photoItem = nil } else { decalItem = nil }
        }
    }

    private func autoHide(_ t: String) {
        guard !t.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if ed.toast == t { ed.toast = "" }
        }
    }
}

// ---------------------------------------------------------------- 手柄叠加

private struct Handles: View {
    let ed: Editor

    var body: some View {
        Canvas { ctx, _ in
            guard ed.hasPhoto, ed.corners.count == 4 else { return }

            var plane = Path()
            for (i, c) in ed.corners.enumerated() {
                let p = ed.toScreen(c)
                if i == 0 { plane.move(to: p) } else { plane.addLine(to: p) }
            }
            plane.closeSubpath()
            ctx.stroke(plane, with: .color(cAccent2.opacity(0.92)), lineWidth: 1.6)

            if ed.mode == .decal {
                let q = ed.decalQuadScreen()
                if q.count == 4 {
                    var p2 = Path()
                    p2.addLines(q)
                    p2.closeSubpath()
                    ctx.stroke(p2, with: .color(.white.opacity(0.85)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }

            for c in ed.corners {
                let p = ed.toScreen(c)
                let r: CGFloat = ed.mode == .corner ? 12 : 8
                let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                let dot = Path(ellipseIn: rect)
                ctx.fill(dot, with: .color(cAccent.opacity(ed.mode == .corner ? 0.95 : 0.42)))
                ctx.stroke(dot, with: .color(.white), lineWidth: 2.2)
            }
        }
    }
}

// ---------------------------------------------------------------- 相机

/// 只为拍一张照片：系统相机、单张、拍完把 JPEG 数据交给 setPhoto。
/// 复用现有的解码链路，EXIF 烘焙和 Vision 自动找平面都不用重写。
private struct CameraPicker: UIViewControllerRepresentable {
    let onData: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.cameraCaptureMode = .photo
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ p: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coord { Coord(onData: onData, close: { dismiss() }) }

    final class Coord: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onData: (Data) -> Void
        private let close: () -> Void

        init(onData: @escaping (Data) -> Void, close: @escaping () -> Void) {
            self.onData = onData
            self.close = close
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            close()
            guard let img = info[.originalImage] as? UIImage else { return }
            // 12MP 的 JPEG 编码在主线程要 100ms 上下，关掉相机的瞬间会顿一下
            DispatchQueue.global(qos: .userInitiated).async {
                guard let d = img.jpegData(compressionQuality: 0.95) else { return }
                DispatchQueue.main.async { self.onData(d) }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { close() }
    }
}

// ---------------------------------------------------------------- 小样式

private extension View {
    /// 空态主按钮
    func primaryBG() -> some View {
        self
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Color(red: 0.016, green: 0.133, blue: 0.165))
            .padding(.horizontal, 26).padding(.vertical, 12)
            .background(cAccent).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    func chipBG(_ on: Bool = false) -> some View {
        self
            .font(.system(size: 13))
            .foregroundStyle(on ? Color(red: 0.561, green: 0.890, blue: 0.949) : Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(on ? Color(red: 0.169, green: 0.231, blue: 0.271) : cChip)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(on ? Color(red: 0.247, green: 0.416, blue: 0.471) : cLine))
    }
}
