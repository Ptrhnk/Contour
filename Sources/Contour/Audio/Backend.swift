import Foundation

/// Where system audio is captured from. Everything downstream — chains, EQ,
/// plugins, routing, metering — is identical either way, which is the point of
/// `AudioSource`.
enum Backend: String, CaseIterable, Identifiable, Sendable {
    /// Muted global process tap. Nothing to install, no system output to change.
    case tap
    /// BlackHole 2ch loopback, with the system output pointed at it.
    case blackHole

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tap: "Tap"
        case .blackHole: "BlackHole"
        }
    }

    /// Taps arrived in macOS 14.2. Below that the option is not offered at all
    /// rather than offered and failing.
    static var isTapSupported: Bool {
        if #available(macOS 14.2, *) { true } else { false }
    }

    var isSupported: Bool {
        switch self {
        case .tap: Self.isTapSupported
        case .blackHole: true
        }
    }

    /// What choosing this backend asks of the user, shown next to the switch.
    var requirement: String {
        switch self {
        case .tap: "Captures system audio directly. macOS 14.2 or later."
        case .blackHole: "Needs BlackHole installed and set as the system output."
        }
    }

    static let `default`: Backend = isTapSupported ? .tap : .blackHole
}
