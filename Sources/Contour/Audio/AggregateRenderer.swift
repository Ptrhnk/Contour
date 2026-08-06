import Accelerate
import AVFoundation
import CoreAudio

/// The realtime half of a backend: one IOProc on an aggregate, reading a stereo
/// pair in and writing two pairs out.
///
/// Shared by both backends, because nothing here depends on where system audio
/// comes from. BlackHole and the process tap differ only in how the aggregate is
/// built; the channel mapping, the startup gate, the metering and the realtime
/// rules are identical.
final class AggregateRenderer {

    /// 8192 frames covers any buffer size Core Audio will ask for; allocating
    /// generously once is cheaper than tracking buffer-size changes at runtime.
    static let scratchCapacity = 8192

    /// Everything the IOProc touches, allocated once at start and never resized.
    /// Reached from the realtime thread through an unretained opaque pointer.
    private final class RenderState {
        let capacity: Int
        let inL, inR, aL, aR, bL, bR: UnsafeMutablePointer<Float>
        let inputPair: ChannelPairSlot
        let pairA: ChannelPairSlot?
        let pairB: ChannelPairSlot?
        let render: RenderBlock
        /// Applied as the capture pair is deinterleaved, so everything
        /// downstream — meters included — sees a level-matched signal whichever
        /// backend produced it. See `AggregateRenderer.captureGain`.
        var captureGain: Float

        // Word-sized plain stores from the realtime thread, read from the main
        // thread for display only. A torn read of a meter is not worth a lock.
        var callbacks: UInt64 = 0
        var lastFrames: Int = 0
        var inputPeakL: Float = 0
        var inputPeakR: Float = 0
        var chainAPeakL: Float = 0
        var chainAPeakR: Float = 0
        var chainBPeakL: Float = 0
        var chainBPeakR: Float = 0

        /// Peak per logical input channel, so "which channel is the audio on"
        /// is answerable without guessing at the buffer layout.
        static let maxProbeChannels = 32
        let inPeaks: UnsafeMutablePointer<Float>
        var inBufferCount: Int = 0
        var inChannelCount: Int = 0
        var outBufferCount: Int = 0

        /// Startup gate. The first buffers a device hands back can contain stale
        /// ring-buffer memory — measured at +14 to +21 dBFS — and it is not
        /// deterministic, so a fixed mute is not reliably long enough. The input
        /// is held silent until it looks like audio, then faded in.
        let minimumMuteFrames: Int
        let maximumMuteFrames: Int
        let fadeFrames: Int
        var framesSinceStart: Int = 0
        var fadeStartFrame: Int = 0
        var calmBlocks: Int = 0
        var isArmed = false
        var isStartupComplete = false

        static let sanityThreshold: Float = 4
        static let requiredCalmBlocks = 3

        init(capacity: Int,
             sampleRate: Double,
             inputPair: ChannelPairSlot,
             pairA: ChannelPairSlot?,
             pairB: ChannelPairSlot?,
             captureGain: Float,
             render: @escaping RenderBlock) {
            self.captureGain = captureGain
            let rate = sampleRate > 0 ? sampleRate : 44_100
            minimumMuteFrames = Int(rate * 0.10)
            maximumMuteFrames = Int(rate * 2.0)
            fadeFrames = Int(rate * 2.0)
            self.capacity = capacity
            self.inputPair = inputPair
            self.pairA = pairA
            self.pairB = pairB
            self.render = render
            func alloc() -> UnsafeMutablePointer<Float> {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
                p.initialize(repeating: 0, count: capacity)
                return p
            }
            inL = alloc(); inR = alloc()
            aL = alloc(); aR = alloc()
            bL = alloc(); bR = alloc()
            inPeaks = UnsafeMutablePointer<Float>.allocate(capacity: Self.maxProbeChannels)
            inPeaks.initialize(repeating: 0, count: Self.maxProbeChannels)
        }

        deinit {
            for p in [inL, inR, aL, aR, bL, bR] {
                p.deinitialize(count: capacity)
                p.deallocate()
            }
            inPeaks.deinitialize(count: Self.maxProbeChannels)
            inPeaks.deallocate()
        }
    }

    struct StereoPeak: Equatable {
        var left: Float = 0
        var right: Float = 0
        var mono: Float { max(left, right) }
    }

    struct Meters {
        var callbacks: UInt64 = 0
        var frames: Int = 0
        var input = StereoPeak()
        var chainA = StereoPeak()
        var chainB = StereoPeak()
        var inputBufferCount: Int = 0
        var outputBufferCount: Int = 0
        /// Peak on every logical input channel, for diagnosing routing.
        var channelPeaks: [Float] = []
    }

    private let aggregate: AggregateDevice
    private let inputPair: ChannelPairSlot
    private let pairA: ChannelPairSlot
    private let pairB: ChannelPairSlot?
    private var procID: AudioDeviceIOProcID?
    private var state: RenderState?

    private(set) var format: AVAudioFormat
    private(set) var outputLatencyFrames: Int = 0
    private(set) var layoutDescription: String

    /// Linear gain applied to the capture pair. 1 for BlackHole, which hands
    /// back exactly what the system wrote; more than that for a tap, which
    /// arrives attenuated by its own mixdown.
    let captureGain: Float

    init(aggregate: AggregateDevice,
         chainAPairIndex: Int,
         chainBPairIndex: Int?,
         captureGain: Float = 1,
         source: String) throws {
        self.aggregate = aggregate
        self.captureGain = captureGain

        guard let inputPair = aggregate.captureInputPair else {
            throw CA.Failure(status: nil,
                             what: "no usable stereo input pair in the aggregate "
                                 + "(streams: \(aggregate.inputStreams))")
        }
        guard let pairA = aggregate.interfaceOutputPair(chainAPairIndex) else {
            throw CA.Failure(status: nil,
                             what: "interface has no output pair \(chainAPairIndex + 1) "
                                 + "(streams: \(aggregate.outputStreams))")
        }
        self.inputPair = inputPair
        self.pairA = pairA
        pairB = chainBPairIndex.flatMap { aggregate.interfaceOutputPair($0) }

        let rate = aggregate.sampleRate > 0 ? aggregate.sampleRate : aggregate.interface.sampleRate
        format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        outputLatencyFrames = aggregate.outputLatencyFrames

        layoutDescription = """
            source=\(source) captureGain=\(captureGain) \
            aggregate=\(aggregate.id) sr=\(aggregate.sampleRate) \
            bufferFrames=\(aggregate.bufferFrameSize)
            interface=\(aggregate.interface.name) in=\(aggregate.interface.inputChannels) \
            out=\(aggregate.interface.outputChannels)
            inputStreams=\(aggregate.inputStreams) outputStreams=\(aggregate.outputStreams)
            inputPair=buffer \(inputPair.buffer) offset \(inputPair.leftOffset) \
            stride \(inputPair.stride)
            pairA=buffer \(pairA.buffer) offset \(pairA.leftOffset) stride \(pairA.stride)
            pairB=\(pairB.map { "buffer \($0.buffer) offset \($0.leftOffset) stride \($0.stride)" } ?? "none")
            """
    }

    // MARK: - Lifecycle

    func start(_ render: @escaping RenderBlock) throws {
        guard procID == nil else { return }

        let state = RenderState(capacity: Self.scratchCapacity,
                                sampleRate: format.sampleRate,
                                inputPair: inputPair,
                                pairA: pairA,
                                pairB: pairB,
                                captureGain: captureGain,
                                render: render)
        self.state = state

        let opaque = Unmanaged.passUnretained(state).toOpaque()
        var procID: AudioDeviceIOProcID?
        do {
            try CA.check(
                AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, nil) {
                    now, inputData, _, outputData, _ in
                    Self.process(opaque, now, inputData, outputData)
                },
                "create IOProc")
            try CA.check(AudioDeviceStart(aggregate.id, procID), "start device")
            self.procID = procID
        } catch {
            if let procID { AudioDeviceDestroyIOProcID(aggregate.id, procID) }
            self.state = nil
            throw error
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregate.id, procID)
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
            self.procID = nil
        }
        aggregate.destroy()
        state = nil
    }

    deinit { stop() }

    /// The rate the aggregate is actually running at, which is not necessarily
    /// the rate it was built with.
    var currentSampleRate: Double { aggregate.sampleRate }

    // MARK: - Metering

    var meters: Meters {
        guard let state else { return Meters() }
        let count = min(state.inChannelCount, RenderState.maxProbeChannels)
        return Meters(callbacks: state.callbacks,
                      frames: state.lastFrames,
                      input: StereoPeak(left: state.inputPeakL, right: state.inputPeakR),
                      chainA: StereoPeak(left: state.chainAPeakL, right: state.chainAPeakR),
                      chainB: StereoPeak(left: state.chainBPeakL, right: state.chainBPeakR),
                      inputBufferCount: state.inBufferCount,
                      outputBufferCount: state.outBufferCount,
                      channelPeaks: (0..<count).map { state.inPeaks[$0] })
    }

    /// Reads the accumulated peaks and clears them, so the next read reports the
    /// interval since this one. Racing the audio thread can at worst drop a
    /// single callback's peak, which is not worth a lock on a meter.
    func consumeMeters() -> Meters {
        let snapshot = meters
        if let state {
            state.inputPeakL = 0
            state.inputPeakR = 0
            state.chainAPeakL = 0
            state.chainAPeakR = 0
            state.chainBPeakL = 0
            state.chainBPeakR = 0
        }
        return snapshot
    }

    // MARK: - Realtime

    /// Realtime thread. No allocation, no locks, no logging, no new objects.
    private static func process(_ opaque: UnsafeMutableRawPointer,
                                _ timestamp: UnsafePointer<AudioTimeStamp>,
                                _ inputData: UnsafePointer<AudioBufferList>,
                                _ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let state = Unmanaged<RenderState>.fromOpaque(opaque).takeUnretainedValue()
        let output = UnsafeMutableAudioBufferListPointer(outputData)
        guard output.count > 0 else { return }

        let outChannels = Int(output[0].mNumberChannels)
        guard outChannels > 0 else { return }
        let frames = Int(output[0].mDataByteSize) / (MemoryLayout<Float>.size * outChannels)

        // Silence every output buffer first. On the BlackHole backend the
        // capture device's own output channels are part of this aggregate, and
        // anything written there loops straight back into its input.
        for buffer in output {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        guard frames > 0, frames <= state.capacity else { return }

        var unity: Float = 1

        // Deinterleave the capture pair into planar scratch.
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))

        // Peak per logical input channel, in buffer order.
        var probed = 0
        for buffer in input {
            let channels = Int(buffer.mNumberChannels)
            guard let raw = buffer.mData, channels > 0 else { continue }
            let base = raw.assumingMemoryBound(to: Float.self)
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let n = min(frames, available)
            for channel in 0..<channels where probed < RenderState.maxProbeChannels {
                var peak: Float = 0
                if n > 0 {
                    vDSP_maxmgv(base + channel, vDSP_Stride(channels), &peak, vDSP_Length(n))
                }
                state.inPeaks[probed] = peak
                probed += 1
            }
        }
        state.inBufferCount = input.count
        state.inChannelCount = probed
        state.outBufferCount = output.count

        let slot = state.inputPair
        if slot.buffer < input.count, let raw = input[slot.buffer].mData,
           Int(input[slot.buffer].mDataByteSize)
            >= frames * Int(input[slot.buffer].mNumberChannels) * MemoryLayout<Float>.size {
            let src = raw.assumingMemoryBound(to: Float.self) + slot.leftOffset
            // The deinterleave already costs a multiply, so level-matching the
            // capture is free here.
            var gain = state.captureGain
            vDSP_vsmul(src, vDSP_Stride(slot.stride), &gain,
                       state.inL, 1, vDSP_Length(frames))
            vDSP_vsmul(src + 1, vDSP_Stride(slot.stride), &gain,
                       state.inR, 1, vDSP_Length(frames))
        } else {
            vDSP_vclr(state.inL, 1, vDSP_Length(frames))
            vDSP_vclr(state.inR, 1, vDSP_Length(frames))
        }

        applyStartupGate(state, frames)

        vDSP_vclr(state.aL, 1, vDSP_Length(frames))
        vDSP_vclr(state.aR, 1, vDSP_Length(frames))
        vDSP_vclr(state.bL, 1, vDSP_Length(frames))
        vDSP_vclr(state.bR, 1, vDSP_Length(frames))

        state.render(RenderBuffers(timestamp: timestamp,
                                   inputL: state.inL,
                                   inputR: state.inR,
                                   chainAL: state.aL,
                                   chainAR: state.aR,
                                   chainBL: state.bL,
                                   chainBR: state.bR,
                                   frameCount: frames))

        write(state.aL, state.aR, to: state.pairA, output, frames, &unity)
        write(state.bL, state.bR, to: state.pairB, output, frames, &unity)

        // Post-gain peaks, accumulated as a running max until the UI consumes
        // them: reporting only the newest callback would miss all but one buffer
        // in ~43 while the popover is closed.
        accumulate(state.inL, frames, into: &state.inputPeakL)
        accumulate(state.inR, frames, into: &state.inputPeakR)
        accumulate(state.aL, frames, into: &state.chainAPeakL)
        accumulate(state.aR, frames, into: &state.chainAPeakR)
        accumulate(state.bL, frames, into: &state.chainBPeakL)
        accumulate(state.bR, frames, into: &state.chainBPeakR)
        state.lastFrames = frames
        state.callbacks &+= 1
    }

    /// Hold silent until the input looks like audio, then fade in. Applied to
    /// the input before anything downstream, so stale memory cannot reach the
    /// biquads and ring them either.
    @inline(__always)
    private static func applyStartupGate(_ state: RenderState, _ frames: Int) {
        guard !state.isStartupComplete else { return }
        let count = vDSP_Length(frames)
        state.framesSinceStart += frames

        if !state.isArmed {
            var peakL: Float = 0
            var peakR: Float = 0
            vDSP_maxmgv(state.inL, 1, &peakL, count)
            vDSP_maxmgv(state.inR, 1, &peakR, count)

            let calm = max(peakL, peakR) <= RenderState.sanityThreshold
            state.calmBlocks = calm ? state.calmBlocks + 1 : 0

            let waitedLongEnough = state.framesSinceStart >= state.minimumMuteFrames
            let settled = state.calmBlocks >= RenderState.requiredCalmBlocks
            // Never stay muted forever: a genuinely hot source must still play.
            let timedOut = state.framesSinceStart >= state.maximumMuteFrames

            if (waitedLongEnough && settled) || timedOut {
                state.isArmed = true
                state.fadeStartFrame = state.framesSinceStart
            }
            vDSP_vclr(state.inL, 1, count)
            vDSP_vclr(state.inR, 1, count)
            return
        }

        let elapsed = state.framesSinceStart - state.fadeStartFrame
        guard elapsed < state.fadeFrames else {
            state.isStartupComplete = true
            return
        }
        let from = Float(max(elapsed - frames, 0)) / Float(state.fadeFrames)
        let to = Float(min(elapsed, state.fadeFrames)) / Float(state.fadeFrames)
        let step = (to - from) / Float(frames)
        // vDSP_vrampmul advances `start`, so each channel needs its own copy.
        var start = from
        var increment = step
        vDSP_vrampmul(state.inL, 1, &start, &increment, state.inL, 1, count)
        start = from
        increment = step
        vDSP_vrampmul(state.inR, 1, &start, &increment, state.inR, 1, count)
    }

    @inline(__always)
    private static func accumulate(_ samples: UnsafeMutablePointer<Float>,
                                   _ frames: Int,
                                   into destination: inout Float) {
        var value: Float = 0
        vDSP_maxmgv(samples, 1, &value, vDSP_Length(frames))
        if value > destination { destination = value }
    }

    @inline(__always)
    private static func write(_ left: UnsafeMutablePointer<Float>,
                              _ right: UnsafeMutablePointer<Float>,
                              to pair: ChannelPairSlot?,
                              _ output: UnsafeMutableAudioBufferListPointer,
                              _ frames: Int,
                              _ unity: inout Float) {
        guard let pair, pair.buffer < output.count,
              let raw = output[pair.buffer].mData else { return }
        let dst = raw.assumingMemoryBound(to: Float.self) + pair.leftOffset
        vDSP_vsmul(left, 1, &unity, dst, vDSP_Stride(pair.stride), vDSP_Length(frames))
        vDSP_vsmul(right, 1, &unity, dst + 1, vDSP_Stride(pair.stride), vDSP_Length(frames))
    }
}
