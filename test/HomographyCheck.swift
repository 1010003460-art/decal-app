// 直接编译 Decal/Homography.swift 跑真实实现，不经过 iOS 模拟器：
//   swiftc -O Decal/Homography.swift test/HomographyCheck.swift -o /tmp/hcheck && /tmp/hcheck
//
// 为什么不用 XCTest：模拟器启动要一分钟，而这里要验的只有纯数学（只依赖 CGPoint），
// macOS 上 swiftc 五秒能跑完。verify_homography.mjs 验的是 JS 参考实现，
// 这个文件验的是真正打进 App 的那份 Swift。

import CoreGraphics
import Foundation

@main
struct HomographyCheck {
    static var fail = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "PASS  " : "FAIL  ") + name + (detail.isEmpty ? "" : "  [\(detail)]"))
        if !ok { fail += 1 }
    }

    static func dist(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y))
    }

    static func main() {
        // 1. 单位方 → 应该是恒等映射
        let unit: [(Double, Double)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
        let unitPts = unit.map { CGPoint(x: $0.0, y: $0.1) }
        if let h = Homography.solve(unitPts) {
            var maxErr = 0.0
            for (x, y) in unit {
                if let p = h.map(x, y) {
                    maxErr = max(maxErr, dist(p, CGPoint(x: x, y: y)))
                }
            }
            check("单位方 → 恒等映射", maxErr < 1e-9, "maxErr=\(String(format: "%.2e", maxErr))")
        } else {
            check("单位方 → 恒等映射", false, "solve 返回 nil")
        }

        // 2. 任意四边形：解出来的矩阵必须把单位方四角精确打到目标四角
        let quad = [CGPoint(x: 40, y: 60), CGPoint(x: 700, y: 25),
                    CGPoint(x: 740, y: 470), CGPoint(x: 10, y: 500)]
        if let h = Homography.solve(quad) {
            var maxErr = 0.0
            for i in 0..<4 {
                guard let p = h.map(unit[i].0, unit[i].1) else { maxErr = .infinity; continue }
                maxErr = max(maxErr, dist(p, quad[i]))
            }
            check("四点 → 四角精确（<1e-9 px）", maxErr < 1e-9,
                  "maxErr=\(String(format: "%.2e", maxErr))")
        } else {
            check("四点 → 四角精确（<1e-9 px）", false, "solve 返回 nil")
        }

        // 3. 中心映射不能跑到四边形外（防翻转/符号错）
        if let h = Homography.solve(quad), let c = h.map(0.5, 0.5) {
            let xs = quad.map { Double($0.x) }, ys = quad.map { Double($0.y) }
            let inside = Double(c.x) > xs.min()! && Double(c.x) < xs.max()!
                      && Double(c.y) > ys.min()! && Double(c.y) < ys.max()!
            check("中心落在四边形包围盒内（无翻转）", inside,
                  "c=(\(String(format: "%.1f", Double(c.x))), \(String(format: "%.1f", Double(c.y))))")
        } else {
            check("中心落在四边形包围盒内（无翻转）", false, "solve/map 返回 nil")
        }

        // 4. 退化输入（三点共线）必须给 nil，而不是垃圾矩阵
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                    CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 0)]
        check("共线四点 → 返回 nil", Homography.solve(line) == nil)

        // 5. 正映射 → 逆映射往返，误差应 < 0.01 px（拖角/拖贴花都靠这条）
        if let h = Homography.solve(quad), let hi = h.inverse {
            var maxErr = 0.0
            for n in 0..<200 {
                let x = Double(n % 20) / 19.0, y = Double(n / 20) / 9.0
                guard let f = h.map(x, y), let b = hi.map(Double(f.x), Double(f.y)) else {
                    maxErr = .infinity; break
                }
                maxErr = max(maxErr, hypot(Double(b.x) - x, Double(b.y) - y))
            }
            check("往返（正→逆）误差 < 1e-6", maxErr < 1e-6,
                  "maxErr=\(String(format: "%.2e", maxErr))")
        } else {
            check("往返（正→逆）误差 < 1e-6", false, "solve/inverse 返回 nil")
        }

        // 6. 已知矩阵的逆：x' = 2x+3, y' = 4y+5 → 逆应为 x=(x'-3)/2, y=(y'-5)/4
        let m = Mat3([2, 0, 3, 0, 4, 5, 0, 0, 1])
        if let inv = m.inverse, let p = inv.map(1, 1) {
            // 2x+3=1 → x=-1；4y+5=1 → y=-1
            let ok = abs(Double(p.x) + 1) < 1e-12 && abs(Double(p.y) + 1) < 1e-12
            check("已知仿射矩阵求逆", ok,
                  "inv(1,1)=(\(String(format: "%.6f", Double(p.x))), \(String(format: "%.6f", Double(p.y))))")
        } else {
            check("已知仿射矩阵求逆", false, "inverse 返回 nil")
        }

        // 7. 奇异矩阵必须返回 nil（否则拖角到共线时会给出 inf 坐标）
        check("奇异矩阵 → inverse 返回 nil",
              Mat3([1, 2, 3, 2, 4, 6, 3, 6, 9]).inverse == nil)

        print(fail == 0 ? "\n全部通过" : "\n\(fail) 项失败")
        exit(fail == 0 ? 0 : 1)
    }
}
