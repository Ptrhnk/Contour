import Accelerate
import AVFoundation
import CoreAudio

/// Backend B. System output is set to BlackHole; Contour reads it back out of the
/// aggregate and writes the processed result to the interface's channel pairs.
final class BlackHoleSource: AudioSource {

    /// Everything the IOProc touches, allocated once at start and never resized.
    /// Held by the source for the lifetime of the proc and reached from the
    /// realtime thread through an unretained opaque pointer.
    private final class RenderState {
        let capacity: Int
        let inL, inR, aL, aR, bL, bR: UnsafeMutablePointer<Float>
        let inputPair: ChannelPairSlot
        let pairA: ChannelPairSlot?
        let pairB: ChannelPairSlot?
        let render: RenderBlock

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

        init(capacity: Int,
             inputPair: ChannelPairSlot,
             pairA: ChannelPairSlot?,
             pairB: ChannelPairSlot?,
             render: @escaping RenderBlock) {
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

    /// 8192 frames covers any buffer size Core Audio will ask for; allocating
    /// generously once is cheaper than tracking buffer-size changes at runtime.
    static let scratchCapacity = 8192

    private let interface: AudioDevice
    private let capture: AudioDevice
    private let chainAPairIndex: Int
    private let chainBPairIndex: Int?

    private var aggregate: AggregateDevice?
    private var procID: AudioDeviceIOProcID?
    private var state: RenderState?

    private(set) var format: AVAudioFormat
    private(set) var outputLatencyFrames: Int = 0

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

    struct StereoPeak: Equatable {
        var left: Float = 0
        var right: Float = 0
        var mono: Float { max(left, right) }
    }

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
    /// interval since this one. Racing the audio thread here can at worst drop a
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

    /// Human-readable description of what the aggregate looks like, for diagnostics.
    private(set) var layoutDescription: String = "not started"

    init(interface: AudioDevice,
         capture: AudioDevice,
         chainAPairIndex: Int,
         chainBPairIndex: Int?) {
        self.interface = interface
        self.capture = capture
        self.chainAPairIndex = chainAPairIndex
        self.chainBPairIndex = chainBPairIndex
        let rate = interface.sampleRate > 0 ? interface.sampleRate : 44_100
        self.format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    }

    func start(_ render: @escaping RenderBlock) throws {
        guard aggregate == nil else { return }

        let aggregate = try AggregateDevice.create(interface: interface, capture: capture)
        do {
            guard let inputPair = aggregate.captureInputPair else {
                throw CA.Failure(status: nil,
                                 what: "capture device has no usable stereo input pair "
                                     + "in the aggregate (streams: \(aggregate.inputStreams))")
            }
            guard let pairA = aggregate.interfaceOutputPair(chainAPairIndex) else {
                throw CA.Failure(status: nil,
                                 what: "interface has no output pair \(chainAPairIndex + 1) "
                                     + "(streams: \(aggregate.outputStreams))")
            }
            let pairB = chainBPairIndex.flatMap { aggregate.interfaceOutputPair($0) }

            let rate = aggregate.sampleRate > 0 ? aggregate.sampleRate : interface.sampleRate
            format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            outputLatencyFrames = aggregate.outputLatencyFrames

            let state = RenderState(capacity: Self.scratchCapacity,
                                    inputPair: inputPair,
                                    pairA: pairA,
                                    pairB: pairB,
                                    render: render)
            self.state = state

            layoutDescription = """
                aggregate=\(aggregate.id) sr=\(aggregate.sampleRate) \
                bufferFrames=\(aggregate.bufferFrameSize)
                interface=\(interface.name) in=\(interface.inputChannels) \
                out=\(interface.outputChannels)
                capture=\(capture.name) in=\(capture.inputChannels) \
                out=\(capture.outputChannels)
                inputStreams=\(aggregate.inputStreams) outputStreams=\(aggregate.outputStreams)
                capturePair=buffer \(inputPair.buffer) offset \(inputPair.leftOffset) \
                stride \(inputPair.stride)
                pairA=buffer \(pairA.buffer) offset \(pairA.leftOffset) stride \(pairA.stride)
                pairB=\(pairB.map { "buffer \($0.buffer) offset \($0.leftOffset) stride \($0.stride)" } ?? "none")
                """

            let opaque = Unmanaged.passUnretained(state).toOpaque()
            var procID: AudioDeviceIOProcID?
            try CA.check(
                AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, nil) {
                    _, inputData, _, outputData, _ in
                    Self.process(opaque, inputData, outputData)
                },
                "create IOProc")
            self.procID = procID

            try CA.check(AudioDeviceStart(aggregate.id, procID), "start device")
            self.aggregate = aggregate
        } catch {
            teardown(aggregate: aggregate)
            throw error
        }
    }

    func stop() {
        guard let aggregate else { return }
        teardown(aggregate: aggregate)
        self.aggregate = nil
    }

    deinit { stop() }

    private func teardown(aggregate: AggregateDevice) {
        if let procID {
            AudioDeviceStop(aggregate.id, procID)
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
            self.procID = nil
        }
        aggregate.destroy()
        state = nil
    }

    // MARK: - Realtime

    /// Realtime thread. No allocation, no locks, no logging, no new objects.
    private static func process(_ opaque: UnsafeMutableRawPointer,
                                _ inputData: UnsafePointer<AudioBufferList>,
                                _ outputData: UnsafeMutablePointer<AudioBufferList>) {
        let state = Unmanaged<RenderState>.fromOpaque(opaque).takeUnretainedValue()
        let output = UnsafeMutableAudioBufferListPointer(outputData)
        guard output.count > 0 else { return }

        let outChannels = Int(output[0].mNumberChannels)
        guard outChannels > 0 else { return }
        let frames = Int(output[0].mDataByteSize) / (MemoryLayout<Float>.size * outChannels)

        // Silence every output buffer first. The capture device's own output
        // channels are part of this aggregate, and anything written there loops
        // straight back into its input.
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
            vDSP_vsmul(src, vDSP_Stride(slot.stride), &unity,
                       state.inL, 1, vDSP_Length(frames))
            vDSP_vsmul(src + 1, vDSP_Stride(slot.stride), &unity,
                       state.inR, 1, vDSP_Length(frames))
        } else {
            vDSP_vclr(state.inL, 1, vDSP_Length(frames))
            vDSP_vclr(state.inR, 1, vDSP_Length(frames))
        }

        vDSP_vclr(state.aL, 1, vDSP_Length(frames))
        vDSP_vclr(state.aR, 1, vDSP_Length(frames))
        vDSP_vclr(state.bL, 1, vDSP_Length(frames))
        vDSP_vclr(state.bR, 1, vDSP_Length(frames))

        state.render(RenderBuffers(inputL: state.inL,
                                   inputR: state.inR,
                                   chainAL: state.aL,
                                   chainAR: state.aR,
                                   chainBL: state.bL,
                                   chainBR: state.bR,
                                   frameCount: frames))

        write(state.aL, state.aR, to: state.pairA, output, frames, &unity)
        write(state.bL, state.bR, to: state.pairB, output, frames, &unity)

        // Post-gain peaks, accumulated as a running max until the UI consumes
        // them. Reporting only the newest callback would miss all but one
        // buffer in ~43 while the popover is closed.
        accumulate(state.inL, frames, into: &state.inputPeakL)
        accumulate(state.inR, frames, into: &state.inputPeakR)
        accumulate(state.aL, frames, into: &state.chainAPeakL)
        accumulate(state.aR, frames, into: &state.chainAPeakR)
        accumulate(state.bL, frames, into: &state.chainBPeakL)
        accumulate(state.bR, frames, into: &state.chainBPeakR)
        state.lastFrames = frames
        state.callbacks &+= 1
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
