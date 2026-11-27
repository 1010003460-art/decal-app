# 贴花（Decal）

把一张贴纸 / 文字 / logo 贴到照片里的**平面**上，并跟随表面的透视和明暗。

iPhone 用的自签 App。渲染在 `Decal/decal.html`（WebGL2），Swift 只做外壳与存相册。

---

## 它是怎么做的

```
照片 + 用户拖的四个角
        ↓
   四点单应矩阵 H（单位方 → 图像四角）
        ↓
   逐像素逆采样：屏幕像素 → 图像像素 → 平面 uv → 贴花坐标
        ↓
   L1 光照融合（乘表面低频亮度）+ 接触阴影
        ↓
   一次 draw call 出图；导出时同样的 shader 渲染到 4096 内的全分辨率离屏缓冲
```

**为什么不用 3D / 不用深度模型**：贴花只落在用户指定的平面上，而平面→图像是一个
精确的单应变换。没有跨面、没有参数化不连续、没有收边门限，透视缩短由 H 自带。

上一版「Vision 找矩形 → 整块展平 → 把展平图重画回去」之所以看着脏，是因为它把
整块区域重采样了一遍（贴花周围的原图像素也被改），而且 CPU 循环要 3~8 秒。

## 已验证的

| 项 | 方法 | 结果 |
|---|---|---|
| 单应矩阵 | `verify_homography.mjs`，6 项 | 四角误差 1.4e-14 px |
| 着色器坐标 | 与 numpy SVD-DLT + CPU 双线性的独立实现逐像素比（`test/ref_check.py`） | 三张真实照片，内部区域最大差 **0.49/255**（8bit 舍入量级） |
| 拖拽交互 | 真实指针事件（`test/drag.js`） | 拖角 134.2 期望 / 134.0 实际；点空白不误移 |
| 导出 | 4096 上限离屏渲染 + readPixels | 单张约 21ms |

复现：

```bash
python -m http.server 8801 --bind 127.0.0.1      # 在仓库根目录
node test/shoot_png.js && cd test && python ref_check.py
node test/drag.js
```

## 已知边界（设计边界，不是 bug）

| 边界 | 说明 |
|---|---|
| **只对平面精确** | 曲面（瓶子、人脸）会被当成平面，贴花看起来像"浮在前面的一张硬卡片"。这是 2D 单应的定义 |
| **不处理遮挡** | 有人站在墙前面时，贴花会盖到人身上。要修需要深度图（MoGe-2 / Depth-Anything） |
| **只处理漫反射** | 玻璃、金属这类高频反射表面，乘法算不出来 |
| **单张静态照片** | 不做实时相机 |

## 构建（不需要 Mac）

GitHub Actions 用 macOS runner 编译，产出未签名 ipa：

```
push → Actions「iOS Build」→ Artifacts「Decal-unsigned-ipa」
```

本地真机安装用 Sideloadly + 免费 Apple ID（7 天有效）。iOS 17 必须先打开
「设置 → 隐私与安全性 → 开发者模式」并重启，否则装了会闪退。

## 目录

```
Decal/
  decal.html          渲染与交互全部在这里
  ContentView.swift   WKWebView 外壳 + 存相册桥
  DecalApp.swift      入口
project.yml           XcodeGen 工程描述
test/                 验证脚本（素材与产物已 gitignore）
verify_homography.mjs 单应数学自检
```

## 许可提醒

后续若接深度模型：MoGe 代码与权重 MIT；Depth-Anything-3 只有 Small / Base 是
Apache-2.0 可商用，Large / Giant 是 CC BY-NC 4.0 禁商用。
