import BubblesCore
import CoreGraphics
import Foundation
import Synchronization

/// The soap-bubble film (story 50): a port of the approved prototype `soap-bubble-lab.html`
/// (`film`, `thickness`, `band`, `drawBubble`) at its "Iridescence" 70 / "Film thickness" 50.
///
/// The film is drawn into a small bitmap in the bubble's own space — unsquashed and unrotated, in units
/// of the radius — and Core Animation scales, squashes and spins it with the layer. Everything the
/// prototype strokes (16 rings stepping inward with a conic thin-film colour, the milky sheen, the inner
/// fold, the two glints) depends only on the angle and the depth inside the outline, so it is first
/// summed into a small angle × depth table, then each pixel of the annulus near the edge looks itself up
/// there. Colours add up as in the prototype's `lighter`; the picture's alpha is the brightest channel, so it
/// stays valid premultiplied colour (the window server clamps colour above alpha) and lies over the
/// wallpaper like a light, screen-like veil. The centre stays clear.
enum SoapFilm {
    /// One film picture: `image` covers the square of half-side `extent · radius` around the centre.
    struct Picture {
        let image: CGImage
        let extent: CGFloat
    }

    struct Input {
        var radius: CGFloat          // points
        var phase: Double
        var time: Double
        var roundness: Double
        var tint: GlassTint
        /// The layer's spin: glints are placed at `screen angle − rotation` so they stay top-left.
        var rotation: Double
        /// The window's colour space: a picture already in it is not converted again by Core Animation.
        var colorSpace: CGColorSpace? = nil
    }

    // Prototype sliders at the approved values.
    private static let iridescence = 0.70
    private static let rimSlider = 0.50
    private static let rimMax = 0.05 + rimSlider * 0.16                   // of the radius
    private static let layers = 16
    private static let saturation = 0.35 + iridescence * 0.65
    private static let iriAlpha = 0.3 + iridescence * 0.7

    private static let angleColumns = 48
    private static let radiusSamples = 128
    private static let depthStep = 0.008                                   // of the radius per table row
    private static let depthLow = -0.06

    // MARK: - Prototype functions

    /// Thin-film interference: thickness → pastel rainbow (magenta, gold, cyan, violet).
    static func film(_ thickness: Double) -> (Double, Double, Double) {
        let k = thickness * 2 * .pi
        let mix = 1 - saturation
        return ((0.5 + 0.5 * cos(k)) * saturation + mix,
                (0.5 + 0.5 * cos(k - 2.1)) * saturation + mix,
                (0.5 + 0.5 * cos(k - 4.2)) * saturation + mix)
    }

    /// Large soft colour zones: low harmonics only, slow drift.
    static func thickness(angle a: Double, time t: Double, phase ph: Double, layer: Double) -> Double {
        0.45 * sin(a + t * 0.25 + ph) + 0.25 * sin(a * 2 - t * 0.35 + ph * 2) + layer * 0.035 + t * 0.03
    }

    /// How thick the film band is at an angle: thick on one side, almost gone on the other.
    static func band(angle a: Double, time t: Double, phase ph: Double) -> Double {
        max(0.15, 0.55 + 0.45 * sin(a + 2.4 + ph + t * 0.15) + 0.25 * sin(a * 3 - t * 0.3 + ph))
    }

    // MARK: - Rendering

    static func render(_ input: Input) -> Picture? {
        let r = max(4, Double(input.radius))
        let ph = input.phase, t = input.time
        // Tint: the film's rainbow is pulled toward the chosen colour (multiplying a pastel rainbow by a
        // light tint changed almost nothing). "Clear" keeps the plain rainbow.
        let tintMix = input.tint == .clear ? 0.0 : 0.6
        let tintRGB = (input.tint.rgb.r, input.tint.rgb.g, input.tint.rgb.b)
        func tinted(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
            (c.0 + (tintRGB.0 - c.0) * tintMix, c.1 + (tintRGB.1 - c.1) * tintMix, c.2 + (tintRGB.2 - c.2) * tintMix)
        }

        // Outline (and the inner fold membrane) as radial factors around the circle.
        let nR = radiusSamples
        var outline = [Double](repeating: 1, count: nR)
        for i in 0..<nR {
            outline[i] = BlobGeometry.radius(at: Double(i) / Double(nR) * 2 * .pi, phase: ph, time: t,
                                             roundness: input.roundness)
        }
        let fold = BlobGeometry.foldStrength(roundness: input.roundness)
        let minF = outline.min() ?? 1, maxF = outline.max() ?? 1

        // Depth table: rows from just outside the edge to past the deepest stroke.
        let depthHigh = 0.34
        let nD = Int(((depthHigh - depthLow) / depthStep).rounded(.up)) + 1
        let nA = angleColumns
        var table = [Float](repeating: 0, count: nA * nD * 3)

        let blur = max(1, r * 0.012) / r
        func profile(_ x: Double, width: Double, sigma: Double) -> Double {
            let s = sigma * 2.squareRoot()
            return 0.5 * (ErfTable.value((x + width / 2) / s) - ErfTable.value((x - width / 2) / s))
        }
        let glints: [(angle: Double, length: Double, width: Double, alpha: Double)] = [
            (2.3, 0.7, max(2, r * 0.035) / r, 0.32),      // soft window reflection, top-left
            (-0.75, 0.25, max(1.5, r * 0.018) / r, 0.22), // small one, bottom-right
        ]

        table.withUnsafeMutableBufferPointer { table in
        func stroke(column j: Int, center c: Double, width w: Double, sigma: Double,
                    color: (Double, Double, Double), alpha: Double, tint: Bool = true) {
            guard alpha > 0.002 else { return }
            let reach = w / 2 + 3 * sigma
            let lo = max(0, Int(((c - reach - depthLow) / depthStep).rounded(.down)))
            let hi = min(nD - 1, Int(((c + reach - depthLow) / depthStep).rounded(.up)))
            guard lo <= hi else { return }
            let tc = tint ? tinted(color) : color
            let cr = tc.0 * alpha, cg = tc.1 * alpha, cb = tc.2 * alpha
            for row in lo...hi {
                let d = depthLow + Double(row) * depthStep
                let p = profile(d - c, width: w, sigma: sigma)
                guard p > 0.001 else { continue }
                let k = (j * nD + row) * 3
                table[k] += Float(cr * p)
                table[k + 1] += Float(cg * p)
                table[k + 2] += Float(cb * p)
            }
        }

        for j in 0..<nA {
            let a = Double(j) / Double(nA) * 2 * .pi
            let w = band(angle: a, time: t, phase: ph)
            let edge = sample(outline, angle: a)
            // Film: rings stepping inward, thick on one side, thin on the other, softly blurred.
            let ringAlpha = (0.10 + 0.62 * w * w) * iriAlpha
            for layer in 0..<layers {
                let f = Double(layer) / Double(layers)
                stroke(column: j, center: f * rimMax * w * 1.8, width: rimMax / Double(layers) * 3.2, sigma: blur,
                       color: film(thickness(angle: a, time: t, phase: ph, layer: Double(layer))),
                       alpha: pow(1 - f, 1.6) * ringAlpha)
            }
            // Milky sheen inside the thick part of the film.
            stroke(column: j, center: rimMax * w * 0.9, width: rimMax * 1.4, sigma: blur,
                   color: film(thickness(angle: a, time: t, phase: ph, layer: 2)), alpha: 0.16 * w)
            // Specular glints: blurred arcs just inside the film, fixed on screen.
            for g in glints {
                var delta = (a - (g.angle - input.rotation)).truncatingRemainder(dividingBy: 2 * .pi)
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                let sigma = g.width * 0.6
                let along = profile(delta * edge, width: g.length * edge + g.width, sigma: sigma)
                stroke(column: j, center: rimMax * 1.1, width: g.width, sigma: sigma,
                       color: (1, 1, 1), alpha: g.alpha * along, tint: false)
            }
        }
        }

        // Inner fold: a faint second membrane when the shape is chaotic. Its depth changes fast with the
        // angle, so it is drawn per pixel from its own fine table rather than through the coarse one.
        var foldDepth = [Float](repeating: 0, count: nR)
        var foldColor = [Float](repeating: 0, count: nR * 3)
        if fold > 0 {
            for i in 0..<nR {
                let a = Double(i) / Double(nR) * 2 * .pi
                let vis = max(0, sin(a + ph + t * 0.2)) * fold
                guard vis >= 0.02 else { continue }
                let inner = 0.86 * BlobGeometry.radius(at: a, phase: ph + 1.7, time: t * 1.2, roundness: input.roundness)
                // Keep the fold inside the bubble: where the inner membrane would poke out past the
                // outline it drew a second loop outside the bubble.
                foldDepth[i] = Float(max(0.04, outline[i] - inner))
                let c = tinted(film(thickness(angle: a, time: t, phase: ph, layer: 3) + 0.3))
                foldColor[i * 3] = Float(c.0 * vis)
                foldColor[i * 3 + 1] = Float(c.1 * vis)
                foldColor[i * 3 + 2] = Float(c.2 * vis)
            }
        }
        let foldWidth = Float(rimMax * 0.5)
        let foldSigma = Float(max(0.6 / r, 0.004) * 2.squareRoot())

        // Pixels: about one per 1.8 pt (about the blur), between 40 and 80 per radius.
        // The size is rounded up to a multiple of 8 so the few sizes in use share their polar grids.
        let perRadius = min(80, max(min(40, 2 * r), r / 1.8))
        let size = max(16, min(440, Int((2 * (maxF - depthLow + 0.02) * perRadius / 8).rounded(.up)) * 8))
        let extent = Double(size) / (2 * perRadius)
        let du = Float(2 * extent / Double(size))
        let grid = PolarGrid.make(size)
        var innermost = minF - depthHigh
        for i in 0..<nR where foldColor[i * 3] + foldColor[i * 3 + 1] + foldColor[i * 3 + 2] > 0 {
            innermost = min(innermost, outline[i] - Double(foldDepth[i]) - rimMax)
        }
        let innerLimit = Float(max(0, innermost)) / du, outerLimit = Float(maxF - depthLow) / du
        let lowD = Float(depthLow), highD = Float(depthHigh), step = Float(depthStep)
        let nRf = Float(nR), nAf = Float(nA)
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let outlineF = outline.map(Float.init)

        table.withUnsafeBufferPointer { tab in
        outlineF.withUnsafeBufferPointer { edge in
        foldDepth.withUnsafeBufferPointer { fdepth in
        foldColor.withUnsafeBufferPointer { fcolor in
        grid.angle.withUnsafeBufferPointer { angle in
        grid.rho.withUnsafeBufferPointer { rho in
        pixels.withUnsafeMutableBufferPointer { out in
            for i in 0..<(size * size) {
                let rp = rho[i]
                guard rp < outerLimit, rp > innerLimit else { continue }
                let turn = angle[i]                                   // 0..<1 of the full turn
                let fr = turn * nRf
                let i0 = Int(fr) % nR, i1 = (i0 + 1) % nR
                let wr = fr - Float(Int(fr))
                let d = edge[i0] * (1 - wr) + edge[i1] * wr - rp * du
                var red: Float = 0, green: Float = 0, blue: Float = 0
                if fold > 0 {
                    let x = d - (fdepth[i0] * (1 - wr) + fdepth[i1] * wr)
                    if abs(x) < foldWidth {
                        let p = Float(0.5 * (ErfTable.value(Double((x + foldWidth / 2) / foldSigma))
                                             - ErfTable.value(Double((x - foldWidth / 2) / foldSigma))))
                        red = (fcolor[i0 * 3] * (1 - wr) + fcolor[i1 * 3] * wr) * p
                        green = (fcolor[i0 * 3 + 1] * (1 - wr) + fcolor[i1 * 3 + 1] * wr) * p
                        blue = (fcolor[i0 * 3 + 2] * (1 - wr) + fcolor[i1 * 3 + 2] * wr) * p
                    }
                }
                if d > lowD, d < highD {
                // Bilinear lookup in the angle × depth table.
                let fa = turn * nAf
                let ja = Int(fa) % nA, jb = (ja + 1) % nA
                let wa = fa - Float(Int(fa))
                let fd = (d - lowD) / step
                let ra = min(nD - 2, Int(fd))
                let wd = fd - Float(ra)
                let k00 = (ja * nD + ra) * 3, k01 = k00 + 3, k10 = (jb * nD + ra) * 3, k11 = k10 + 3
                let w00 = (1 - wa) * (1 - wd), w01 = (1 - wa) * wd, w10 = wa * (1 - wd), w11 = wa * wd
                red += tab[k00] * w00 + tab[k01] * w01 + tab[k10] * w10 + tab[k11] * w11
                green += tab[k00 + 1] * w00 + tab[k01 + 1] * w01 + tab[k10 + 1] * w10 + tab[k11 + 1] * w11
                blue += tab[k00 + 2] * w00 + tab[k01 + 2] * w01 + tab[k10 + 2] * w10 + tab[k11 + 2] * w11
                }
                guard red + green + blue > 0 else { continue }
                red = min(1, red); green = min(1, green); blue = min(1, blue)
                let alpha = max(red, green, blue)
                // BGRA, premultiplied.
                let k = i * 4
                out[k] = UInt8(blue * 255)
                out[k + 1] = UInt8(green * 255)
                out[k + 2] = UInt8(red * 255)
                out[k + 3] = UInt8(alpha * 255)
            }
        }}}}}}}

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: size * 4, space: input.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                           | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return Picture(image: image, extent: CGFloat(extent))
    }

    /// Linear interpolation in a table of radial factors spaced evenly over the full turn.
    private static func sample(_ values: [Double], angle: Double) -> Double {
        let n = values.count
        var f = angle / (2 * .pi) * Double(n)
        f -= (f / Double(n)).rounded(.down) * Double(n)
        let i = Int(f) % n
        let w = f - Double(Int(f))
        return values[i] * (1 - w) + values[(i + 1) % n] * w
    }
}

/// Angle (as a fraction of the turn, counter-clockwise from +x, y-up) and distance from the centre (in
/// pixels) of every pixel of a square picture, row 0 at the top. Shared by all bubbles of the same size.
private struct PolarGrid: Sendable {
    let angle: [Float]
    let rho: [Float]

    private static let cache = Mutex<[Int: PolarGrid]>([:])

    static func make(_ size: Int) -> PolarGrid {
        if let grid = cache.withLock({ $0[size] }) { return grid }
        var angle = [Float](repeating: 0, count: size * size)
        var rho = [Float](repeating: 0, count: size * size)
        let half = Double(size) / 2
        for row in 0..<size {
            let y = half - (Double(row) + 0.5)
            for col in 0..<size {
                let x = (Double(col) + 0.5) - half
                var a = atan2(y, x) / (2 * .pi)
                if a < 0 { a += 1 }
                angle[row * size + col] = Float(min(a, 0.999_999))
                rho[row * size + col] = Float((x * x + y * y).squareRoot())
            }
        }
        let grid = PolarGrid(angle: angle, rho: rho)
        cache.withLock { cache in
            if cache.count > 64 { cache.removeAll() }
            cache[size] = grid
        }
        return grid
    }
}

/// `erf` from a table: the film needs tens of thousands of blurred-stroke profiles per picture.
private enum ErfTable {
    static let limit = 3.5
    static let count = 1024
    static let values: [Double] = (0...count).map { erf(-limit + 2 * limit * Double($0) / Double(count)) }

    static func value(_ x: Double) -> Double {
        if x <= -limit { return -1 }
        if x >= limit { return 1 }
        let f = (x + limit) / (2 * limit) * Double(count)
        let i = min(count - 1, Int(f))
        let w = f - Double(i)
        return values[i] * (1 - w) + values[i + 1] * w
    }
}
