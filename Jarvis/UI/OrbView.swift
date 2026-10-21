import AppKit

/// Parçacık küresi: siyah zeminde binlerce beyaz nokta. Boşta nefes alır, kullanıcı konuşurken
/// mikrofon seviyesiyle dalgalanır, Jarvis konuşurken kendi sesiyle nabız atar.
/// Kenar parlaması (ring etkisi) silüete yakın noktaların daha parlak çizilmesinden gelir.
///
/// Saf AppKit (NSView + Core Graphics). Ölçüldü: macOS 27'de çerçevesiz paneldeki NSHostingView,
/// fare olayı gelince SwiftUI hit-test'inde (PointerBridge.mouseMoved) SIGSEGV ile çöküyor;
/// burada SwiftUI yok, tracking area yok, dolayısıyla o yol hiç çalışmıyor.
///
/// Çizim ARKA PLANDA yapılır, ekrana hazır resim konur. Ölçüldü: ana iş parçacığında 60 Hz çizim,
/// her kare 16 ms'den uzun sürünce zamanlayıcı hep "vadesi gelmiş" kalıyor, runloop hiç uyumuyor ve
/// ana kuyruk (MainActor görevleri, izin geri çağrıları) sıra alamıyor; "Dinle" sonrası hiçbir şey olmuyordu.
final class OrbView: NSView {
    struct Sample {
        let phase: AppState.Phase
        let inputLevel: Float
        let outputLevel: Float
    }

    /// Her karede çağrılır; o anki durum ve ses seviyeleri. Arka plan kuyruğundan çağrılır.
    var sample: () -> Sample = { Sample(phase: .off, inputLevel: 0, outputLevel: 0) }

    private let queue = DispatchQueue(label: "jarvis.orb", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var rendering = false
    private let start = Date()
    private let scale: CGFloat = 2

    /// Fibonacci küresi: eşit dağılmış birim vektörler. Bir kez hesaplanır.
    private static let points: [SIMD3<Float>] = {
        let n = 2000
        let golden = Float.pi * (3 - sqrt(5))
        return (0..<n).map { i in
            let y = 1 - (Float(i) / Float(n - 1)) * 2
            let r = sqrt(1 - y * y)
            let a = golden * Float(i)
            return SIMD3(cos(a) * r, y, sin(a) * r)
        }
    }()

    /// Her noktanın kendi dalga fazı; dalgalanma tek parça değil, yüzeyde gezsin diye.
    private static let phases: [Float] = (0..<points.count).map { _ in Float.random(in: 0..<(2 * .pi)) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 28
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.contentsGravity = .resize
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.cancel() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // fare olaylarına hiç karışma

    /// Arka planda bir kare üretir, ana iş parçacığına yalnızca hazır resmi verir.
    private func tick() {
        guard !rendering else { return }   // önceki kare bitmediyse bu kareyi atla
        rendering = true
        let size = bounds.size
        let s = sample()
        let t = Float(Date().timeIntervalSince(start))
        let image = Self.render(size: size, scale: scale, sample: s, t: t)
        DispatchQueue.main.async { [weak self] in
            self?.layer?.contents = image
            self?.rendering = false
        }
    }

    private static func render(size: CGSize, scale: CGFloat, sample s: Sample, t: Float) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)

        // Ne kadar "canlı": dinlerken mikrofon, konuşurken hoparlör, düşünürken hafif sürekli kıpırtı.
        // Renk: dinlerken beyaz, cevap verirken kırmızı, kapalı/bekleme/düşünme durumunda mavi.
        let energy: Float, spin: Float
        let tint: (r: CGFloat, g: CGFloat, b: CGFloat)
        let white: (r: CGFloat, g: CGFloat, b: CGFloat) = (1, 1, 1)
        let red: (r: CGFloat, g: CGFloat, b: CGFloat) = (1, 0.27, 0.23)
        let blue: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.35, 0.6, 1)
        switch s.phase {
        case .off:        energy = 0.06;                     spin = 0.08; tint = blue
        case .standby:    energy = 0.06;                     spin = 0.08; tint = blue
        case .connecting: energy = 0.15;                     spin = 0.3;  tint = blue
        case .listening:  energy = max(s.inputLevel, 0.06);  spin = 0.15; tint = white
        case .thinking:   energy = 0.25;                     spin = 0.9;  tint = blue
        case .speaking:   energy = s.outputLevel;            spin = 0.25; tint = red
        }

        let cx = Float(size.width) / 2, cy = Float(size.height) / 2
        let R = min(cx, cy) * 0.72
        let breath = 1 + 0.03 * sin(t * 1.1)
        let ry = t * spin, rx: Float = 0.35 + 0.1 * sin(t * 0.4)
        let (sy, cy_) = (sin(ry), cos(ry)), (sx, cx_) = (sin(rx), cos(rx))

        // Parlaklık kovaları: binlerce ayrı fill yerine 5 yol, her biri tek fill.
        // Noktalar küçük kare: elips yolundan kat kat ucuz, bu boyutta gözle fark yok.
        let buckets = (0..<5).map { _ in CGMutablePath() }
        let pts = points, ph = phases
        for i in pts.indices {
            var p = pts[i]
            // Yüzey dalgası: ses enerjisiyle büyüyen, noktadan noktaya fazı değişen bozulma.
            let wave = sin(t * 3.2 + ph[i]) * sin(t * 1.7 + p.y * 4 + ph[i] * 0.5)
            let r = breath + energy * 0.42 * wave + 0.015 * sin(t * 2 + ph[i])
            p *= r
            // Y sonra X ekseninde döndür.
            let x1 = p.x * cy_ + p.z * sy, z1 = -p.x * sy + p.z * cy_
            let y2 = p.y * cx_ - z1 * sx, z2 = p.y * sx + z1 * cx_
            // Ortografik izdüşüm; z2 derinlik (+ öne doğru). Bitmap kökeni sol alt, o yüzden y ters değil.
            let px = cx + x1 * R, py = cy + y2 * R
            // Silüete yakınlık: |z| küçükse kenardadır, parlasın (resimdeki halka).
            let rim = 1 - min(abs(z2) / r, 1)
            let depth = (z2 / r + 1) / 2                      // 0 arka, 1 ön
            let bright = 0.08 + 0.55 * rim * rim * rim + 0.25 * depth + energy * 0.3 * max(wave, 0)
            let b = min(Int(bright * 5), 4)
            let sz = CGFloat(1.1 + 1.2 * rim + energy * 1.5 * max(wave, 0))
            buckets[b].addRect(CGRect(x: CGFloat(px) - sz / 2, y: CGFloat(py) - sz / 2, width: sz, height: sz))
        }
        let alphas: [CGFloat] = [0.12, 0.28, 0.5, 0.75, 1]
        for (i, path) in buckets.enumerated() {
            ctx.setFillColor(CGColor(red: tint.r, green: tint.g, blue: tint.b, alpha: alphas[i]))
            ctx.addPath(path)
            ctx.fillPath()
        }

        // Yumuşak dış hale: konuşurken genişler.
        let halo = CGFloat(R * (1.25 + energy * 0.25))
        let haloColor = { (a: CGFloat) in CGColor(red: tint.r, green: tint.g, blue: tint.b, alpha: a) }
        let colors = [haloColor(0), haloColor(0.06 + CGFloat(energy) * 0.12), haloColor(0)] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.6, 1]) {
            ctx.drawRadialGradient(grad, startCenter: CGPoint(x: CGFloat(cx), y: CGFloat(cy)), startRadius: halo * 0.6,
                                   endCenter: CGPoint(x: CGFloat(cx), y: CGFloat(cy)), endRadius: halo, options: [])
        }
        return ctx.makeImage()
    }
}
