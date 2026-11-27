import Photos
import SwiftUI
import UIKit
import WebKit

// ============================================================================
// 贴花 App 的 iOS 外壳
//
// 渲染全部在 decal.html 里（WebGL2 一片全屏着色器，四点单应逆采样）。
// 这里只做两件事：把本地页面装进 WKWebView，以及把导出的图片写进相册。
//
// 为什么不是原生 Metal：
//   · 平面贴花是纯 2D 单应问题，数学上精确，没有 3D 需要写
//   · 同一份 shader 以后直接跑安卓，不用重写第二套
//   · 页面能在本机用真实照片逐像素验证（已与 numpy 独立实现比对到 0.49/255）
// 代价：上架时会碰到 App Store 4.2（最低功能）审核风险，自用不受影响。
// ============================================================================

struct ContentView: View {
    var body: some View {
        WebShell()
            .ignoresSafeArea(edges: .bottom)
            .background(Color(red: 0.067, green: 0.075, blue: 0.086))
    }
}

struct WebShell: UIViewRepresentable {
    func makeCoordinator() -> Bridge { Bridge() }

    func makeUIView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        conf.allowsInlineMediaPlayback = true
        conf.userContentController.add(context.coordinator, name: "save")

        let wv = WKWebView(frame: .zero, configuration: conf)
        wv.isOpaque = false
        wv.backgroundColor = UIColor(red: 0.067, green: 0.075, blue: 0.086, alpha: 1)
        wv.scrollView.bounces = false
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.allowsBackForwardNavigationGestures = false

        if let url = Bundle.main.url(forResource: "decal", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            let html = """
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <div style="font:16px -apple-system;color:#eee;padding:40px;line-height:1.7">
              没找到 decal.html<br><span style="color:#888">检查 Xcode 里这个文件是否在 Copy Bundle Resources 中</span>
            </div>
            """
            wv.loadHTMLString(html, baseURL: nil)
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - JS → 原生：存相册

final class Bridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        guard message.name == "save",
              let body = message.body as? [String: Any],
              let dataURL = body["dataURL"] as? String,
              let comma = dataURL.firstIndex(of: ",") else { return }

        let b64 = String(dataURL[dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let image = UIImage(data: data) else {
            reply(message.webView, "图片解码失败")
            return
        }

        let ms = (body["ms"] as? Int).map { " · \($0)ms" } ?? ""

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.reply(message.webView, "没有相册写入权限，去「设置 → 贴花」里打开")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { ok, err in
                if ok {
                    self.reply(message.webView, "已存入相册" + ms)
                } else {
                    self.reply(message.webView, err?.localizedDescription ?? "保存失败")
                }
            }
        }
    }

    /// 回一句提示给页面里的 toast，不然 iOS 上是"点了没反应"
    private func reply(_ webView: WKWebView?, _ text: String) {
        DispatchQueue.main.async {
            let esc = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: " ")
            webView?.evaluateJavaScript(
                "window.__nativeResult && window.__nativeResult('\(esc)')",
                completionHandler: nil)
        }
    }
}

#Preview {
    ContentView()
}
