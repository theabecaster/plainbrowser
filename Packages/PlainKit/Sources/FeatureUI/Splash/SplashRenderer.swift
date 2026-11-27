#if canImport(UIKit)
import Metal
import QuartzCore
import Synchronization
import UIKit
import simd

nonisolated struct SplashError: Error, CustomStringConvertible {
    let description: String
}

/// What the dive needs that doesn't depend on the screen's size: device, compiled pipelines, the
/// splash's pictures as textures and the mesh's index buffer. Built once, off the main thread, as
/// the app launches.
///
/// `@unchecked Sendable`: every property is a `let` set in `init`, and the kit then moves from
/// the build queue to the renderer's builder to the render thread, one owner at a time. The
/// textures and index buffer are only read; the Metal device, queue, pipeline and sampler
/// objects are thread-safe.
nonisolated final class SplashKit: @unchecked Sendable {
    static let sampleCount = 4

    let device: MTLDevice
    let queue: MTLCommandQueue
    let sheet: MTLRenderPipelineState
    let hole: MTLRenderPipelineState
    let sheetDepth: MTLDepthStencilState
    let holeDepth: MTLDepthStencilState
    let smooth: MTLSamplerState
    let exact: MTLSamplerState
    let stretch: MTLSamplerState
    let art: SplashArt
    let mark: MTLTexture
    let field: MTLTexture
    let dawn: MTLTexture
    let indices: MTLBuffer
    let indexCount: Int
    /// Library compile plus both pipelines, and the whole build, in seconds.
    let compileTime: CFTimeInterval
    let buildTime: CFTimeInterval

    /// `art` is asked for after the shaders are compiled: the pictures are drawn meanwhile.
    init(art: () -> SplashArt?) throws {
        let start = CACurrentMediaTime()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw SplashError(description: "no Metal device")
        }
        self.device = device
        self.queue = queue

        let library = try device.makeLibrary(source: splashShaderSource, options: nil)
        func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.rasterSampleCount = Self.sampleCount
            d.depthAttachmentPixelFormat = .depth32Float
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: d)
        }
        sheet = try pipeline("sheet_vertex", "sheet_fragment")
        hole = try pipeline("hole_vertex", "hole_fragment")
        compileTime = CACurrentMediaTime() - start

        func depthState(_ compare: MTLCompareFunction, write: Bool) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            guard let s = device.makeDepthStencilState(descriptor: d) else { throw SplashError(description: "no depth state") }
            return s
        }
        // The rolled rim lies over the sheet it came from: nearer wins.
        sheetDepth = try depthState(.less, write: true)
        // Drawn first, under everything.
        holeDepth = try depthState(.always, write: false)

        func sampler(_ filter: MTLSamplerMinMagFilter, _ address: MTLSamplerAddressMode) throws -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter
            d.magFilter = filter
            d.mipFilter = .notMipmapped
            d.sAddressMode = address
            d.tAddressMode = address
            guard let s = device.makeSamplerState(descriptor: d) else { throw SplashError(description: "no sampler") }
            return s
        }
        smooth = try sampler(.linear, .clampToZero)
        exact = try sampler(.nearest, .clampToZero)
        stretch = try sampler(.linear, .clampToEdge)

        guard let art = art() else { throw SplashError(description: "no splash pictures") }
        self.art = art
        func texture(_ bitmap: SplashBitmap) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: bitmap.width, height: bitmap.height, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .shared
            guard let bytes = bitmap.bytes, let texture = device.makeTexture(descriptor: d) else {
                throw SplashError(description: "no texture")
            }
            texture.replace(region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height), mipmapLevel: 0, withBytes: bytes,
                            bytesPerRow: bitmap.bytesPerRow)
            return texture
        }
        mark = try texture(art.mark)
        field = try texture(art.field)
        dawn = try texture(art.view)

        let idx = SplashMesh.indices()
        guard let buffer = device.makeBuffer(bytes: idx, length: idx.count * MemoryLayout<UInt16>.stride, options: .storageModeShared) else {
            throw SplashError(description: "no index buffer")
        }
        indices = buffer
        indexCount = idx.count
        buildTime = CACurrentMediaTime() - start
    }
}

/// Frame timing for the launch log, per drawn frame: the display link's target presentation time
/// (gaps show skipped refreshes), CPU encode time, GPU time, and whether the GPU finished after
/// the frame was due on screen.
nonisolated struct SplashStats: Sendable {
    var targets: [CFTimeInterval] = []
    /// How long before its target each frame's callback ran: what the frame had left.
    var leads: [CFTimeInterval] = []
    var encode: [CFTimeInterval] = []
    var gpu: [CFTimeInterval] = []
    var late = 0
    /// First frame drawn and scheduled (off the main thread), and the swap transaction (main thread).
    var firstFrame: CFTimeInterval = 0
    var swap: CFTimeInterval = 0

    var summary: String {
        func ms(_ v: Double) -> String { String(format: "%.2f", v * 1000) }
        func pct(_ a: [Double], _ q: Double) -> Double {
            guard !a.isEmpty else { return 0 }
            let s = a.sorted()
            return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
        }
        let gaps = zip(targets.dropFirst(), targets).map { $0 - $1 }
        let hist = Dictionary(grouping: gaps) { String(format: "%.1f", $0 * 1000) }
            .sorted { $0.key < $1.key }.map { "\($0.key)ms x\($0.value.count)" }.joined(separator: ", ")
        return "frames \(targets.count); interval p50 \(ms(pct(gaps, 0.5))) p95 \(ms(pct(gaps, 0.95))) "
            + "max \(ms(gaps.max() ?? 0)) ms [\(hist)]; GPU done after due \(late); "
            + "lead p50 \(ms(pct(leads, 0.5))) min \(ms(leads.min() ?? 0)) ms; "
            + "CPU encode p50 \(ms(pct(encode, 0.5))) max \(ms(encode.max() ?? 0)) ms; "
            + "GPU p50 \(ms(pct(gpu, 0.5))) max \(ms(gpu.max() ?? 0)) ms; first frame \(ms(firstFrame)) ms off main, swap \(ms(swap)) ms on main"
    }
}

/// Draws the dive into a `CAMetalLayer` from its own thread, clocked by a `CAMetalDisplayLink`,
/// so main-thread work while the app starts underneath can't stall it. `make` draws the still
/// first frame off the main thread; the main thread presents it in the transaction that hides
/// the Core Animation splash (`presentFirstFrame`), so the swap is atomic; `start()` then hands
/// over to the render thread.
///
/// `@unchecked Sendable`: one thread at a time owns the Metal state: the builder in `make`, the
/// main thread until `start()`, the render thread after it. `cancelled` is atomic and `stats`
/// sits behind a mutex.
nonisolated final class SplashRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    let layer = CAMetalLayer()
    private var kit: SplashKit?
    private let timeline: SplashTimeline
    private let mesh: MTLBuffer
    /// The dive's start on `CACurrentMediaTime()`'s clock, the base of the Core Animation `beginTime`s.
    private let t0: CFTimeInterval
    /// Debug slow motion: 1 is normal speed.
    private let slow: Double
    private var msaa: MTLTexture?
    private var depth: MTLTexture?
    private var link: CAMetalDisplayLink?
    private var running = true
    private var encodeTimes: [CFTimeInterval] = []
    private var targets: [CFTimeInterval] = []
    private var leads: [CFTimeInterval] = []
    private var firstDrawable: CAMetalDrawable?
    private let cancelled = Atomic(false)
    /// Held while a frame is handed to the GPU and while `cancel` marks the renderer stopped
    /// (true): once `cancel` has returned, no frame is committed.
    private let stopped = Mutex(false)
    /// The render thread's run loop while it runs, so `cancel` can wake it.
    private let loop = Mutex<CFRunLoop?>(nil)
    private let stats = Mutex(SplashStats())
    private let onFinish: @Sendable (SplashStats) -> Void

    private init(kit: SplashKit, timeline: SplashTimeline, mesh: MTLBuffer, t0: CFTimeInterval, slow: Double,
                 onFinish: @escaping @Sendable (SplashStats) -> Void) {
        self.kit = kit
        self.timeline = timeline
        self.mesh = mesh
        self.t0 = t0
        self.slow = slow
        self.onFinish = onFinish
        super.init()
        let layout = timeline.layout
        layer.device = kit.device
        layer.pixelFormat = .bgra8Unorm          // blend in gamma space, as Core Animation does
        layer.colorspace = SplashColor.space
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.contentsScale = layout.scale
        layer.frame = CGRect(origin: .zero, size: layout.size)
        layer.drawableSize = CGSize(width: (layout.size.width * layout.scale).rounded(), height: (layout.size.height * layout.scale).rounded())
        layer.maximumDrawableCount = 3
        encodeTimes.reserveCapacity(160)
        targets.reserveCapacity(160)
        leads.reserveCapacity(160)
    }

    /// Builds a renderer whose still first frame is drawn and scheduled, ready to swap in. Off
    /// the main thread: the first GPU submission waits several milliseconds.
    ///
    /// `wanted` says whether the splash still wants a renderer (it has not ended, and has not
    /// chosen Core Animation): it is read before anything is made, and the frame goes to the GPU
    /// under it, so nothing is drawn for a splash that is gone or an app in the background.
    static func make(kit: SplashKit, layout: SplashLayout, t0: CFTimeInterval, slow: Double, wanted: SplashFlag,
                     onFinish: @escaping @Sendable (SplashStats) -> Void) throws -> SplashRenderer {
        guard wanted.isSet else { throw SplashError(description: "not wanted any more") }
        // The pictures must be at the screen's scale, or the swap would show.
        guard abs(kit.art.scale - layout.scale) < 0.01 else { throw SplashError(description: "pictures are not at the screen's scale") }
        let vertices = SplashMesh.vertices(window: Float(layout.holeRadius), far: Float(hypot(layout.size.width, layout.size.height)))
        guard let mesh = kit.device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD2<Float>>.stride,
                                               options: .storageModeShared) else {
            throw SplashError(description: "no mesh")
        }
        // A thread without a run loop never commits an implicit transaction: commit the layer's setup.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = SplashRenderer(kit: kit, timeline: SplashTimeline(layout: layout, theme: kit.art.theme), mesh: mesh, t0: t0,
                               slow: slow, onFinish: onFinish)
        r.layer.presentsWithTransaction = true
        CATransaction.commit()
        let begin = CACurrentMediaTime()
        guard let drawable = r.layer.nextDrawable(), let cb = r.encode(t: -1, into: drawable.texture) else {
            throw SplashError(description: "no first frame")
        }
        // Committed only while still wanted, and the splash's end waits for this to finish.
        guard wanted.whileSet({ cb.commit() }) else { throw SplashError(description: "not wanted any more") }
        cb.waitUntilScheduled()
        r.firstDrawable = drawable
        let spent = CACurrentMediaTime() - begin
        r.stats.withLock { $0.firstFrame = spent }
        return r
    }

    /// Shows the first frame with the caller's `CATransaction`. Main thread, before `start()`.
    func presentFirstFrame() {
        firstDrawable?.present()
        firstDrawable = nil
    }

    /// Main-thread time of the swap, for the launch log.
    func noteSwap(_ seconds: CFTimeInterval) {
        stats.withLock { $0.swap = seconds }
    }

    /// Hands the renderer to its own thread, which draws every later frame and then frees everything.
    /// Call after committing the transaction that presented the first frame.
    func start() {
        layer.presentsWithTransaction = false
        let thread = Thread { [self] in self.renderLoop() }
        thread.name = "PlainSplash"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops early (the splash went away, or the app left the foreground). Any thread. Nothing
    /// more is drawn: the render thread is woken to stop, whether or not the display link ever
    /// calls again. A renderer that never started is simply freed.
    func cancel() {
        cancelled.store(true, ordering: .relaxed)
        stopped.withLock { $0 = true }
        loop.withLock { loop in
            guard let loop else { return }
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { [self] in self.finish() }
            CFRunLoopWakeUp(loop)
        }
    }

    private func renderLoop() {
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.delegate = self
        link.add(to: .current, forMode: .default)
        self.link = link
        loop.withLock { $0 = CFRunLoopGetCurrent() }
        // Cancelled before the thread got here: nothing woke it.
        if cancelled.load(ordering: .relaxed) { running = false }
        while running {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }
        loop.withLock { $0 = nil }
        link.invalidate()
        self.link = nil
        msaa = nil
        depth = nil
        kit = nil
        let encode = encodeTimes, targets = self.targets, leads = self.leads
        // Let the last command buffers report their GPU time first.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            var s = self.stats.withLock { $0 }
            s.encode = encode
            s.targets = targets
            s.leads = leads
            self.onFinish(s)
        }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // Cancelled: stop without drawing.
        guard running, !cancelled.load(ordering: .relaxed) else { return finish() }
        let t = (update.targetPresentationTimestamp - t0) / slow
        let done = t >= SplashTimeline.duration
        // Until the dive starts, the first frame (presented on the main thread) is still right.
        if t < 0 && !done { return }
        let begin = CACurrentMediaTime()
        leads.append(update.targetPresentationTimestamp - begin)
        // The last frame is empty: the opening has cleared the screen by then.
        guard let cb = encode(t: done ? .infinity : t, into: update.drawable.texture) else { return finish() }
        let due = update.targetPresentationTimestamp
        cb.addCompletedHandler { [self] cb in
            let gpu = cb.gpuEndTime - cb.gpuStartTime
            let late = cb.gpuEndTime > due
            self.stats.withLock {
                $0.gpu.append(gpu)
                if late { $0.late += 1 }
            }
        }
        // Handed to the GPU unless `cancel` got in first; `cancel` waits for a hand-over under way.
        let committed = stopped.withLock { stopped -> Bool in
            guard !stopped else { return false }
            cb.present(update.drawable)
            cb.commit()
            return true
        }
        guard committed else { return finish() }
        encodeTimes.append(CACurrentMediaTime() - begin)
        targets.append(due)
        if done { finish() }
    }

    private func finish() {
        running = false
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    /// One frame: what is in the opening, then the sheet. `t = .infinity` draws nothing (a clear
    /// frame); `t < 0` the still splash.
    private func encode(t: Double, into target: MTLTexture) -> MTLCommandBuffer? {
        guard let kit, let cb = kit.queue.makeCommandBuffer() else { return nil }
        if msaa?.width != target.width || msaa?.height != target.height {
            msaa = makeTarget(kit, .bgra8Unorm, target)
            depth = makeTarget(kit, .depth32Float, target)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        if t.isFinite {
            var u = timeline.uniforms(at: t)
            let size = MemoryLayout<SplashUniforms>.stride
            enc.setCullMode(.none)
            enc.setFrontFacing(.clockwise)
            enc.setVertexBytes(&u, length: size, index: 0)
            enc.setFragmentBytes(&u, length: size, index: 0)
            enc.setFragmentSamplerState(kit.smooth, index: 0)
            enc.setFragmentSamplerState(kit.exact, index: 1)
            enc.setFragmentSamplerState(kit.stretch, index: 2)

            enc.setRenderPipelineState(kit.hole)
            enc.setDepthStencilState(kit.holeDepth)
            enc.setFragmentTexture(kit.dawn, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

            enc.setRenderPipelineState(kit.sheet)
            enc.setDepthStencilState(kit.sheetDepth)
            enc.setVertexBuffer(mesh, offset: 0, index: 1)
            enc.setFragmentTexture(kit.mark, index: 0)
            enc.setFragmentTexture(kit.field, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: kit.indexCount, indexType: .uint16,
                                      indexBuffer: kit.indices, indexBufferOffset: 0)
        }
        enc.endEncoding()
        return cb
    }

    /// Multisampled color and depth, never stored: tile memory only on Apple GPUs.
    private func makeTarget(_ kit: SplashKit, _ format: MTLPixelFormat, _ like: MTLTexture) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: like.width, height: like.height, mipmapped: false)
        d.textureType = .type2DMultisample
        d.sampleCount = SplashKit.sampleCount
        d.usage = .renderTarget
        #if targetEnvironment(simulator)
        d.storageMode = .private
        #else
        d.storageMode = .memoryless
        #endif
        return kit.device.makeTexture(descriptor: d)
    }
}
#endif
