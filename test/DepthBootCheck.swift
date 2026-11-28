// DepthModel 的 boot check：不启模拟器，几秒钟把整条推理链路验一遍。
//
// 为什么要这一步：模型能不能加载、输出到底是不是 518×392、值域对不对、
// 模型认不认得出圆柱曲率 —— 这些都不需要 UI。放进模拟器 UI 测试要 7 分钟，
// 失败了还分不清是模型错还是渲染错。这里先在命令行把「模型层」钉死。
//
// 用法（CI 里跑）：
//   swiftc -O Decal/DepthModel.swift test/DepthBootCheck.swift -o /tmp/dchk && /tmp/dchk
// 环境变量：
//   DEPTH_MODEL  编译好的 .mlmodelc 路径，默认 Model/DepthAnythingV2SmallF16.mlmodelc
//   DECAL_ROOT   仓库根，默认当前目录

import CoreGraphics
import Foundation
import ImageIO

var failures = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        print("  ✓ \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
    } else {
        print("  ✗ \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        failures += 1
    }
}

func loadImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

let root = ProcessInfo.processInfo.environment["DECAL_ROOT"] ?? "."
let modelPath = ProcessInfo.processInfo.environment["DEPTH_MODEL"]
    ?? "Model/DepthAnythingV2SmallF16.mlmodelc"

print("=== depth model boot check ===")
print("model: \(modelPath)")

// ---------------------------------------------------------------- 1. 加载

let t0 = CFAbsoluteTimeGetCurrent()
guard let dm = DepthModel(compiledURL: URL(fileURLWithPath: modelPath)) else {
    print("  ✗ 模型加载失败 —— CI 里先跑 coremlcompiler compile")
    exit(1)
}
let loadMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000
check("模型能加载", dm.isAvailable, String(format: "%.0fms", loadMS))

// ---------------------------------------------------------------- 2. 推理

guard let cg = loadImage("\(root)/test/bottle.png") else {
    print("  ✗ 找不到 test/bottle.png（确认 .gitignore 里有 !test/bottle.png 例外）")
    exit(1)
}
print("输入照片 \(cg.width)×\(cg.height)")

let t1 = CFAbsoluteTimeGetCurrent()
guard let d = dm.infer(cg) else {
    print("  ✗ 推理失败 —— 输出既不是 MLMultiArray 也读不成 image buffer")
    exit(1)
}
let inferMS = (CFAbsoluteTimeGetCurrent() - t1) * 1000
check("推理出结果", true, String(format: "%.0fms  %d×%d", inferMS, d.width, d.height))

check("输出尺寸 = 518×392", d.width == 518 && d.height == 392,
      "\(d.width)×\(d.height)")

let mn = d.values.min() ?? 0, mx = d.values.max() ?? 0
check("值域落在 0..1", mn >= -0.02 && mx <= 1.02,
      String(format: "%.3f..%.3f", mn, mx))
check("不是常数图（否则等于没算出深度）", mx - mn > 0.05,
      String(format: "跨度 %.3f", mx - mn))

// ---------------------------------------------------------------- 3. 模型认不认得出曲率

// 瓶身横向剖面：圆柱的曲率就在这一行的起伏里。跨度太小 → 弧长积分没有输入，
// 下一轮的「扭曲感」会整条落空。
let rowY = Int(Double(d.height) * 0.62)
let x0 = Int(Double(d.width) * 0.15), x1 = Int(Double(d.width) * 0.85)
var rowMin = Float.greatestFiniteMagnitude, rowMax = -Float.greatestFiniteMagnitude
for x in x0...x1 {
    let v = d.at(x: x, y: rowY)
    rowMin = min(rowMin, v); rowMax = max(rowMax, v)
}
let span = rowMax - rowMin
check("瓶身横向深度跨度 >= 0.15", span >= 0.15,
      String(format: "y=%d  x=%d..%d  %.3f..%.3f 跨度 %.3f", rowY, x0, x1, rowMin, rowMax, span))

// 前景该比背景近。这条挡的是「整张图反相」这种低级错 —— 反相之后
// 背景比瓶子亮，弧长积分会把贴花往反方向扯，肉眼看是一团糊。
let bg = d.at(x: Int(Double(d.width) * 0.03), y: rowY)
let fg = d.at(x: Int(Double(d.width) * 0.50), y: rowY)
check("前景比背景近", fg > bg + 0.15,
      String(format: "瓶身 %.3f vs 背景 %.3f", fg, bg))

// ---------------------------------------------------------------- 4. 汇总

print("")
if failures == 0 {
    print("全部通过")
    exit(0)
} else {
    print("\(failures) 项失败")
    exit(1)
}
