# 贴花（Decal）

把一张贴纸 / 文字 / logo 贴到照片里的**平面**上，并跟随表面的透视和明暗。

iPhone 原生 App：SwiftUI 界面 + Metal 着色器，无 WebView。自签安装（Sideloadly + 免费 Apple ID，7 天）。

---

## 它是怎么做的

```
照片 + 用户拖的四个角
        ↓
   四点单应矩阵 H（单位方 → 图像四角）        Homography.swift
        ↓
   Depth Anything V2 Small → 相对深度图       DepthModel.swift
        ↓
   逐像素逆采样：屏幕像素 → 图像像素 → 平面 uv → 贴花坐标
        ↓                                    Shaders.metal
   L1 光照融合（低频光照场 + 两端降饱和）+ 接触阴影
        ↓
   一次 draw call 出图；导出时同样的 shader 渲到 4096 内的离屏纹理
```

**平面为什么不需要 3D**：贴花只落在用户指定的平面上，而平面→图像是一个精确的
单应变换，透视缩短由 H 自带，不需要建模。

**曲面为什么必须靠深度**：平面单应等价于**正交投影**。圆柱上的点在屏幕上位置是
`R·sinθ`，而它正交投影到切平面上的坐标也是 `R·sinθ` —— 两者线性相关，所以贴花
在曲面上**永远不变形**，不管单应算得多准。真实贴纸不可拉伸，内容按**弧长** `R·θ`
分布，投影到屏幕后边缘才会被压缩。`sinθ` vs `θ` 就是「贴了张幻灯片」和「贴纸卷上去」
的区别，这个差别平面数学给不出来。

**深度模型现状**：`apple/coreml-depth-anything-v2-small` 已接进 App（49.8MB，
输入 518×392，输出 `depth` 是 **image 类型**不是数组，相对深度 0..1）。
当前只做**推理 + 可视化**（画布上的「深度」开关），弧长扭曲是下一步。

**为什么用 Metal 而不是 Web**：同一套数学，原生能直接吃 CoreML（后面接深度遮挡）、
系统分享、原生手势；也不再依赖 WKWebView 的 60fps 节流与内存上限。

## 目录

```
Decal/
  Shaders.metal       全屏片元着色器（GLSL 的 1:1 翻译）
  Editor.swift        状态 + 几何 + Metal 管线 + 导出（原 decal.html 的 700 行 JS）
  Homography.swift    行主序 Mat3 + 8×8 高斯消元
  ContentView.swift   SwiftUI 面板 + Canvas 手柄 + PhotosPicker
  DepthModel.swift    深度推理（只依赖 CoreML，CI 里能直接编译跑）
  DecalApp.swift      入口
  decal.html          Web 参考实现，**不进包**（旧版 WKWebView 外壳用的，留作对照/将来做安卓）
Model/                深度模型占位目录（.mlmodelc 由 CI 用 coremlcompiler 现编，不入库）
project.yml           XcodeGen 工程描述
test/                 验证脚本（素材与产物已 gitignore）
verify_homography.mjs 单应数学自检（与 Swift 侧同算法）
```

## 已验证的

| 项 | 方法 | 结果 |
|---|---|---|
| 单应矩阵 | `verify_homography.mjs`，6 项 | 四角误差 1.4e-14 px |
| 着色器坐标 | Web 版与 numpy SVD-DLT + CPU 双线性的独立实现逐像素比（`test/ref_check.py`） | 三张真实照片，内部区域最大差 **0.49/255** |
| 拖拽交互 | Web 版真实指针事件（`test/drag.js`） | 拖角 134.2 期望 / 134.0 实际 |
| 导出 | 4096 上限离屏渲染 | Web 版 21ms；原生版待测 |
| 光照层数学 | `test/light_check.py`（纯标准库，进 CI） | 亮度守恒 2e-16、饱和度只降不升、shade=0 完整退化 |
| 光照层视觉 | `test/light_demo.py` 合成侧光砖墙 + 白贴纸 | 旧版白纸上透出砖缝格线（半透明感），新版实心且跟随明暗 |
| 深度模型 | `test/DepthBootCheck.swift`（CI，5 秒，编真源码） | 加载 652ms / 推理 675ms / 518×392 / 值域 0.033..1.000 / 瓶身 0.799 vs 背景 0.059 |
| 深度可视化 | 模拟器 UI 测试 `testDepthPreviewTurnsPhotoGrayscale` | 点「深度」后照片带饱和色比例掉到 <25%，贴花被顶掉 |
| 编译 | GitHub Actions macOS runner | 通过，`default.metallib` 已入包 |

**未验证**：原生版尚未真机跑过（构建机是 Windows，没有模拟器）。
shader 与数学是逐行翻译、Uniforms 布局是手算对齐的 112 字节，但首跑仍可能出现
位置偏移、手势失灵一类问题——报现象即可定位。

## 已知边界（设计边界，不是 bug）

| 边界 | 说明 |
|---|---|
| **只对平面精确** | 曲面（瓶子、人脸）会被当成平面，贴花看起来像"浮在前面的一张硬卡片" |
| **遮挡只认前景实例** | `VNGenerateForegroundInstanceMaskRequest` 能挡人/车/箱子；细小的前景物（管道、桌角）会漏，墙上的海报本身可能被判前景。默认关闭，可一键退回 |
| **光照是低频的** | 贴花跟随 32px 光照场（对 4K 是 128px 粒度），小于这个尺度的光照变化（一条细窄的窗影）不会体现在贴花上 |
| **只处理漫反射** | 玻璃、金属这类高频反射表面，乘法算不出来 |
| **单张静态照片** | 不做实时相机 |

## 构建（不需要 Mac）

GitHub Actions 用 macOS runner 编译，产出未签名 ipa：

```
push → Actions「iOS Build」→ Artifacts「Decal-unsigned-ipa」
```

本地真机安装用 Sideloadly + 免费 Apple ID（7 天有效）。iOS 17 必须先打开
「设置 → 隐私与安全性 → 开发者模式」并重启，否则装了会闪退。

## 许可提醒

后续若接深度模型：MoGe 代码与权重 MIT；Depth-Anything-3 只有 Small / Base 是
Apache-2.0 可商用，Large / Giant 是 CC BY-NC 4.0 禁商用。
