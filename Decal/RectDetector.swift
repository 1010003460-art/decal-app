import CoreGraphics
import Vision

enum RectDetector {
    /// 找图中最像「平面」的矩形。返回四角（CIImage 坐标，y 向上，单位像素），
    /// 顺序 TL, TR, BL, BR；找不到返回 nil。
    static func detect(in cg: CGImage) -> [CGPoint]? {
        let req = VNDetectRectanglesRequest()
        req.maximumObservations = 3
        req.minimumConfidence = 0.5
        req.minimumSize = 0.2
        req.minimumAspectRatio = 0.15
        req.quadratureTolerance = 30
        do {
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        } catch {
            return nil
        }
        guard let obs = (req.results ?? []).first else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * w, y: p.y * h) }
        return [px(obs.topLeft), px(obs.topRight), px(obs.bottomLeft), px(obs.bottomRight)]
    }
}
