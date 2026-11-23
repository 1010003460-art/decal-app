import CoreGraphics
import Foundation

/// 4 点透视变换（单应矩阵）。坐标一律用「图像像素、y 轴向下」。
struct Homography {
    /// 行主序 9 元素，m[8] 恒为 1
    let m: [Double]

    /// 四点对应求解：src[i] → dst[i]，顺序必须一致（如 TL, TR, BL, BR）
    static func solve(from src: [CGPoint], to dst: [CGPoint]) -> Homography? {
        guard src.count == 4, dst.count == 4 else { return nil }
        // 8 个未知数 h11..h32，放大成 8x9 增广矩阵做高斯消元
        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = Double(src[i].x), y = Double(src[i].y)
            let u = Double(dst[i].x), v = Double(dst[i].y)
            a[i * 2]     = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[i * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }
        for col in 0..<8 {
            var piv = col
            for r in (col + 1)..<8 where abs(a[r][col]) > abs(a[piv][col]) { piv = r }
            guard abs(a[piv][col]) > 1e-12 else { return nil }
            if piv != col { a.swapAt(piv, col) }
            let d = a[col][col]
            for c in col...8 { a[col][c] /= d }
            for r in 0..<8 where r != col {
                let f = a[r][col]
                guard f != 0 else { continue }
                for c in col...8 { a[r][c] -= f * a[col][c] }
            }
        }
        var h = [Double](repeating: 0, count: 9)
        for i in 0..<8 { h[i] = a[i][8] }
        h[8] = 1
        return Homography(m: h)
    }

    func map(_ p: CGPoint) -> CGPoint? {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) > 1e-12 else { return nil }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w,
                       y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    func inverted() -> Homography? {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h
        let B = f * g - d * i
        let C = d * h - e * g
        let det = a * A + b * B + c * C
        guard abs(det) > 1e-12 else { return nil }
        return Homography(m: [
             A / det, (c * h - b * i) / det, (b * f - c * e) / det,
             B / det, (a * i - c * g) / det, (c * d - a * f) / det,
             C / det, (b * g - a * h) / det, (a * e - b * d) / det,
        ])
    }

    /// 往返自检：求解 → 正向映射 → 逆映射，必须回到原点
    static func selfCheck() -> Bool {
        let src = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
                   CGPoint(x: 0, y: 60), CGPoint(x: 100, y: 60)]
        let dst = [CGPoint(x: 12, y: 30), CGPoint(x: 210, y: 18),
                   CGPoint(x: 30, y: 190), CGPoint(x: 240, y: 205)]
        guard let hm = Homography.solve(from: src, to: dst),
              let hi = hm.inverted() else { return false }
        for k in 0..<4 {
            guard let p = hm.map(src[k]), let q = hi.map(p) else { return false }
            if abs(p.x - dst[k].x) > 1e-6 || abs(p.y - dst[k].y) > 1e-6 { return false }
            if abs(q.x - src[k].x) > 1e-6 || abs(q.y - src[k].y) > 1e-6 { return false }
        }
        return true
    }
}
