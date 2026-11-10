// swift-tools-version:5.10
import Foundation
import PackageDescription

// The encrypted history store is the Rust crate in ../history-store (shared with the Qt app).
// Build it first: cargo build --release --locked --manifest-path ../history-store/Cargo.toml
// (scripts/build-app.sh does that).
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let rustLibDir = packageDir.appendingPathComponent("../history-store/target/release").standardized.path

let package = Package(
    name: "CorvusMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "corvus", targets: ["CorvusMac"]),
    ],
    targets: [
        .systemLibrary(name: "CHistoryStore", path: "Sources/CHistoryStore"),
        // SQLCipher (SQLite with page encryption) for the history database: the amalgamation, built with
        // the same options as the backend's copy, on CommonCrypto.
        .target(
            name: "CSQLCipher",
            path: "Sources/CSQLCipher",
            exclude: ["LICENSE.sqlcipher"],
            cSettings: [
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCIPHER_CRYPTO_CC"),
                .define("SQLITE_TEMP_STORE", to: "2"),
                .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
                .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_DQS", to: "0"),
                .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
                .define("SQLITE_OMIT_DEPRECATED"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
                .define("SQLITE_OMIT_SHARED_CACHE"),
                .define("SQLITE_USE_URI"),
                .define("HAVE_USLEEP", to: "1"),
                .define("HAVE_STDINT_H", to: "1"),
                .define("NDEBUG"),
                .unsafeFlags(["-w", "-O2"]),
            ],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "CorvusCore",
            dependencies: ["CHistoryStore", "CSQLCipher"],
            linkerSettings: [.unsafeFlags(["-L", rustLibDir])]
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
