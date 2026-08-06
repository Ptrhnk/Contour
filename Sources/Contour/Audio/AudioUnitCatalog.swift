import AVFoundation
import Observation
import os

/// One installed effect, reduced to what is needed to show it and re-find it later.
struct AudioUnitDescriptor: Identifiable, Hashable, Codable, Sendable {
    var name: String
    var manufacturer: String
    var componentType: OSType
    var componentSubType: OSType
    var componentManufacturer: OSType

    /// Stable across launches and machines, unlike an `AVAudioUnitComponent`
    /// reference, so presets can name a plugin without holding onto it.
    var id: String {
        "\(componentType.fourCharacterCode)/"
            + "\(componentSubType.fourCharacterCode)/"
            + "\(componentManufacturer.fourCharacterCode)"
    }

    var audioComponentDescription: AudioComponentDescription {
        AudioComponentDescription(componentType: componentType,
                                  componentSubType: componentSubType,
                                  componentManufacturer: componentManufacturer,
                                  componentFlags: 0,
                                  componentFlagsMask: 0)
    }

    init(_ component: AVAudioUnitComponent) {
        name = component.name
        manufacturer = component.manufacturerName
        componentType = component.audioComponentDescription.componentType
        componentSubType = component.audioComponentDescription.componentSubType
        componentManufacturer = component.audioComponentDescription.componentManufacturer
    }
}

extension OSType {
    var fourCharacterCode: String {
        let bytes = [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
                     UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
              let text = String(bytes: bytes, encoding: .ascii)
        else { return String(self) }
        return text
    }
}

/// The installed effects, scanned once.
///
/// The scan walks every component on disk and is slow enough to be visible, so
/// it happens off the main thread and the result is kept for the process
/// lifetime. `rescan()` exists for when a plugin is installed while running.
@MainActor
@Observable
final class AudioUnitCatalog {

    private(set) var effects: [AudioUnitDescriptor] = []
    private(set) var isScanning = false

    private static let log = Logger(subsystem: "com.nahak.contour", category: "aucatalog")

    func scanIfNeeded() {
        guard effects.isEmpty, !isScanning else { return }
        rescan()
    }

    func rescan() {
        guard !isScanning else { return }
        isScanning = true
        Task { @MainActor [weak self] in
            let found = await Self.scan()
            guard let self else { return }
            self.effects = found
            self.isScanning = false
            Self.log.notice("found \(found.count, privacy: .public) effect audio units")
        }
    }

    func descriptor(id: String) -> AudioUnitDescriptor? {
        effects.first { $0.id == id }
    }

    private static func scan() async -> [AudioUnitDescriptor] {
        await Task.detached(priority: .userInitiated) {
            let description = AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0)
            return AVAudioUnitComponentManager.shared()
                .components(matching: description)
                .map(AudioUnitDescriptor.init)
                .sorted {
                    ($0.manufacturer.lowercased(), $0.name.lowercased())
                        < ($1.manufacturer.lowercased(), $1.name.lowercased())
                }
        }.value
    }
}
