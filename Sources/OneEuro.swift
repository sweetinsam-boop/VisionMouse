import Foundation

/// 1€ filter (Casiez et al.): 저속 정지 시 떨림(Jitter) 제거, 고속 이동 시 지연(Lag) 최소화.
final class OneEuro {
    var minCutoff: Double
    var beta: Double
    private let dCutoff = 1.0
    private var xPrev: Double?
    private var dxPrev = 0.0
    private var tPrev = 0.0

    init(minCutoff: Double = 1.2, beta: Double = 0.015) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    func filter(_ x: Double, t: Double) -> Double {
        guard let xp = xPrev else {
            xPrev = x
            tPrev = t
            return x
        }
        let dt = min(max(t - tPrev, 0.001), 0.1)
        tPrev = t
        let dx = (x - xp) / dt
        let ad = alpha(dCutoff, dt)
        dxPrev = ad * dx + (1.0 - ad) * dxPrev
        let a = alpha(minCutoff + beta * abs(dxPrev), dt)
        let r = a * x + (1.0 - a) * xp
        xPrev = r
        return r
    }

    func reset() {
        xPrev = nil
        dxPrev = 0.0
        tPrev = 0.0
    }
}
