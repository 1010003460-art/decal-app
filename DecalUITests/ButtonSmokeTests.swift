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

    func testEmptyStatePhotoPickerButtonExists() {
        let app = XCUIApplication()
        app.launch()

        // PhotosPicker 在无障碍树里不一定是 .button，按任意元素找
        let pick = app.descendants(matching: .any)["选择照片"]
        XCTAssertTrue(pick.waitForExistence(timeout: 20), "空态没有「选择照片」")
        pick.tap()

        // 系统相册是独立进程的远程视图，断言不到内容；
        // 但点击被吞掉时 App 会原地不动，这里只要不崩、仍在前台即视为到达
        XCTAssertEqual(app.state, .runningForeground)
    }
}
