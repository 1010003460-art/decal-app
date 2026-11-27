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

    private func saveShot(_ name: String) {
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
    }
}
