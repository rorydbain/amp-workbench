// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AmpWorkbench", platforms: [.macOS(.v14), .iOS(.v17)], products: [
    .library(name: "AmpCore", targets: ["AmpCore"]),
    .library(name: "AmpMIDI", targets: ["AmpMIDI"]),
    .executable(name: "AmpWorkbench", targets: ["AmpWorkbench"]),
    .executable(name: "ampctl", targets: ["ampctl"]),
    .executable(name: "ampcheck", targets: ["ampcheck"])
], dependencies: [
    .package(url: "https://github.com/weichsel/ZIPFoundation.git", .exact("0.9.20"))
], targets: [
    .target(name: "AmpCore", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")], resources: [.process("Resources")]),
    .target(name: "AmpMIDI", dependencies: ["AmpCore"], linkerSettings: [.linkedFramework("CoreMIDI"), .linkedFramework("CoreBluetooth")]),
    .executableTarget(name: "AmpWorkbench", dependencies: ["AmpCore", "AmpMIDI"], linkerSettings: [.linkedFramework("CoreAudioKit")]),
    .executableTarget(name: "ampctl", dependencies: ["AmpCore", "AmpMIDI"]),
    .executableTarget(name: "ampcheck", dependencies: ["AmpCore", "AmpMIDI"]),
    .testTarget(name: "AmpCoreTests", dependencies: ["AmpCore", "AmpMIDI"])
], swiftLanguageModes: [.v5])
