// swift-tools-version:5.10
import Foundation
import PackageDescription

// Everything of the app that is Rust is one static library, signal-backend/corvus-core: the Signal
// backend (run inside the app), the history store's key wrapping and SQLCipher. Build it first:
//   cargo build --release --locked --manifest-path ../signal-backend/Cargo.toml -p corvus-core
// (scripts/build-app.sh does that).
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let cargoTarget = ProcessInfo.processInfo.environment["CARGO_TARGET_DIR"]
    ?? packageDir.appendingPathComponent("../signal-backend/target").standardized.path
let rustLibDir = cargoTarget + "/release"

let package = Package(
    name: "CorvusMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "corvus", targets: ["CorvusMac"]),
    ],
    targets: [
        .systemLibrary(name: "CHistoryStore", path: "Sources/CHistoryStore"),
        // SQLCipher's C interface for the history database (the library is in the Rust static library).
        .systemLibrary(name: "CSQLCipher", path: "Sources/CSQLCipher"),
        .target(
            name: "CorvusCore",
            dependencies: ["CHistoryStore", "CSQLCipher"],
            linkerSettings: [
                .unsafeFlags(["-L", rustLibDir]),
                // What the Rust library needs of the system (cargo rustc -- --print native-static-libs, and
                // BoringSSL's C++).
                .linkedFramework("Security"), .linkedFramework("CoreFoundation"), .linkedFramework("SystemConfiguration"),
                .linkedLibrary("iconv"), .linkedLibrary("c++"),
            ]
        ),
        .executableTarget(
            name: "CorvusMac",
            dependencies: ["CorvusCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "CorvusCoreTests",
            dependencies: ["CorvusCore"]
        ),
    ]
)
