// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Lumio", platforms: [.macOS(.v15)], products: [.executable(name: "Lumio", targets: ["Lumio"])], targets: [.executableTarget(name: "Lumio")], swiftLanguageModes: [.v5])
