import XCTest

// ============================================================================
// 空态按钮的可点击性冒烟测试（真机 bug 的回归网）
//
// 背景：`DragGesture(minimumDistance: 0)` 挂在整个画布容器上时，手指一落下就赢下
// 手势竞争、把子视图的点击吞掉，表现是「点了完全没反应」。编译能过、静态检查也发现不了。
//
// 判据：模拟器没有相机 → `openCamera()` 走 guard 分支弹 toast。
// 这句中文出现，就证明点击确实到达了按钮；没出现说明又被上层吞了。
// ============================================================================

final class ButtonSmokeTests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testEmptyStateCameraButtonReceivesTap() {
        let app = XCUIApplication()
        app.launch()

        let cam = app.buttons["拍一张"]
        XCTAssertTrue(cam.waitForExistence(timeout: 20),
                      "空态没渲染出「拍一张」，先确认空态还在、没被别的东西盖住")
        cam.tap()

        let toast = app.staticTexts["这台设备没有可用相机"]
        XCTAssertTrue(toast.waitForExistence(timeout: 4),
                      "点击没有到达按钮 —— 被画布手势吞了（就是这次真机报的问题）")
    }

    func testEmptyStatePhotoPickerOpens() {
        let app = XCUIApplication()
        app.launch()

        // PhotosPicker 在无障碍树里不一定是 .button，按任意元素找
        let pick = app.descendants(matching: .any)["选择照片"]
        XCTAssertTrue(pick.waitForExistence(timeout: 20), "空态没有「选择照片」")
        XCTAssertTrue(pick.isHittable, "「选择照片」在，但点不到（被上层盖住或命中区域不对）")
        pick.tap()

        // 相册弹出来会盖住空态：按钮从「能点」变「不能点」，说明界面真的换了。
        // 点击被吞掉的话它一直 hittable，这条就超时失败。
        let covered = NSPredicate(format: "isHittable == false")
        let e = expectation(for: covered, evaluatedWith: pick, handler: nil)
        wait(for: [e], timeout: 10)
    }

    /// 截图存证：用 -probe-photo 灌一张「左红右蓝 + 顶部白条」的图，把画面传回 CI。
    /// 通道互换会让左半变蓝，行序翻转会让白条跑到底部 —— 看图就能判断，不用再靠描述。
    func testProbePhotoScreenshot() {
        let app = XCUIApplication()
        app.launchArguments = ["-probe-photo", "-probe-decal"]
        app.launch()

        // 有照片才会出现控制栏；等不到也照样截图，正好能看到失败现场
        _ = app.buttons["保存"].waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 3.0)   // 给 Vision 自动找平面留时间
        saveShot("probe-photo")
    }

    /// 对照组：不开遮挡时贴花必须跨过照片中线。
    /// 没有它的话，「橙色全在右半」也可能只是因为贴花本来就偏右，证明不了遮挡生效。
    func testDecalCoversBothHalvesWithoutOcclusion() {
        let app = XCUIApplication()
        app.launchArguments = ["-probe-photo", "-probe-decal"]
        app.launch()

        _ = app.buttons["保存"].waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 3.0)
        let shot = saveShot("no-occlusion")

        guard let cg = shot.image.cgImage else { return XCTFail("截不出图") }
        let (total, left) = Self.countOrange(cg)
        XCTAssertGreaterThan(total, 800, "贴花没画出来")
        let leftRatio = Double(left) / Double(total)
        XCTAssertGreaterThan(leftRatio, 0.3,
                             "不开遮挡时贴花应跨过中线（实际左半 \(Int(leftRatio * 100))%）—— 对照不成立")
    }

    /// 遮挡剔除：合成 mask 左半全黑（挡住）、右半全白（可画）。
    /// 判据是贴花的橙色像素必须几乎全在画面右半边 —— 这是唯一能离线验证
    /// 「逐像素遮挡」的地方（真机的 Vision 分割在模拟器上跑不出来）。
    func testOcclusionCutsDecalInHalf() {
        let app = XCUIApplication()
        app.launchArguments = ["-probe-photo", "-probe-decal", "-probe-occlusion"]
        app.launch()

        _ = app.buttons["保存"].waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 3.0)
        let shot = saveShot("occlusion")

        guard let cg = shot.image.cgImage else { return XCTFail("截不出图") }
        let (total, left) = Self.countOrange(cg)

        XCTAssertGreaterThan(total, 400, "贴花的橙色一个都没找到 —— 贴花根本没画出来，先查这个")
        let leftRatio = Double(left) / Double(total)
        XCTAssertLessThan(leftRatio, 0.08,
                          "左半边还有 \(left)/\(total) 个橙色像素（\(Int(leftRatio * 100))%）—— 遮挡没生效")
    }

    /// 数「贴花橙」像素。贴花探针是 (1, 0.5, 0) 的橙。
    /// 注意 g 的门槛必须抬高：探针照片里的红色经 JPEG 编码后是 (255,39,0)，
    /// 用 g>25 会把整片红底算成橙色（第一版就是这么误判的，实测 77% 假阳性）。
    /// 橙色 g≈132、红底 g≈39，用 g>90 分开；b<80 再挡掉白色条。
    private static func countOrange(_ cg: CGImage) -> (total: Int, left: Int) {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (0, 0)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var total = 0, left = 0
        buf.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in stride(from: 0, to: h, by: 2) {
                for x in stride(from: 0, to: w, by: 2) {
                    let i = (y * w + x) * 4
                    let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                    guard r > 180, g > 90, b < 80, g > b + 60 else { continue }
                    total += 1
                    if x < w / 2 { left += 1 }
                }
            }
        }
        return (total, left)
    }

    /// 深度预览：点「深度」后画面应该从「左红右蓝」变成灰度。
    ///
    /// 判据是**照片区域内的饱和色像素**比例大幅下降 —— 深度图是单通道转出来的灰度，
    /// 任何饱和色都不该剩下。只统计照片所在的横带，避开控制栏那个青色按钮，
    /// 否则「控制栏本来就带色」会把判据冲淡。
    ///
    /// 这条同时是「模型真的打进包了」的证据：模型缺失时 toggleDepth 会弹
    /// 「深度模型没打进包」，画面不变，比例不降。
    func testDepthPreviewTurnsPhotoGrayscale() {
        let app = XCUIApplication()
        app.launchArguments = ["-probe-photo", "-probe-decal"]
        app.launch()

        let depthChip = app.buttons["深度"]
        XCTAssertTrue(depthChip.waitForExistence(timeout: 60),
                      "控制栏没出现，或者「深度」chip 没加上")
        Thread.sleep(forTimeInterval: 8.0)   // 首次要加载 50MB 模型，模拟器上是纯 CPU

        let before = saveShot("depth-off")
        guard let cgBefore = before.image.cgImage else { return XCTFail("截不出图") }
        let (n0, s0) = Self.saturatedInPhotoBand(cgBefore)
        let r0 = n0 > 0 ? Double(s0) / Double(n0) : 0

        depthChip.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let after = saveShot("depth-on")
        guard let cgAfter = after.image.cgImage else { return XCTFail("截不出图") }
        let (n1, s1) = Self.saturatedInPhotoBand(cgAfter)
        let r1 = n1 > 0 ? Double(s1) / Double(n1) : 0

        XCTAssertFalse(app.staticTexts["深度模型没打进包"].exists,
                       "模型没进 bundle —— 检查 CI 里 Compile depth model 那一步")
        XCTAssertGreaterThan(r0, 0.5, "关闭状态的照片区域就该满是红蓝（实际 \(Int(r0 * 100))%），判据本身不成立")
        XCTAssertLessThan(r1, 0.25,
                          "开了深度还有 \(Int(r1 * 100))% 饱和像素（关时 \(Int(r0 * 100))%）—— 深度图没绑上去")
    }

    /// 统计「照片横带」里的高饱和像素占比。
    /// probe 照片是 3:2 横图，在竖屏画布上垂直居中，实际占屏幕高度的 ~28%~58%。
    private static func saturatedInPhotoBand(_ cg: CGImage) -> (total: Int, saturated: Int) {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return (0, 0)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let y0 = Int(Double(h) * 0.25), y1 = Int(Double(h) * 0.58)
        var total = 0, sat = 0
        buf.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in stride(from: y0, to: y1, by: 2) {
                for x in stride(from: 0, to: w, by: 2) {
                    let i = (y * w + x) * 4
                    let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                    total += 1
                    let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                    if mx - mn > 70 { sat += 1 }
                }
            }
        }
        return (total, sat)
    }

    @discardableResult
    private func saveShot(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()

        // 一份进 xcresult（Xcode 里能看），一份写到沙盒 tmp（CI 里直接捞文件）
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("decal-shot-\(name).png")
        try? shot.pngRepresentation.write(to: url)
        print("SHOT_PATH \(url.path)")
        return shot
    }
}
