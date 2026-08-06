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
            guard !isLoading, destination != oldValue else { return }
            defaults.set(destination.rawValue, forKey: Keys.destination)
            publishParameters()
        }
    }

    let history = EditHistory()

    var chainA = ChainSettings() {
        didSet {
            guard !isLoading, chainA != oldValue else { return }
            history.record(chain: .a, before: oldValue, after: chainA)
            save(chainA, forKey: Keys.chainA)
            publishParameters()
            if chainA.eq != oldValue.eq { eqA.update(settings: chainA.eq, sampleRate: eqSampleRate) }
            if chainA.processing != oldValue.processing { rebuildGraph(for: .a) }
        }
    }

    var chainB = ChainSettings() {
        didSet {
            guard !isLoading, chainB != oldValue else { return }
            history.record(chain: .b, before: oldValue, after: chainB)
            save(chainB, forKey: Keys.chainB)
            publishParameters()
            if chainB.eq != oldValue.eq { eqB.update(settings: chainB.eq, sampleRate: eqSampleRate) }
            if chainB.processing != oldValue.processing { rebuildGraph(for: .b) }
        }
    }

    /// Persisted so the choice survives relaunches; auto-picked when unset.
    ///
    /// Restarts only when the *resolved* device actually changes. Storing a UID
    /// for a device that is not plugged in resolves to the auto-picked one, and
    /// several paths — notably the interface `Picker` writing its selection back
    /// on first layout — set this to a value that changes nothing. Restarting on
    /// those re-runs the startup mute and fade, which is audible.
    var interfaceUID: String? {
        didSet {
            guard !isLoading, interfaceUID != oldValue else { return }
            defaults.set(interfaceUID, forKey: Keys.interfaceUID)
            let previous = interface?.uid
            refreshEnvironment()
            guard interface?.uid != previous else { return }
            restart()
        }
    }

    /// Number of visible views currently showing meters.
    ///
    /// A count rather than a flag because there are two surfaces now — the
    /// popover and the EQ window — and either alone must be enough to raise the
    /// poll rate. Gating on the popover meant the window's meters stepped along
    /// at the 500 ms idle rate whenever the popover happened to be closed.
    private(set) var meterViewCount = 0

    var wantsFastMeters: Bool { meterViewCount > 0 }

    func beginObservingMeters() { meterViewCount += 1 }

    func endObservingMeters() { meterViewCount = max(0, meterViewCount - 1) }

    func settings(for chain: Chain) -> ChainSettings { chain == .a ? chainA : chainB }

    func setSettings(_ settings: ChainSettings, for chain: Chain) {
        if chain == .a { chainA = settings } else { chainB = settings }
    }

    private enum Keys {
        static let interfaceUID = "interfaceUID"
        static let destination = "destination"
        static let chainA = "chainA"
        static let chainB = "chainB"
        static let presetA = "loadedPresetA"
        static let presetB = "loadedPresetB"
    }

    /// Loading persisted settings in `init` re-assigns properties that already
    /// hold their defaults, and Swift *does* run `didSet` for that. Without this
    /// guard, restoring the saved interface schedules a restart before the
    /// engine has even started, which shows up as the app starting twice and
    /// fading in twice.
    private var isLoading = true

    private let defaults = UserDefaults.standard
    private let parameters = TripleBuffer<EngineParameters>(EngineParameters())

    /// One cascade per chain, allocated once and kept for the process lifetime
    /// so the realtime path never waits on a filter being built.
    private let eqA = ChainEQ(maximumFrames: BlackHoleSource.scratchCapacity,
                              sampleRate: 44_100)
    private let eqB = ChainEQ(maximumFrames: BlackHoleSource.scratchCapacity,
                              sampleRate: 44_100)

    // Gain and trim are ramped rather than applied as a step, so loading a
    // preset that changes level does not click.
    private let trimRampA = GainRamp()
    private let trimRampB = GainRamp()
    private let gainRampA = GainRamp()
    private let gainRampB = GainRamp()
    private let makeupRampA = GainRamp()
    private let makeupRampB = GainRamp()

    let presets = PresetStore()
    let catalog = AudioUnitCatalog()

    /// Live plugins per chain, keyed by processing-item id, so a rebuild reuses
    /// instances rather than tearing down and re-instantiating everything.
    private var liveHosts: [Chain: [UUID: PluginHost]] = [.a: [:], .b: [:]]
    private var graphBuilds: [Chain: Task<Void, Never>] = [:]
    private(set) var pluginLatencyFrames: [Chain: Int] = [.a: 0, .b: 0]
    private(set) var pluginFailure: String?

    /// Which preset each chain currently has loaded, if any.
    private(set) var loadedPresetA: UUID?
    private(set) var loadedPresetB: UUID?

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
        loadedPresetA = defaults.string(forKey: Keys.presetA).flatMap(UUID.init(uuidString:))
        loadedPresetB = defaults.string(forKey: Keys.presetB).flatMap(UUID.init(uuidString:))
        isLoading = false
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

    /// What to call a chain in the UI.
    ///
    /// With two output pairs the names are roles the user assigned to physical
    /// outputs, and Contour cannot see what is plugged into either — so they
    /// stay "Speakers" and "Headphones". With a single stereo device the chain
    /// *is* that device, and calling a pair of AirPods "Speakers" is just wrong.
    func title(for chain: Chain) -> String {
        guard !supportsTwoChains, let interface else { return chain.title }
        return interface.shortName
    }

    func symbol(for chain: Chain) -> String {
        guard !supportsTwoChains, let interface else {
            return chain == .a ? "hifispeaker" : "headphones"
        }
        return interface.symbolName
    }

    /// Single source of truth for "does this chain render".
    ///
    /// On a stereo-only device chain A is always active, whatever the
    /// destination says. Otherwise a destination of Headphones left over from a
    /// four-output interface silences the app completely — chain B does not
    /// exist to render and chain A has been switched off — and the destination
    /// picker is hidden on such devices, so there is no way back.
    func isChainActive(_ chain: Chain) -> Bool {
        guard supportsTwoChains else { return chain == .a }
        return chain == .a ? destination.includesA : destination.includesB
    }

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
        // Channel count decides how many chains exist, which decides which are
        // active. Swapping a 4-output interface for a stereo one must re-derive
        // that, not leave a stale "off".
        publishParameters()
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
            // Plugins are allocated for a specific sample rate.
            rebuildGraph(for: .a)
            rebuildGraph(for: .b)
            status = .running
            installInterfaceListeners()
            Self.log.notice("""
                started engineSampleRate=\(self.sampleRate, privacy: .public) \
                interfaceSampleRate=\(interface.sampleRate, privacy: .public)
                \(source.layoutDescription, privacy: .public)
                """)
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

    // MARK: - Plugins

    /// Rebuilds one chain's graph and swaps it in.
    ///
    /// Instantiation and `allocateRenderResources` happen here, off the audio
    /// thread; the realtime side only ever sees an index change (§6a). Existing
    /// instances are reused, so reordering or bypassing never reloads a plugin.
    func rebuildGraph(for chain: Chain) {
        graphBuilds[chain]?.cancel()
        let settings = settings(for: chain)

        // Bypassing or reordering never needs a new instance, so when every
        // plugin is already live the graph is rebuilt here and now. Going
        // through the async path meant a plugin that blocks — SoundID Reference
        // does — could stall the rebuild, leaving the *previous* graph running.
        // That looks exactly like a bypass that did nothing.
        if let graph = graphFromLiveHosts(settings: settings, chain: chain) {
            eq(for: chain).graphs.publish(graph)
            pluginLatencyFrames[chain] = graph.latencyFrames
            Self.log.notice("""
                \(chain.title, privacy: .public) graph rebuilt from live plugins: \
                \(Self.describe(graph), privacy: .public)
                """)
            return
        }

        let sampleRate = eqSampleRate
        let frames = BlackHoleSource.scratchCapacity

        graphBuilds[chain] = Task { @MainActor [weak self] in
            guard let self else { return }
            var hosts = self.liveHosts[chain] ?? [:]
            var failure: String?
            let log = AudioEngine.log
            log.notice("rebuilding \(chain.title, privacy: .public) graph")

            func host(for item: ProcessingItem) async -> PluginHost? {
                guard let descriptor = item.descriptor else { return nil }
                if let existing = hosts[item.id],
                   existing.descriptor.id == descriptor.id {
                    // Reused instances get the stored state too, or loading the
                    // same preset twice would keep whatever was tweaked in
                    // between. Callers capture live state before mutating the
                    // list, so this never overwrites unsaved work.
                    if let state = item.state { existing.fullState = state }
                    return existing
                }
                do {
                    let created = try await PluginHost(descriptor: descriptor,
                                                       sampleRate: sampleRate,
                                                       maximumFrames: frames)
                    created.fullState = item.state
                    hosts[item.id] = created
                    return created
                } catch {
                    let name = descriptor.name
                    failure = "\(name): \(error.localizedDescription)"
                    let detail = String(describing: error)
                    log.error("could not load \(name, privacy: .public): \(detail, privacy: .public)")
                    return nil
                }
            }

            // A bypassed plugin is instantiated but left out of the graph
            // entirely, so no audio passes through it and it costs no CPU —
            // `shouldBypassEffect` alone still renders, which is why the
            // plugin's own meters kept moving. Keeping the instance alive is
            // what makes re-enabling instant and preset switching click-free
            // (§6a).
            var before: [PluginHost] = []
            for item in settings.pluginsBeforeEQ {
                guard let created = await host(for: item) else { continue }
                created.isBypassed = item.isBypassed
                if !item.isBypassed { before.append(created) }
            }
            var after: [PluginHost] = []
            for item in settings.pluginsAfterEQ {
                guard let created = await host(for: item) else { continue }
                created.isBypassed = item.isBypassed
                if !item.isBypassed { after.append(created) }
            }

            guard !Task.isCancelled else { return }

            // Drop instances no longer referenced, returning their RAM (§4).
            let referenced = Set(settings.processing.map(\.id))
            hosts = hosts.filter { referenced.contains($0.key) }
            self.liveHosts[chain] = hosts

            let graph = ProcessingGraph(before: before, after: after)
            self.eq(for: chain).graphs.publish(graph)
            self.pluginLatencyFrames[chain] = graph.latencyFrames
            self.pluginFailure = failure
            Self.log.notice("""
                \(chain.title, privacy: .public) graph: \
                \(AudioEngine.describe(graph), privacy: .public)
                """)
        }
    }

    /// A graph built only from instances already loaded, or nil when something
    /// would have to be instantiated.
    private func graphFromLiveHosts(settings: ChainSettings, chain: Chain) -> ProcessingGraph? {
        let hosts = liveHosts[chain] ?? [:]
        var before: [PluginHost] = []
        var after: [PluginHost] = []

        for item in settings.processing where !item.isEQ {
            guard let descriptor = item.descriptor,
                  let host = hosts[item.id],
                  host.descriptor.id == descriptor.id
            else { return nil }
            host.isBypassed = item.isBypassed
        }
        for item in settings.pluginsBeforeEQ {
            guard let host = hosts[item.id] else { return nil }
            if !item.isBypassed { before.append(host) }
        }
        for item in settings.pluginsAfterEQ {
            guard let host = hosts[item.id] else { return nil }
            if !item.isBypassed { after.append(host) }
        }
        return ProcessingGraph(before: before, after: after)
    }

    private static func describe(_ graph: ProcessingGraph) -> String {
        let names = graph.before.map { "\($0.descriptor.name) (pre)" }
            + graph.after.map { "\($0.descriptor.name) (post)" }
        return names.isEmpty ? "EQ only" : names.joined(separator: ", ")
    }

    /// Captures each plugin's own state so it can be persisted with the chain.
    func capturePluginStates(for chain: Chain) {
        var settings = settings(for: chain)
        var changed = false
        for index in settings.processing.indices {
            let item = settings.processing[index]
            guard !item.isEQ, let host = liveHosts[chain]?[item.id] else { continue }
            let state = host.fullState
            if state != item.state {
                settings.processing[index].state = state
                changed = true
            }
        }
        if changed { setSettings(settings, for: chain) }
    }

    func pluginHost(for item: ProcessingItem, chain: Chain) -> PluginHost? {
        liveHosts[chain]?[item.id]
    }

    // MARK: - Undo

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func undo() {
        guard let step = history.undo() else { return }
        history.withApplying { setSettings(step.settings, for: step.chain) }
    }

    func redo() {
        guard let step = history.redo() else { return }
        history.withApplying { setSettings(step.settings, for: step.chain) }
    }

    // MARK: - Presets

    func loadedPresetID(for chain: Chain) -> UUID? {
        chain == .a ? loadedPresetA : loadedPresetB
    }

    func loadedPreset(for chain: Chain) -> Preset? {
        presets.preset(id: loadedPresetID(for: chain))
    }

    /// Whether the chain has drifted from the preset it was loaded from.
    /// Silently discarding an hour of tweaking on a preset switch is the kind of
    /// thing that makes a tool untrustworthy, so this is surfaced.
    func hasUnsavedChanges(_ chain: Chain) -> Bool {
        guard let preset = loadedPreset(for: chain) else { return false }
        return preset.settings != settings(for: chain)
    }

    private func setLoadedPreset(_ id: UUID?, for chain: Chain) {
        if chain == .a {
            loadedPresetA = id
            defaults.set(id?.uuidString, forKey: Keys.presetA)
        } else {
            loadedPresetB = id
            defaults.set(id?.uuidString, forKey: Keys.presetB)
        }
    }

    /// EQ coefficients ramp through SetTargets and gain through `GainRamp`, so
    /// this is click-free without any special handling.
    func loadPreset(_ preset: Preset, into chain: Chain) {
        setSettings(preset.settings, for: chain)
        setLoadedPreset(preset.id, for: chain)
    }

    /// Captures first: a plugin's own settings live inside the plugin until
    /// asked for, so a preset saved without this records the curve and misses
    /// everything the plugin was set to.
    func savePresetAsNew(named name: String, from chain: Chain) {
        capturePluginStates(for: chain)
        let preset = presets.add(name: name, settings: settings(for: chain))
        setLoadedPreset(preset.id, for: chain)
    }

    func updateLoadedPreset(from chain: Chain) {
        guard let id = loadedPresetID(for: chain) else { return }
        capturePluginStates(for: chain)
        presets.update(id: id, settings: settings(for: chain))
    }

    func deletePreset(_ id: UUID) {
        presets.delete(id: id)
        for chain in Chain.allCases where loadedPresetID(for: chain) == id {
            setLoadedPreset(nil, for: chain)
        }
    }

    // MARK: - Parameters

    /// Trim actually sent to the audio thread. Auto-trim is derived here rather
    /// than written back into `inputTrimDB`, which would recurse through the
    /// `didSet` that triggered it and would destroy the manual value.
    /// Deliberately independent of whether the EQ is switched on. Letting the
    /// trim jump back to zero when the EQ is bypassed makes the bypassed path
    /// louder, and a louder A/B always wins — which is the exact comparison this
    /// control exists to keep honest (§3.3).
    func effectiveTrimDB(for chain: Chain) -> Float {
        let settings = settings(for: chain)
        guard settings.autoTrim else { return settings.inputTrimDB }
        let boost = EQCurveCache.maximumBoostDB(bands: settings.eq.bands,
                                                adaptiveQ: settings.eq.adaptiveQ,
                                                sampleRate: eqSampleRate)
        return Float(max(min(-boost, 0), Double(ChainSettings.trimRange.lowerBound)))
    }

    /// Undoes the EQ's average level change, so switching the EQ off does not
    /// also change loudness and hand the comparison to whichever side is louder
    /// (§3.3). Zero when the EQ is off, because then there is nothing to undo.
    func loudnessMatchDB(for chain: Chain) -> Float {
        let settings = settings(for: chain)
        guard settings.loudnessMatch, settings.eq.isEnabled else { return 0 }
        let average = EQCurveCache.averageGainDB(bands: settings.eq.bands,
                                                 adaptiveQ: settings.eq.adaptiveQ,
                                                 sampleRate: eqSampleRate)
        return Float(-average)
    }

    private func publishParameters() {
        parameters.publish(EngineParameters(
            a: ChainParameters(isActive: isChainActive(.a),
                               eqMakeup: Decibels.toLinear(loudnessMatchDB(for: .a)),
                               inputTrim: Decibels.toLinear(effectiveTrimDB(for: .a)),
                               outputGain: Decibels.toLinear(chainA.outputGainDB)),
            b: ChainParameters(isActive: isChainActive(.b),
                               eqMakeup: Decibels.toLinear(loudnessMatchDB(for: .b)),
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
        let trimRampA = self.trimRampA
        let trimRampB = self.trimRampB
        let gainRampA = self.gainRampA
        let gainRampB = self.gainRampB
        let makeupRampA = self.makeupRampA
        let makeupRampB = self.makeupRampB
        return { buffers in
            let values = parameters.current()
            let frames = buffers.frameCount
            let bytes = frames * MemoryLayout<Float>.size

            if values.a.isActive {
                memcpy(buffers.chainAL, buffers.inputL, bytes)
                memcpy(buffers.chainAR, buffers.inputR, bytes)
                trimRampA.apply(target: values.a.inputTrim,
                                left: buffers.chainAL, right: buffers.chainAR, frames: frames)
                eqA.process(left: buffers.chainAL, right: buffers.chainAR,
                             frames: frames, timestamp: buffers.timestamp)
                makeupRampA.apply(target: values.a.eqMakeup,
                                  left: buffers.chainAL, right: buffers.chainAR,
                                  frames: frames)
                gainRampA.apply(target: values.a.outputGain,
                                left: buffers.chainAL, right: buffers.chainAR, frames: frames)
            }
            if values.b.isActive {
                memcpy(buffers.chainBL, buffers.inputL, bytes)
                memcpy(buffers.chainBR, buffers.inputR, bytes)
                trimRampB.apply(target: values.b.inputTrim,
                                left: buffers.chainBL, right: buffers.chainBR, frames: frames)
                eqB.process(left: buffers.chainBL, right: buffers.chainBR,
                             frames: frames, timestamp: buffers.timestamp)
                makeupRampB.apply(target: values.b.eqMakeup,
                                  left: buffers.chainBL, right: buffers.chainBR,
                                  frames: frames)
                gainRampB.apply(target: values.b.outputGain,
                                left: buffers.chainBL, right: buffers.chainBR, frames: frames)
            }
        }
    }

    // MARK: - Metering

    private func startMeterPolling() {
        meterTask = Task { @MainActor [weak self] in
            var lastCallbacks: UInt64 = 0
            var stalledPolls = 0
            while !Task.isCancelled {
                let idle = !(self?.wantsFastMeters ?? false)
                try? await Task.sleep(for: .milliseconds(idle ? 500 : 50))
                guard let self else { return }
                guard let source = self.source else {
                    self.meters = BlackHoleSource.Meters()
                    self.levels = DisplayLevels()
                    lastCallbacks = 0
                    continue
                }
                let interval = idle ? 0.5 : 0.05

                // Backstop for a missed rate-change notification. This is not
                // cosmetic: EQ coefficients are computed for a specific sample
                // rate, so running at a rate we do not know about detunes every
                // band.
                let actual = source.currentSampleRate
                if actual > 0, abs(actual - self.sampleRate) > 1 {
                    Self.log.error("""
                        sample rate drifted: engine=\(self.sampleRate, privacy: .public) \
                        aggregate=\(actual, privacy: .public) — rebuilding
                        """)
                    self.restart()
                    continue
                }

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

        // Scope matters: Core Audio matches a listener's address exactly.
        // kAudioDevicePropertyNominalSampleRate is a *global* property, so
        // registering it against the output scope silently never fires.
        let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
        ]
        for (selector, scope) in watched {
            interfaceListeners.append(PropertyListener(
                object: interface.id,
                address: CA.address(selector, scope: scope),
                queue: listenerQueue) { [weak self] in
                    Task { @MainActor in
                        AudioEngine.log.notice(
                            "interface property changed: \(CA.describe(OSStatus(bitPattern: selector)), privacy: .public)")
                        self?.restart()
                    }
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
                Self.log.notice("""
                    hardware change -> restart: \
                    uid \(previousInterfaceUID ?? "nil", privacy: .public) -> \
                    \(self.interface?.uid ?? "nil", privacy: .public), \
                    rate \(previousSampleRate ?? -1, privacy: .public) -> \
                    \(self.interface?.sampleRate ?? -1, privacy: .public)
                    """)
                restart()
            }
        case .waiting:
            if interface != nil, capture != nil, microphoneAccess == .authorized {
                Self.log.notice("hardware change -> restart from waiting")
                restart()
            }
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
                AudioEngine.log.notice("didWake -> start")
                self?.start()
            }
        }
    }
}
