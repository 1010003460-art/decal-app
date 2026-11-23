# 贴花 · iOS 原生版

把贴纸贴到照片里的平面（墙、海报、包装）上。**先展平再贴、贴完映射回原图**，
所以转角撕裂这类问题从根上不存在。

## 三步流程

1. 选照片 → Vision 自动找出画面里最大的矩形
2. CoreImage 把那个四边形透视展平成正视图
3. 在正视图上拖贴纸 → 反向变换贴回原图 → 存相册 / 分享

## 在 Mac 上跑

```bash
brew install xcodegen
cd ios_decal
xcodegen generate
open Decal.xcodeproj      # 选自己的 iPhone，Run
```

首次运行需要在 Xcode 的 Signing & Capabilities 里选你的 Apple ID 团队
（Bundle ID `com.wancai.decal` 可能被别人占用，改成 `com.你的名字.decal`）。

## 只有 Windows：靠 CI 编译

```bash
git init && git add -A && git commit -m "init"
git remote add origin git@github.com:你的账号/你的仓库.git
git push -u origin main
```

Actions 会自动跑，约 5-8 分钟：
- 通过 → Artifacts 里下载 `Decal-unsigned-ipa`
- 失败 → 点进日志看 `xcodebuild` 那一步的报错，贴给我

拿到 `.ipa` 后用 [Sideloadly](https://sideloadly.io) 重签装到自己手机
（填自己的 Apple ID，免费账号 7 天有效）。

## 验证

```bash
node verify_homography.mjs      # 单应矩阵数学：6 项，全过才算数
```

Swift 里另有一道运行时自检：Debug 构建启动时 `assert(Homography.selfCheck())`。

## 已知限制（如实说明）

| 项 | 现状 |
|---|---|
| Swift 代码是否编得过 | **未验证**。本机是 Windows，没有 Swift/iOS SDK。首次 CI 大概率要修几处编译错误 |
| Vision 角点顺序 | 按文档 TL/TR/BL/BR 写的，但 `CIPerspectiveCorrection` 的实际接受顺序要真机看一眼 |
| 曲面（瓶子、人脸） | 阶段 1 不支持。Vision 只认矩形，曲面要靠 MoGe-2 CoreML（已有现成 184MB 包） |
| 半透明贴纸边缘 | 展平图整块重投影，边缘会有一次重采样（视觉损失极小） |
| 性能 | 反变换是纯 Swift 逐像素，200 万像素约 0.3-1 秒，只在最终导出跑一次 |
