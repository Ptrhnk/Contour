import AVFoundation
import os

/// One instantiated effect, ready to render.
///
/// Instantiated **in-process**: out-of-process isolation adds IPC jitter a
/// realtime insert cannot absorb (§6). Everything expensive — instantiation,
/// `allocateRenderResources`, buffer allocation — happens here, off the audio
/// thread, so `render` only calls the unit's render block.
final class PluginHost: @unchecked Sendable {

    let descriptor: AudioUnitDescriptor
    let audioUnit: AUAudioUnit

    /// Reported by the unit, in frames. Summed per chain for the readout.
    var latencyFrames: Int { Int(audioUnit.latency * audioUnit.outputBusses[0].format.sampleRate) }

    /// Bypassed units stay instantiated so preset switching does not have to
    /// build anything (§6a).
    var isBypassed: Bool {
        get { audioUnit.shouldBypassEffect }
        set { audioUnit.shouldBypassEffect = newValue }
    }

    private static let log = Logger(subsystem: "com.nahak.contour", category: "plugin")

    private let maximumFrames: Int
    /// `renderBlock`, not `internalRenderBlock`. The latter is what an audio
    /// unit *implementor* provides; calling it as a host returns
    /// `kAudioUnitErr_NoConnection` (-10876) and silence.
    private let renderBlock: AURenderBlock
    /// Pre-allocated: the audio thread never touches an allocator.
    private let inputList: UnsafeMutableAudioBufferListPointer
    private let outputList: UnsafeMutableAudioBufferListPointer
    private let inputStorage: UnsafeMutablePointer<Float>
    private let outputStorage: UnsafeMutablePointer<Float>
    private var pullInput: AURenderPullInputBlock!

    init(descriptor: AudioUnitDescriptor,
         sampleRate: Double,
         maximumFrames: Int) async throws {
        self.descriptor = descriptor
        self.maximumFrames = maximumFrames

        audioUnit = try await Self.instantiate(descriptor)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        else { throw PluginError.unsupportedFormat }
        try audioUnit.inputBusses[0].setFormat(format)
        try audioUnit.outputBusses[0].setFormat(format)
        // Without this the unit renders nothing and reports NoConnection, even
        // with a valid pull-input block.
        audioUnit.inputBusses[0].isEnabled = true
        audioUnit.outputBusses[0].isEnabled = true

        audioUnit.maximumFramesToRender = AUAudioFrameCount(maximumFrames)
        try audioUnit.allocateRenderResources()
        renderBlock = audioUnit.renderBlock

        inputStorage = .allocate(capacity: maximumFrames * 2)
        inputStorage.initialize(repeating: 0, count: maximumFrames * 2)
        outputStorage = .allocate(capacity: maximumFrames * 2)
        outputStorage.initialize(repeating: 0, count: maximumFrames * 2)

        inputList = Self.makeBufferList(storage: inputStorage, frames: maximumFrames)
        outputList = Self.makeBufferList(storage: outputStorage, frames: maximumFrames)

        // Hands the unit the samples already staged in `inputList`. Stored once
        // so calling it allocates nothing.
        let input = inputList
        pullInput = { _, _, frameCount, _, bufferList in
            let destination = UnsafeMutableAudioBufferListPointer(bufferList)
            for channel in 0..<min(destination.count, input.count) {
                destination[channel].mNumberChannels = 1
                destination[channel].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
                destination[channel].mData = input[channel].mData
            }
            return noErr
        }
    }

    deinit {
        audioUnit.deallocateRenderResources()
        free(inputList.unsafeMutablePointer)
        free(outputList.unsafeMutablePointer)
        inputStorage.deallocate()
        outputStorage.deallocate()
    }

    // MARK: - Setup

    /// In-process. Falls back to the default options rather than failing
    /// outright, because a plugin that cannot be hosted at all is worse than one
    /// hosted with more jitter — but that case is logged, because it matters.
    /// Seconds a plugin gets to load before it is given up on. Hosting is
    /// in-process, so a unit that never returns would otherwise hold the chain
    /// rebuild open indefinitely and leave the previous graph running.
    private static let instantiationTimeout: Duration = .seconds(20)

    private static func instantiate(_ descriptor: AudioUnitDescriptor) async throws -> AUAudioUnit {
        do {
            return try await withTimeout(instantiationTimeout) {
                try await AUAudioUnit.instantiate(
                    with: descriptor.audioComponentDescription,
                    options: [.loadInProcess])
            }
        } catch {
            log.error("""
                \(descriptor.name, privacy: .public) would not load in-process \
                (\(String(describing: error), privacy: .public)); \
                retrying out-of-process, which adds IPC jitter
                """)
            return try await withTimeout(instantiationTimeout) {
                try await AUAudioUnit.instantiate(
                    with: descriptor.audioComponentDescription, options: [])
            }
        }
    }

    /// Races the work against a sleep. The losing task is cancelled, though a
    /// plugin blocking inside its own load will not honour that — the point is
    /// that *we* stop waiting on it.
    private static func withTimeout<T>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: UncheckedBox<T>.self) { group in
            group.addTask { UncheckedBox(try await operation()) }
            group.addTask {
                try await Task.sleep(for: duration)
                throw PluginError.timedOut
            }
            guard let first = try await group.next() else { throw PluginError.timedOut }
            group.cancelAll()
            return first.value
        }
    }

    private static func makeBufferList(storage: UnsafeMutablePointer<Float>,
                                       frames: Int) -> UnsafeMutableAudioBufferListPointer {
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        for channel in 0..<2 {
            list[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage + channel * frames))
        }
        return list
    }

    // MARK: - State

    /// Opaque binary, so a preset carrying it only restores on a machine with
    /// the same plugin installed.
    var fullState: Data? {
        get {
            guard let state = audioUnit.fullStateForDocument else { return nil }
            return try? NSKeyedArchiver.archivedData(withRootObject: state,
                                                     requiringSecureCoding: false)
        }
        set {
            guard let newValue,
                  let state = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClasses: [NSDictionary.self, NSString.self, NSNumber.self,
                                NSData.self, NSArray.self],
                    from: newValue) as? [String: Any]
            else { return }
            audioUnit.fullStateForDocument = state
        }
    }

    // MARK: - Realtime

    /// Audio thread. In-place stereo, no allocation.
    @inline(__always)
    func render(left: UnsafeMutablePointer<Float>,
                right: UnsafeMutablePointer<Float>,
                frames: Int,
                timestamp: UnsafePointer<AudioTimeStamp>) {
        guard frames > 0, frames <= maximumFrames else { return }
        let bytes = frames * MemoryLayout<Float>.size

        memcpy(inputList[0].mData, left, bytes)
        memcpy(inputList[1].mData, right, bytes)

        for channel in 0..<2 {
            outputList[channel].mNumberChannels = 1
            outputList[channel].mDataByteSize = UInt32(bytes)
        }

        var flags = AudioUnitRenderActionFlags()
        let status = renderBlock(&flags,
                                 timestamp,
                                 AUAudioFrameCount(frames),
                                 0,
                                 outputList.unsafeMutablePointer,
                                 pullInput)
        guard status == noErr else { return }

        memcpy(left, outputList[0].mData, bytes)
        memcpy(right, outputList[1].mData, bytes)
    }
}

/// Carries a non-Sendable value across a task group.
///
/// `AUAudioUnit` is not Sendable and a task group insists its results are.
/// Hosting is in-process and this value never leaves the main actor, so nothing
/// actually crosses an isolation boundary. Declared here because a generic type
/// cannot be nested inside a generic function.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

enum PluginError: Error, LocalizedError {
    case unsupportedFormat
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Could not create a stereo float format for this plugin."
        case .timedOut: "The plugin did not finish loading."
        }
    }
}
