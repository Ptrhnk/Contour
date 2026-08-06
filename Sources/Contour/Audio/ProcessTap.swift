import CoreAudio
import Foundation
import os

/// A muted global process tap: system audio arrives here, and the original path
/// is silenced so Contour renders the only audible copy.
///
/// Measured properties this relies on, none of them assumed:
///
/// - The mute engages only while the tap is **running** on an aggregate. A tap
///   that is merely created changes nothing audible.
/// - The mute dies with the process. A `SIGKILL` with no teardown left no tap
///   behind and audio returned by itself, which is what makes this safe to ship
///   at all — a stuck system-wide mute would be the worst possible failure.
///
/// Taps arrived in macOS 14.2; the app targets 14.4, but the availability
/// annotation is what lets the compiler agree.
@available(macOS 14.2, *)
final class ProcessTap {

    let id: AudioObjectID
    let uuid: String

    private var destroyed = false
    private static let log = Logger(subsystem: "com.nahak.contour", category: "tap")

    /// - Parameter excluding: processes whose audio must not be captured.
    ///   Contour's own is mandatory, or the render feeds back into itself.
    init(excluding pids: [pid_t]) throws {
        let objects = pids.compactMap(Self.processObject(forPID:))
        guard objects.count == pids.count else {
            throw CA.Failure(status: nil,
                             what: "could not translate every PID to an audio process object")
        }

        // The refined ObjC name: Swift gets no nicer spelling for this.
        let description = CATapDescription(
            __stereoGlobalTapButExcludeProcesses: objects.map(NSNumber.init(value:)))
        description.name = "Contour"
        description.isPrivate = true
        // The enum cases do not import; 1 is CATapMuted.
        description.muteBehavior = CATapMuteBehavior(rawValue: 1) ?? .init(rawValue: 0)!

        var tapID = AudioObjectID(0)
        try CA.check(AudioHardwareCreateProcessTap(description, &tapID), "create process tap")
        guard tapID != 0 else {
            throw CA.Failure(status: nil, what: "process tap created with id 0")
        }
        id = tapID
        uuid = description.uuid.uuidString
        Self.log.notice("tap \(tapID, privacy: .public) created")
    }

    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        AudioHardwareDestroyProcessTap(id)
        Self.log.notice("tap \(self.id, privacy: .public) destroyed")
    }

    deinit { destroy() }

    /// `CATapDescription` wants audio *process object* IDs. Handing it a Unix
    /// PID fails with `kAudioHardwareBadObjectError` and logs "can't find
    /// specified process object", which reads like a permissions problem.
    private static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var input = pid
        var object = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address,
                                                UInt32(MemoryLayout<pid_t>.size), &input,
                                                &size, &object)
        return status == noErr && object != 0 ? object : nil
    }

    /// Taps still alive in the system, which is the recovery path if one is ever
    /// leaked by a build that crashed before this class existed.
    static func liveTapIDs() -> [AudioObjectID] {
        let address = CA.address(kAudioHardwarePropertyTapList)
        return ((try? CA.array(AudioObjectID(kAudioObjectSystemObject),
                               address, of: AudioObjectID.self)) ?? []).filter { $0 != 0 }
    }
}
