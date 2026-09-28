// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FieldKit",
    platforms: [.iOS("16.4"), .macOS(.v14)],
    products: [
        .library(name: "FieldContracts", targets: ["FieldContracts"]),
        .library(name: "FieldData", targets: ["FieldData"]),
        .library(name: "FieldDomain", targets: ["FieldDomain"]),
        .library(name: "FieldRuntime", targets: ["FieldRuntime"]),
        .library(name: "FieldAdapters", targets: ["FieldAdapters"]),
    ],
    targets: [
        .target(name: "FieldContracts"),
        .target(name: "FieldDomain", dependencies: ["FieldContracts"]),
        .target(name: "FieldData", dependencies: ["FieldContracts", "FieldDomain"]),
        .target(name: "FieldAdapters", dependencies: ["FieldContracts", "FieldDomain"]),
        .target(
            name: "FieldRuntime",
            dependencies: ["FieldContracts", "FieldDomain", "FieldData", "FieldAdapters"]),
        .testTarget(name: "FieldContractsTests", dependencies: ["FieldContracts"]),
        .testTarget(name: "FieldDomainTests", dependencies: ["FieldDomain"]),
        .testTarget(name: "FieldDataTests", dependencies: ["FieldData"]),
        .testTarget(name: "FieldAdaptersTests", dependencies: ["FieldAdapters"]),
        .testTarget(
            name: "FieldRuntimeTests",
            dependencies: ["FieldRuntime", "FieldContracts", "FieldDomain", "FieldData"]),
    ],
    swiftLanguageModes: [.v5]
)
