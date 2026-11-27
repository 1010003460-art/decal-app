import CoreGraphics
import simd

// ============================================================================
// 3×3 行主序矩阵
//
// 刻意不用 simd_double3x3：simd 的下标是「列」，而这里所有公式都是照着
// Web 版 JS 的行主序写的（m[0..2] 是第一行）。数组布局两边一字不差，
// 出问题时可以直接对行比对数值，不用在脑子里做转置。
// ============================================================================

struct Mat3 {
    /// [h0 h1 h2 | h3 h4 h5 | h6 h7 h8]
    var m: [Double]

    init(_ m: [Double]) { self.m = m }

    static let identity = Mat3([1, 0, 0, 0, 1, 0, 0, 0, 1])

    func map(_ x: Double, _ y: Double) -> CGPoint? {
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) >= 1e-12 else { return nil }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w,
                       y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    var inverse: Mat3? {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]
        let A = e * i - f * h, B = f * g - d * i, C = d * h - e * g
        let det = a * A + b * B + c * C
        guard abs(det) >= 1e-12 else { return nil }
        return Mat3([
            A / det, (c * h - b * i) / det, (b * f - c * e) / det,
            B / det, (a * i - c * g) / det, (c * d - a * f) / det,
            C / det, (b * g - a * h) / det, (a * e - b * d) / det,
        ])
    }

    /// 行主序 → MSL 的 float3x3（simd 按列存，rows: 初始化器负责转置）
    var msl: simd_float3x3 {
        simd_float3x3(rows: [
            SIMD3(Float(m[0]), Float(m[1]), Float(m[2])),
            SIMD3(Float(m[3]), Float(m[4]), Float(m[5])),
            SIMD3(Float(m[6]), Float(m[7]), Float(m[8])),
        ])
    }
}

enum Homography {
    /// 单位方 (0,0)(1,0)(1,1)(0,1) → 四个图像像素点。
    /// 8 未知数 + h8=1，8×8 高斯消元；退化时返回 nil。
    static func solve(_ q: [CGPoint]) -> Mat3? {
        guard q.count == 4 else { return nil }
        let src: [(Double, Double)] = [(0, 0), (1, 0), (1, 1), (0, 1)]

        var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let (x, y) = src[i]
            let u = Double(q[i].x), v = Double(q[i].y)
            a[i * 2]     = [x, y, 1, 0, 0, 0, -u * x, -u * y, u]
            a[i * 2 + 1] = [0, 0, 0, x, y, 1, -v * x, -v * y, v]
        }

        for col in 0..<8 {
            var piv = col
            for r in (col + 1)..<8 where abs(a[r][col]) > abs(a[piv][col]) { piv = r }
            if abs(a[piv][col]) < 1e-12 { return nil }
            if piv != col { a.swapAt(piv, col) }

            let dv = a[col][col]
            for c in col...8 { a[col][c] /= dv }

            for r in 0..<8 where r != col {
                let f = a[r][col]
                if f == 0 { continue }
                for c in col...8 { a[r][c] -= f * a[col][c] }
            }
        }

        var h = (0..<8).map { a[$0][8] }
        h.append(1)
        return Mat3(h)
    }
}
