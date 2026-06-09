import Foundation

/// Renders the classic rotating ASCII torus ("donut.c" by Andy Sloane) used by
/// the welcome splash. Pure math, no dependencies: sample the torus surface,
/// rotate by A (around X) and B (around Z), project with perspective, and pick a
/// brightness character from the surface luminance, with a z-buffer for occlusion.
enum SplashRenderer {
    private static let ramp = Array(".,-~:;=!*#$@")

    // 5×7 bitmap glyphs for the wordmark, spelling E D I T X R.
    private static let glyphs: [[String]] = [
        ["#####", "#....", "#....", "####.", "#....", "#....", "#####"], // E
        ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."], // D
        ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"], // I
        ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."], // T
        ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"], // X
        ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"], // R
    ]

    /// Render the "editxr" wordmark as an extruded 3D slab, gently rotated a
    /// little on each of the Z (roll), Y (yaw) and X (pitch) axes. Shaded by the
    /// letters' own extrusion depth so the whole word stays evenly lit.
    static func wordmark(rx: Double, ry: Double, rz: Double, width: Int, height: Int) -> [String] {
        guard width > 1, height > 1 else { return [] }
        let glyphW = 5, glyphH = 7, gap = 2
        let bw = glyphs.count * glyphW + (glyphs.count - 1) * gap

        // Point cloud: each lit pixel is subdivided into a small filled block
        // (so upscaling never leaves gaps) and extruded across a few depth layers
        // (so the rotation reveals the letters' thickness).
        var pts: [(Double, Double, Double)] = []
        let depth = 0.35
        let sub = [0.0, 0.34, 0.67]
        for (li, g) in glyphs.enumerated() {
            let baseCol = li * (glyphW + gap)
            for (r, rowStr) in g.enumerated() {
                let chars = Array(rowStr)
                for c in 0..<glyphW where chars[c] == "#" {
                    for sx in sub {
                        for sy in sub {
                            let px = Double(baseCol + c) + sx - Double(bw - 1) / 2.0
                            let py = Double(glyphH - 1) / 2.0 - (Double(r) + sy)
                            var z = -depth
                            while z <= depth { pts.append((px, py, z)); z += 0.3 }
                        }
                    }
                }
            }
        }

        var out = Array(repeating: Array(repeating: Character(" "), count: width), count: height)
        var zbuf = Array(repeating: Array(repeating: -Double.infinity, count: width), count: height)

        let cosX = cos(rx), sinX = sin(rx)
        let cosY = cos(ry), sinY = sin(ry)
        let cosZ = cos(rz), sinZ = sin(rz)
        let K2 = 8.0
        // Separate X/Y scales so the text fills both dimensions (terminal cells
        // are ~2:1, so a single scale would squash the 7-row glyphs). Kept small.
        let scaleX = Double(width) * 0.60 * K2 / Double(bw)
        let scaleY = Double(height) * 0.42 * K2 / Double(glyphH)

        for (x0, y0, z0) in pts {
            // Rz (roll) → Ry (yaw) → Rx (pitch).
            let x1 = x0 * cosZ - y0 * sinZ
            let y1 = x0 * sinZ + y0 * cosZ
            let x2 = x1 * cosY + z0 * sinY
            let z2 = -x1 * sinY + z0 * cosY
            let y3 = y1 * cosX - z2 * sinX
            let z3 = y1 * sinX + z2 * cosX
            let ooz = 1.0 / (z3 + K2)

            let xp = Int(Double(width) / 2.0 + scaleX * ooz * x2)
            let yp = Int(Double(height) / 2.0 - scaleY * ooz * y3)

            if xp >= 0, xp < width, yp >= 0, yp < height, ooz > zbuf[yp][xp] {
                zbuf[yp][xp] = ooz
                // Shade by the letter's own extrusion depth (front bright, back
                // dim) — not by the rotated z, so the whole word stays evenly lit
                // and readable regardless of the rock.
                let shade = 0.5 + 0.5 * (depth - z0) / (2 * depth)
                let idx = min(ramp.count - 1, max(0, Int(shade * Double(ramp.count - 1))))
                out[yp][xp] = ramp[idx]
            }
        }
        return out.map { String($0) }
    }

    static func donut(A: Double, B: Double, width: Int, height: Int) -> [String] {
        guard width > 1, height > 1 else { return [] }

        let R1 = 1.0          // tube radius
        let R2 = 2.0          // distance from centre to tube
        let K2 = 5.0          // viewer distance
        // Scale so the donut roughly fills the grid.
        let K1 = Double(width) * K2 * 3.0 / (8.0 * (R1 + R2))

        var out = Array(repeating: Array(repeating: Character(" "), count: width), count: height)
        var zbuf = Array(repeating: Array(repeating: 0.0, count: width), count: height)

        let cosA = cos(A), sinA = sin(A)
        let cosB = cos(B), sinB = sin(B)

        var theta = 0.0
        while theta < 2 * .pi {
            let cosT = cos(theta), sinT = sin(theta)
            var phi = 0.0
            while phi < 2 * .pi {
                let cosP = cos(phi), sinP = sin(phi)
                let circleX = R2 + R1 * cosT
                let circleY = R1 * sinT

                let x = circleX * (cosB * cosP + sinA * sinB * sinP) - circleY * cosA * sinB
                let y = circleX * (sinB * cosP - sinA * cosB * sinP) + circleY * cosA * cosB
                let z = K2 + cosA * circleX * sinP + circleY * sinA
                let ooz = 1.0 / z

                let xp = Int(Double(width) / 2.0 + K1 * ooz * x)
                // Halve the vertical scale: terminal cells are ~twice as tall as wide.
                let yp = Int(Double(height) / 2.0 - K1 * ooz * y * 0.5)

                let lum = cosP * cosT * sinB - cosA * cosT * sinP - sinA * sinT
                    + cosB * (cosA * sinT - cosT * sinA * sinP)

                if lum > 0, xp >= 0, xp < width, yp >= 0, yp < height, ooz > zbuf[yp][xp] {
                    zbuf[yp][xp] = ooz
                    let idx = min(ramp.count - 1, max(0, Int(lum * 8.0)))
                    out[yp][xp] = ramp[idx]
                }
                phi += 0.02
            }
            theta += 0.07
        }
        return out.map { String($0) }
    }
}
