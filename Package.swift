// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Contour",
    platforms: [.macOS(.v14)],
    targets: [
        // One atomic integer for the parameter triple buffer. See the header.
        .target(name: "CContourAtomics"),
        // Pure DSP, no UI and no Core Audio, so it can be unit tested.
        .target(name: "ContourDSP"),
        .executableTarget(
            name: "Contour",
            dependencies: ["CContourAtomics", "ContourDSP"],
            path: "Sources/Contour"
        ),
        .testTarget(name: "ContourDSPTests", dependencies: ["ContourDSP"]),
    ]
)
