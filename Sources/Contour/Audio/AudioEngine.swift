import AppKit
import Accelerate
import AVFoundation
import ContourDSP
import CoreAudio
import Foundation
import Observation
import os

enum MeterTarget: Equatable {
    case input
    case chain(Chain)
}

enum EngineStatus: Equatable {
    case stopped
    case running
    /// A precondition isn't met yet — interface unplugged, BlackHole missing,
    /// permission not granted. Contour starts itself when it clears.
    case waiting(String)
    case failed(String)

    var isRunning: Bool { self == .running }
}

/// One channel of a meter, in dBFS.
///
/// Three values because they answer different questions: `level` is the bar and
/// has to be readable while music plays, `hold` is the short-term peak so a
/// transient is visible at all, and `maximum` never falls so "did a boost ever
/// clip" is still answerable after you look away.
struct ChannelMeter: Equatable {
    var level = Decibels.silenceFloor
    var hold = Decibels.silenceFloor
    var holdRemaining: Double = 0
    var maximum = Decibels.silenceFloor
}

struct StereoMeter: Equatable {
    var left = ChannelMeter()
    var right = ChannelMeter()

    var maximum: Float { max(left.maximum, right.maximum) }
    /// Full scale reached. With EQ boosts in the path this is worth flagging.
    var didClip: Bool { maximum >= -0.1 }
}

struct DisplayLevels: Equatable {
    var input = StereoMeter()
    var chainA = StereoMeter()
    var chainB = StereoMeter()

    subscript(chain: Chain) -> StereoMeter {
        get { chain == .a ? chainA : chainB }
        set { if chain == .a { chainA = newValue } else { chainB = newValue } }
    }
}

@MainActor
@Observable
final class AudioEngine {

    private(set) var status: EngineStatus = .stopped
    private(set) var interface: AudioDevice?
    private(set) var capture: AudioDevice?
    private(set) var sampleRate: Double = 0
    private(set) var latencyFrames: Int = 0

    /// Backend B only: the system slider attenuates BlackHole digitally before
    /// Contour sees the audio, so anything below unity is throwing away bits.
    private(set) var systemOutput: AudioDevice?
    private(set) var captureVolume: Float?

    /// Non-nil only when the render target exposes a software volume control.
    ///
    /// This is the whole discovery mechanism for "is this an external interface
    /// or not": a class-compliant interface with a physical knob has no
    /// `kAudioDevicePropertyVolumeScalar`, while Bluetooth headphones and the
    /// built-in speakers do. When it exists the keyboard cannot reach it —
    /// the volume keys act on the *default output device*, which is BlackHole —
    /// so Contour surfaces it instead.
    private(set) var interfaceVolume: Float?

    private(set) var meters = BlackHoleSource.Meters()
    private(set) var levels = DisplayLevels()

    /// Reading BlackHole means reading an *input* device, which macOS gates behind
    /// the microphone TCC grant. Without it Core Audio hands back silence and no
    /// error at all, so this must be checked explicitly, not inferred from failure.
    private(set) var microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
    private var isRequestingMicrophoneAccess = false

    static let log = Logger(subsystem: "com.nahak.contour", category: "engine")

    // MARK: - User-facing settings

    var destination: Destination = .both {
        didSet {
            guard destination != oldValue else { return }
            defaults.set(destination.rawValue, forKey: Keys.destination)
            publishParameters()
        }
    }

    var chainA = ChainSettings() {
        didSet {
            guard chainA != oldValue else { return }
            save(chainA, forKey: Keys.chainA)
            publishParameters()
            if chainA.eq != oldValue.eq { eqA.update(settings: chainA.eq, sampleRate: eqSampleRate) }
        }
    }

    var chainB = ChainSettings() {
        didSet {
            guard chainB != oldValue else { return }
            save(chainB, forKey: Keys.chainB)
            publishParameters()
            if chainB.eq != oldValue.eq { eqB.update(settings: chainB.eq, sampleRate: eqSampleRate) }
        }
    }

    /// Persisted so the choice survives relaunches; auto-picked when unset.
    var interfaceUID: String? {
        didSet {
            guard interfaceUID != oldValue else { return }
            defaults.set(interfaceUID, forKey: Keys.interfaceUID)
            restart()
        }
    }

    /// The popover only exists while open, so meters are polled fast only then.
    var isPopoverVisible = false

    func settings(for chain: Chain) -> ChainSettings { chain == .a ? chainA : chainB }

    func setSettings(_ settings: ChainSettings, for chain: Chain) {
        if chain == .a { chainA = settings } else { chainB = settings }
    }

    private enum Keys {
        static let interfaceUID = "interfaceUID"
        static let destination = "destination"
        static let chainA = "chainA"
        static let chainB = "chainB"
    }

    private let defaults = UserDefaults.standard
    private let parameters = TripleBuffer<EngineParameters>(EngineParameters())

    /// One cascade per chain, allocated once and kept for the process lifetime
    /// so the realtime path never waits on a filter being built.
    private let eqA = ChainEQ(maximumFrames: BlackHoleSource.scratchCapacity,
                              sampleRate: 44_100)
    private let eqB = ChainEQ(maximumFrames: BlackHoleSource.scratchCapacity,
                              sampleRate: 44_100)

    func eq(for chain: Chain) -> ChainEQ { chain == .a ? eqA : eqB }

    private var source: BlackHoleSource?
    private var listeners: [PropertyListener] = []
    private var interfaceListeners: [PropertyListener] = []
    private var restartTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private let listenerQueue = DispatchQueue(label: "com.nahak.contour.listeners")

    init() {
        interfaceUID = defaults.string(forKey: Keys.interfaceUID)
        destination = defaults.string(forKey: Keys.destination)
            .flatMap(Destination.init(rawValue:)) ?? .both
        chainA = load(Keys.chainA) ?? ChainSettings()
        chainB = load(Keys.chainB) ?? ChainSettings()
        publishParameters()
        publishEQ()
        installHardwareListeners()
        installSleepWakeObservers()
        startMeterPolling()
    }

    // MARK: - Environment

    var availableInterfaces: [AudioDevice] { AudioDevices.candidateInterfaces() }

    var systemOutputIsCapture: Bool {
        guard let systemOutput, let capture else { return false }
        return systemOutput.uid == capture.uid
    }

    var outputPairCount: Int { (interface?.outputChannels ?? 0) / 2 }

    /// A stereo-only interface collapses to one chain with no loss of function,
    /// and the destination switch is hidden rather than shown broken.
    var supportsTwoChains: Bool { outputPairCount >= 2 }

    func refreshEnvironment() {
        systemOutput = AudioDevices.defaultOutputDevice()
        let blackHole = AudioDevices.blackHole()
        capture = blackHole
        captureVolume = blackHole.flatMap(AudioDevices.outputVolumeScalar)
        if let uid = interfaceUID, let device = AudioDevices.device(uid: uid) {
            interface = device
        } else {
            interface = AudioDevices.preferredInterface()
        }
        interfaceVolume = interface.flatMap(AudioDevices.outputVolumeScalar)
    }

    var interfaceHasSoftwareVolume: Bool { interfaceVolume != nil }

    func setInterfaceVolume(_ value: Float) {
        guard let interface else { return }
        try? AudioDevices.setOutputVolumeScalar(interface, min(max(value, 0), 1))
        interfaceVolume = AudioDevices.outputVolumeScalar(interface)
    }

    // MARK: - Permissions

    /// Uses the async form deliberately. The completion-handler form runs its
    /// closure on an XPC queue, but Swift infers it as `@MainActor` because
    /// this type is, and the executor assertion then traps the process.
    func requestMicrophoneAccess() {
        guard microphoneAccess == .notDetermined else {
            openMicrophoneSettings()
            return
        }
        guard !isRequestingMicrophoneAccess else { return }
        isRequestingMicrophoneAccess = true
        Task { @MainActor [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self else { return }
            self.isRequestingMicrophoneAccess = false
            self.microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
            Self.log.notice("microphone access granted=\(granted, privacy: .public)")
            if granted { self.start() }
        }
    }

    func openMicrophoneSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Lifecycle

    func start() {
        stop()
        refreshEnvironment()

        microphoneAccess = AVCaptureDevice.authorizationStatus(for: .audio)
        Self.log.notice("start: microphoneAccess=\(self.microphoneAccess.rawValue, privacy: .public)")
        switch microphoneAccess {
        case .notDetermined:
            setStatus(.waiting("Contour needs microphone access to read system audio "
                               + "back from BlackHole."))
            requestMicrophoneAccess()
            return
        case .denied, .restricted:
            setStatus(.waiting("Microphone access is denied. Core Audio returns silence "
                               + "without it — grant it in Privacy & Security."))
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        guard let capture else {
            setStatus(.waiting("BlackHole 2ch not found. Install it, then reopen this menu."))
            return
        }
        guard let interface else {
            setStatus(.waiting("No output interface found."))
            return
        }
        guard interface.outputChannels >= 2 else {
            setStatus(.failed("\(interface.name) has \(interface.outputChannels) output channels."))
            return
        }

        let pairCount = interface.outputChannels / 2
        let source = BlackHoleSource(interface: interface,
                                     capture: capture,
                                     chainAPairIndex: 0,
                                     chainBPairIndex: pairCount >= 2 ? 1 : nil)
        publishParameters()
        do {
            try source.start(makeRenderBlock())
            self.source = source
            sampleRate = source.format.sampleRate
            latencyFrames = source.outputLatencyFrames
            // Coefficients are rate-dependent, and the aggregate may not run at
            // the rate the interface reported before it was built.
            eqA.reset()
            eqB.reset()
            publishEQ()
            status = .running
            installInterfaceListeners()
            Self.log.notice("started\n\(source.layoutDescription, privacy: .public)")
        } catch {
            self.source = nil
            setStatus(.failed("\(error)"))
        }
    }

    /// Every path out of `start()` goes through here, so a stuck engine always
    /// leaves a reason in the log rather than just not starting.
    private func setStatus(_ new: EngineStatus) {
        status = new
        switch new {
        case .waiting(let reason):
            Self.log.notice("waiting: \(reason, privacy: .public)")
        case .failed(let reason):
            Self.log.error("failed: \(reason, privacy: .public)")
        case .running, .stopped:
            break
        }
    }

    func stop() {
        source?.stop()
        source = nil
        interfaceListeners.removeAll()
        levels = DisplayLevels()
        meters = BlackHoleSource.Meters()
        if status.isRunning { status = .stopped }
    }

    func restart() {
        restartTask?.cancel()
        restartTask = Task { @MainActor in
            // Core Audio fires several property changes for one physical event;
            // coalesce them so the aggregate is rebuilt once.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            start()
        }
    }

    // MARK: - Fixes offered in the UI

    func makeCaptureSystemOutput() {
        guard let capture else { return }
        do {
            try AudioDevices.setDefaultOutputDevice(capture)
            refreshEnvironment()
        } catch {
            setStatus(.failed("Could not set system output: \(error)"))
        }
    }

    func resetCaptureVolume() {
        guard let capture else { return }
        try? AudioDevices.setOutputVolumeScalar(capture, 1.0)
        refreshEnvironment()
    }

    // MARK: - Parameters

    /// Trim actually sent to the audio thread. Auto-trim is derived here rather
    /// than written back into `inputTrimDB`, which would recurse through the
    /// `didSet` that triggered it and would destroy the manual value.
    func effectiveTrimDB(for chain: Chain) -> Float {
        let settings = settings(for: chain)
        guard settings.autoTrim, settings.eq.isEnabled else { return settings.inputTrimDB }
        let boost = EQCurveCache.maximumBoostDB(bands: settings.eq.bands,
                                                adaptiveQ: settings.eq.adaptiveQ,
                                                sampleRate: eqSampleRate)
        return Float(max(min(-boost, 0), Double(ChainSettings.trimRange.lowerBound)))
    }

    private func publishParameters() {
        let twoChains = supportsTwoChains
        parameters.publish(EngineParameters(
            a: ChainParameters(isActive: destination.includesA,
                               inputTrim: Decibels.toLinear(effectiveTrimDB(for: .a)),
                               outputGain: Decibels.toLinear(chainA.outputGainDB)),
            b: ChainParameters(isActive: twoChains && destination.includesB,
                               inputTrim: Decibels.toLinear(effectiveTrimDB(for: .b)),
                               outputGain: Decibels.toLinear(chainB.outputGainDB))))
    }

    /// Coefficients depend on sample rate, so this is recomputed whenever the
    /// aggregate is rebuilt as well as when a band changes.
    var eqSampleRate: Double { sampleRate > 0 ? sampleRate : 44_100 }

    private func publishEQ() {
        eqA.update(settings: chainA.eq, sampleRate: eqSampleRate)
        eqB.update(settings: chainB.eq, sampleRate: eqSampleRate)
    }

    /// Signal flow per chain: input trim, then the processing list, then output
    /// gain (§4). The EQ is the only processing-list entry that exists so far.
    /// Inactive chains are left untouched — the source has already zeroed every
    /// output buffer, so not writing *is* the teardown at this stage.
    private func makeRenderBlock() -> RenderBlock {
        let parameters = self.parameters
        let eqA = self.eqA
        let eqB = self.eqB
        return { buffers in
            let values = parameters.current()
            let frames = buffers.frameCount
            let length = vDSP_Length(frames)

            if values.a.isActive {
                var trim = values.a.inputTrim
                vDSP_vsmul(buffers.inputL, 1, &trim, buffers.chainAL, 1, length)
                vDSP_vsmul(buffers.inputR, 1, &trim, buffers.chainAR, 1, length)
                eqA.process(left: buffers.chainAL, right: buffers.chainAR, frames: frames)
                var gain = values.a.outputGain
                vDSP_vsmul(buffers.chainAL, 1, &gain, buffers.chainAL, 1, length)
                vDSP_vsmul(buffers.chainAR, 1, &gain, buffers.chainAR, 1, length)
            }
            if values.b.isActive {
                var trim = values.b.inputTrim
                vDSP_vsmul(buffers.inputL, 1, &trim, buffers.chainBL, 1, length)
                vDSP_vsmul(buffers.inputR, 1, &trim, buffers.chainBR, 1, length)
                eqB.process(left: buffers.chainBL, right: buffers.chainBR, frames: frames)
                var gain = values.b.outputGain
                vDSP_vsmul(buffers.chainBL, 1, &gain, buffers.chainBL, 1, length)
                vDSP_vsmul(buffers.chainBR, 1, &gain, buffers.chainBR, 1, length)
            }
        }
    }

    // MARK: - Metering

    private func startMeterPolling() {
        meterTask = Task { @MainActor [weak self] in
            var lastCallbacks: UInt64 = 0
            var stalledPolls = 0
            while !Task.isCancelled {
                let idle = !(self?.isPopoverVisible ?? false)
                try? await Task.sleep(for: .milliseconds(idle ? 500 : 50))
                guard let self else { return }
                guard let source = self.source else {
                    self.meters = BlackHoleSource.Meters()
                    self.levels = DisplayLevels()
                    lastCallbacks = 0
                    continue
                }
                let interval = idle ? 0.5 : 0.05
                let meters = source.consumeMeters()
                self.meters = meters
                self.levels = Self.advance(self.levels, with: meters, interval: interval)

                // A running device that stops calling back is the failure mode
                // that otherwise presents as "it just went quiet".
                if meters.callbacks == lastCallbacks {
                    stalledPolls += 1
                    if stalledPolls == (idle ? 4 : 40) {
                        Self.log.error("IOProc stalled at \(meters.callbacks, privacy: .public) callbacks")
                    }
                } else {
                    stalledPolls = 0
                }
                lastCallbacks = meters.callbacks
            }
        }
    }

    /// dB per second the bar falls, and the slower rate the peak tick falls
    /// once its hold has expired.
    private static let levelFallRate: Float = 60
    private static let holdFallRate: Float = 20
    private static let holdDuration: Double = 1.5

    private static func advance(_ current: DisplayLevels,
                                with meters: BlackHoleSource.Meters,
                                interval: Double) -> DisplayLevels {
        var levels = current
        levels.input = advance(current.input, meters.input, interval)
        levels.chainA = advance(current.chainA, meters.chainA, interval)
        levels.chainB = advance(current.chainB, meters.chainB, interval)
        return levels
    }

    private static func advance(_ current: StereoMeter,
                                _ peaks: BlackHoleSource.StereoPeak,
                                _ interval: Double) -> StereoMeter {
        StereoMeter(left: advance(current.left, peaks.left, interval),
                    right: advance(current.right, peaks.right, interval))
    }

    /// Instant attack, timed fall.
    private static func advance(_ current: ChannelMeter,
                                _ linear: Float,
                                _ interval: Double) -> ChannelMeter {
        var meter = current
        let db = max(Decibels.fromLinear(linear), Decibels.silenceFloor)

        meter.level = db >= meter.level
            ? db
            : max(db, meter.level - levelFallRate * Float(interval))

        if db >= meter.hold {
            meter.hold = db
            meter.holdRemaining = holdDuration
        } else {
            meter.holdRemaining -= interval
            if meter.holdRemaining <= 0 {
                meter.hold = max(db, meter.hold - holdFallRate * Float(interval))
            }
        }

        if db > meter.maximum { meter.maximum = db }
        return meter
    }

    /// Clears the never-falling maximum for one meter. Bound to clicking its
    /// readout.
    func resetMaximum(_ target: MeterTarget) {
        func cleared(_ meter: StereoMeter) -> StereoMeter {
            var meter = meter
            meter.left.maximum = Decibels.silenceFloor
            meter.right.maximum = Decibels.silenceFloor
            return meter
        }
        switch target {
        case .input: levels.input = cleared(levels.input)
        case .chain(let chain): levels[chain] = cleared(levels[chain])
        }
    }

    // MARK: - Persistence

    private func save<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Listeners

    private func installHardwareListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            listeners.append(PropertyListener(
                object: system,
                address: CA.address(selector),
                queue: listenerQueue) { [weak self] in
                    Task { @MainActor in self?.handleHardwareChange() }
                })
        }
    }

    private func installInterfaceListeners() {
        interfaceListeners.removeAll()
        guard let interface else { return }
        for selector in [kAudioDevicePropertyNominalSampleRate,
                         kAudioDevicePropertyStreamConfiguration] {
            interfaceListeners.append(PropertyListener(
                object: interface.id,
                address: CA.address(selector, scope: kAudioObjectPropertyScopeOutput),
                queue: listenerQueue) { [weak self] in
                    Task { @MainActor in self?.restart() }
                })
        }
        // Volume changed elsewhere (System Settings, the headphones themselves).
        let volumeAddress = CA.address(kAudioDevicePropertyVolumeScalar,
                                       scope: kAudioObjectPropertyScopeOutput)
        if CA.has(interface.id, volumeAddress) {
            interfaceListeners.append(PropertyListener(
                object: interface.id,
                address: volumeAddress,
                queue: listenerQueue) { [weak self] in
                    Task { @MainActor in
                        guard let self, let device = self.interface else { return }
                        self.interfaceVolume = AudioDevices.outputVolumeScalar(device)
                    }
                })
        }
    }

    private func handleHardwareChange() {
        let previousInterfaceUID = interface?.uid
        let previousSampleRate = interface?.sampleRate
        refreshEnvironment()

        switch status {
        case .running:
            // Interface gone or re-clocked: the aggregate is stale either way.
            if interface?.uid != previousInterfaceUID || interface?.sampleRate != previousSampleRate {
                restart()
            }
        case .waiting:
            if interface != nil, capture != nil, microphoneAccess == .authorized { restart() }
        case .stopped, .failed:
            break
        }
    }

    private func installSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // USB interfaces re-enumerate for a second or two after wake.
                try? await Task.sleep(for: .seconds(2))
                self?.start()
            }
        }
    }
}
