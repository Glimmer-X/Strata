import AppKit
import AVFoundation
import ScanCore
import SwiftUI

/// Renders a scripted movie of the window on the made-up disk, frame by frame and without
/// showing anything on screen: the same drawing and movements as the app, run on a clock of
/// its own, with a drawn pointer that moves, hovers and clicks as the script says, a camera
/// that moves over the window, and a backdrop in the colours of the scheme shown.
///
///   Strata --film OUT.mp4 --script FILE.json
///
/// The script (`Film.Script`) gives the movie's size and length, the window, where the
/// pointer is when, what each click does, where the camera looks, and an optional closing card.
@MainActor
enum Film {
    struct Script: Decodable {
        /// The movie, in pixels.
        var size: [Double]
        var fps: Int
        var duration: Double
        /// The window, in points.
        var window: [Double]
        /// Where the camera looks when, eased from one shot to the next.
        var camera: [Shot]
        var theme: String
        var mode: String
        /// Where the pointer is when, eased from one key to the next.
        var pointer: [Key]
        var events: [Event]
        var intro: FilmIntro?
        var card: Card?
        /// Pixels rendered per pixel of the movie before scaling down, for smoother edges.
        var oversample: Double?
    }

    /// A pointer position: window points, a mark on the map ("Library", or "Library/Caches"
    /// for one inside it), or a button in the bar ("bubbles", "flow", "back", a theme id).
    /// Marks and buttons are looked up when the pointer starts moving there.
    struct Key: Decodable {
        var at: Double
        var x: Double?
        var y: Double?
        var over: String?
        var button: String?
        /// Added to the place found, in window points.
        var dx: Double?
        var dy: Double?
    }

    /// The camera: the point of the window (in points) at the middle of the movie, and how
    /// many movie pixels a window point takes.
    struct Shot: Decodable {
        var at: Double
        var x: Double
        var y: Double
        var scale: Double
    }

    struct Event: Decodable {
        var at: Double
        /// "click" (on the map, where the pointer is), "up", "mode", "theme".
        var `do`: String
        var value: String?
    }

    struct Card: Decodable {
        var at: Double
        var lines: [Line]
        /// Where the middle of the text is, from the top, in pixels.
        var centerY: Double
        /// Shows the app's icon above the text.
        var icon: Bool?

        struct Line: Decodable {
            var text: String
            var size: Double
            var weight: String?
            var gap: Double?
            var dim: Bool?
        }
    }

    static func run(_ arguments: [String]) -> Never {
        guard let outIndex = arguments.firstIndex(of: "--film"), outIndex + 1 < arguments.count,
              let scriptIndex = arguments.firstIndex(of: "--script"), scriptIndex + 1 < arguments.count else {
            fail("usage: Strata --film OUT.mp4 --script FILE.json")
        }
        let script: Script
        do {
            script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[scriptIndex + 1])))
        } catch {
            fail("could not read the script: \(error)")
        }
        _ = NSApplication.shared
        do {
            try render(script, to: URL(fileURLWithPath: arguments[outIndex + 1]))
        } catch {
            fail("could not write the movie: \(error)")
        }
        print("wrote \(arguments[outIndex + 1])")
        exit(0)
    }

    // MARK: Rendering

    private static func render(_ script: Script, to url: URL) throws {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var now = start
        let windowSize = CGSize(width: script.window[0], height: script.window[1])

        let model = AppModel(target: .startupDisk, interactive: false)
        model.volumeOverride = DemoDisk.volume
        model.home = DemoDisk.home
        model.present(DemoDisk.tree(scannedAt: Date().addingTimeInterval(-2 * 3600)),
                      mode: MapMode(rawValue: script.mode) ?? .bubbles, theme: Theme.named(script.theme),
                      focus: FileTree.root, mapSize: Metrics.mapSize(inWindow: windowSize))
        model.presentDisks(DemoDisk.disks)
        model.clock = { now }
        model.buildsInline = true
        // With an opening, the map pops up once the window shows.
        model.motion.begin(.popIn, from: nil, at: start.addingTimeInterval(script.intro?.reveal ?? 0))
        let size = CGSize(width: script.size[0], height: script.size[1])
        let intro = script.intro.map { ($0, $0.layout(in: size)) }

        let width = Int(script.size[0]), height = Int(script.size[1])
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 24_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: script.fps,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        var pointer = PointerPath(keys: script.pointer.sorted { $0.at < $1.at })
        pointer.resolve(through: 0) { place(of: $0, model: model, windowSize: windowSize) }
        var pending = script.events.sorted { $0.at < $1.at }[...]
        var clicks: [(at: Double, location: CGPoint)] = []
        var lastMapPoint: CGPoint?? = .none
        var backdrop = Backdrop(theme: model.theme, previous: nil, changed: -1)
        let camera = CameraPath(shots: script.camera.sorted { $0.at < $1.at })
        let frames = Int((script.duration * Double(script.fps)).rounded())

        for frame in 0..<frames {
            let t = Double(frame) / Double(script.fps)
            now = start.addingTimeInterval(t)
            let location = pointer.location(at: t)

            // The pointer first, so a click acts on what it is over.
            let mapPoint = location.flatMap { mapLocation(of: $0, windowSize: windowSize) }
            if lastMapPoint != .some(mapPoint) {
                model.pointerMoved(to: mapPoint)
                lastMapPoint = .some(mapPoint)
            }
            while let event = pending.first, event.at <= t {
                pending.removeFirst()
                if let location { clicks.append((event.at, location)) }
                perform(event, on: model, at: mapPoint)
                lastMapPoint = .none
            }
            _ = model.motion.advance(to: now)
            if model.motion.takeFinished() {
                model.transitionEnded()
                lastMapPoint = .none
            }
            if model.theme != backdrop.theme {
                backdrop = Backdrop(theme: model.theme, previous: backdrop.theme, changed: t)
            }
            // Marks the pointer heads for next are found on the picture shown now.
            pointer.resolve(through: t) { place(of: $0, model: model, windowSize: windowSize) }

            let content = Frame(model: model, script: script, windowSize: windowSize, time: t,
                                shot: camera.shot(at: t), backdrop: backdrop, intro: intro, pointer: location, clicks: clicks)
            let renderer = ImageRenderer(content: content)
            renderer.scale = script.oversample ?? 2
            renderer.isOpaque = true
            guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }

            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            draw(image, into: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(script.fps)))
            if frame % script.fps == 0 { FileHandle.standardError.write(Data("\(Int(t))s ".utf8)) }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        FileHandle.standardError.write(Data("\n".utf8))
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func perform(_ event: Event, on model: AppModel, at mapPoint: CGPoint?) {
        switch event.do {
        case "click":
            if let mapPoint { model.clicked(at: mapPoint) }
        case "up":
            model.goUp()
        case "mode":
            if let mode = event.value.flatMap(MapMode.init(rawValue:)) { model.mode = mode }
        case "theme":
            if let id = event.value { model.theme = Theme.named(id) }
        default:
            fail("unknown event \(event.do)")
        }
    }

    /// Where a pointer key is, in window points.
    private static func place(of key: Key, model: AppModel, windowSize: CGSize) -> CGPoint {
        var point = CGPoint(x: key.x ?? 0, y: key.y ?? 0)
        let bar = Metrics.barHeight / 2
        if let button = key.button {
            let right = windowSize.width
            switch button {
            case "bubbles": point = CGPoint(x: right - 246, y: bar)
            case "flow": point = CGPoint(x: right - 191, y: bar)
            case "back": point = CGPoint(x: Metrics.panelWidth + Metrics.mapInsets.leading + 40, y: bar)
            default:
                guard let index = Theme.all.firstIndex(where: { $0.id == button }) else { fail("no button \(button)") }
                point = CGPoint(x: right - 138 + 24 * Double(index), y: bar)
            }
        } else if let over = key.over {
            guard let center = markCenter(over.split(separator: "/").map(String.init), in: model.scene) else {
                fail("nothing named \(over) on the map at \(key.at)s")
            }
            point = CGPoint(x: center.x + Metrics.panelWidth + Metrics.mapInsets.leading, y: center.y + Metrics.barHeight)
        }
        return CGPoint(x: point.x + (key.dx ?? 0), y: point.y + (key.dy ?? 0))
    }

    /// The middle of a mark, in map coordinates.
    private static func markCenter(_ names: [String], in scene: MapScene?) -> CGPoint? {
        switch scene {
        case nil:
            return nil
        case .bubbles(let scene):
            var candidates = scene.top
            var location: CGPoint?
            for name in names {
                guard let cell = candidates.first(where: { scene.cells[$0].item.title == name }) else { return nil }
                location = scene.cells[cell].center
                candidates = scene.cells[cell].children
            }
            return location
        case .flow(let scene):
            guard let name = names.last, let bar = scene.bars.first(where: { $0.item.title == name }) else { return nil }
            return CGPoint(x: bar.rect.midX, y: bar.rect.midY)
        }
    }

    /// A point of the window in the map's own coordinates, or nil when it is off the map.
    private static func mapLocation(of point: CGPoint, windowSize: CGSize) -> CGPoint? {
        let origin = CGPoint(x: Metrics.panelWidth + Metrics.mapInsets.leading, y: Metrics.barHeight)
        let size = Metrics.mapSize(inWindow: windowSize)
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard local.x >= 0, local.y >= 0, local.x < size.width, local.y < size.height else { return nil }
        return local
    }

    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}

/// Where the pointer is at any moment: eased from one key to the next, held after the last.
private struct PointerPath {
    let keys: [Film.Key]
    private var places: [CGPoint?]

    init(keys: [Film.Key]) {
        self.keys = keys
        places = Array(repeating: nil, count: keys.count)
    }

    /// Finds the place of every key the pointer is at or moving towards by time `t`.
    mutating func resolve(through t: Double, _ place: (Film.Key) -> CGPoint) {
        for index in keys.indices where places[index] == nil {
            let movingThere = index == 0 ? keys[0].at <= t : keys[index - 1].at <= t
            if movingThere { places[index] = place(keys[index]) }
        }
    }

    func location(at t: Double) -> CGPoint? {
        guard let first = keys.first, t >= first.at else { return nil }
        guard let next = keys.firstIndex(where: { $0.at > t }) else { return places.last ?? nil }
        guard let a = places[next - 1], let b = places[next] else { return places[next - 1] ?? nil }
        let x = (t - keys[next - 1].at) / (keys[next].at - keys[next - 1].at)
        let e = x * x * (3 - 2 * x)
        return CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
    }
}

/// The camera at any moment: eased from one shot to the next, held after the last.
private struct CameraPath {
    let shots: [Film.Shot]

    func shot(at t: Double) -> Film.Shot {
        guard let next = shots.firstIndex(where: { $0.at > t }) else { return shots[shots.count - 1] }
        guard next > 0 else { return shots[0] }
        let a = shots[next - 1], b = shots[next]
        let x = (t - a.at) / (b.at - a.at)
        let e = x * x * x * (x * (x * 6 - 15) + 10)
        return Film.Shot(at: t, x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e,
                         scale: a.scale + (b.scale - a.scale) * e)
    }
}

/// The colours behind the window: the scheme shown, fading over from the one before.
private struct Backdrop {
    var theme: Theme
    var previous: Theme?
    /// When the scheme changed, in seconds.
    var changed: Double
}

/// One frame of the movie: the window as the camera sees it, on a backdrop in the scheme's
/// colours, the pointer over it, and the closing card fading in.
private struct Frame: View {
    @ObservedObject var model: AppModel
    let script: Film.Script
    let windowSize: CGSize
    let time: Double
    let shot: Film.Shot
    let backdrop: Backdrop
    let intro: (FilmIntro, FilmIntro.Layout)?
    let pointer: CGPoint?
    let clicks: [(at: Double, location: CGPoint)]

    var body: some View {
        let theme = model.theme
        let size = CGSize(width: script.size[0], height: script.size[1])
        let cardIn = script.card.map { ramp(time - $0.at, 0.6) } ?? 0
        ZStack(alignment: .topLeading) {
            BackdropView(theme: backdrop.previous ?? backdrop.theme, size: size)
            BackdropView(theme: backdrop.theme, size: size)
                .opacity(backdrop.previous == nil ? 1 : ramp(time - backdrop.changed, 0.5))
            window
                .scaleEffect(shot.scale, anchor: .topLeading)
                .offset(x: size.width / 2 - shot.x * shot.scale, y: size.height / 2 - shot.y * shot.scale)
                .opacity(1 - cardIn)
            if let (intro, layout) = intro, time < intro.vanish[1] + 0.5 {
                FilmIntroView(intro: intro, layout: layout, theme: theme, time: time)
            }
            if let card = script.card {
                let textIn = ramp(time - card.at - 0.35, 0.7)
                VStack(spacing: 0) {
                    if card.icon == true, let icon = Bundle.main.image(forResource: "AppIcon") {
                        Image(nsImage: icon).resizable().interpolation(.high)
                            .frame(width: 260, height: 260)
                            .padding(.bottom, 26)
                            .scaleEffect(0.9 + 0.1 * Spring.response(time - card.at - 0.3))
                    }
                    ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.text)
                            .font(.system(size: line.size, weight: line.weight == "semibold" ? .semibold : .regular))
                            .foregroundStyle(line.dim == true ? theme.secondaryText.color : theme.text.color)
                            .padding(.top, line.gap ?? 0)
                    }
                }
                .frame(width: size.width)
                .position(x: size.width / 2, y: card.centerY + 16 * (1 - textIn))
                .opacity(textIn)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private var window: some View {
        WindowFrame(isDark: model.theme.isDark, padded: false) {
            ZStack(alignment: .topLeading) {
                RootView(model: model, live: false)
                    .frame(width: windowSize.width, height: windowSize.height)
                // Until the content appears the window stands empty.
                if let (intro, _) = intro {
                    model.theme.background.color.opacity(1 - ramp(time - intro.reveal, 0.6))
                }
                PointerLayer(pointer: pointer, clicks: clicks, time: time, theme: model.theme)
            }
            .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
            .clipped()
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
    }

    private func ramp(_ x: Double, _ length: Double) -> Double {
        let t = min(max(x / length, 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// A scheme's backdrop: its background colour, deepening downwards, with a soft glow of
/// its first tone behind the window.
private struct BackdropView: View {
    let theme: Theme
    let size: CGSize

    var body: some View {
        let step = theme.isDark ? 1.0 : 0.6
        ZStack {
            LinearGradient(colors: [theme.background.lighter(0.025 * step).color,
                                    theme.background.lighter(-0.07 * step).color],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [theme.tones[0].color.opacity(theme.isDark ? 0.30 : 0.22), .clear],
                           center: UnitPoint(x: 0.5, y: 0.47), startRadius: 0, endRadius: size.height * 0.48)
        }
        .frame(width: size.width, height: size.height)
    }
}

/// The Mac's arrow pointer, and a soft ring where each click happened.
private struct PointerLayer: View {
    let pointer: CGPoint?
    let clicks: [(at: Double, location: CGPoint)]
    let time: Double
    let theme: Theme

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(clicks.enumerated()), id: \.offset) { _, click in
                let age = time - click.at
                if age >= 0, age < 0.45 {
                    let k = age / 0.45
                    Circle()
                        .fill(theme.text.color.opacity(0.22 * (1 - k)))
                        .frame(width: 14 + 30 * k, height: 14 + 30 * k)
                        .position(click.location)
                }
            }
            if let pointer {
                let cursor = NSCursor.arrow
                Image(nsImage: cursor.image)
                    .offset(x: pointer.x - cursor.hotSpot.x, y: pointer.y - cursor.hotSpot.y)
            }
        }
        .allowsHitTesting(false)
    }
}
