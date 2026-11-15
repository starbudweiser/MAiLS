// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MAiLS",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "MAiLS", targets: ["MAiLS"]),
        .library(name: "MAiLSCore", targets: ["MAiLSCore"]),
        .executable(name: "mails-bench", targets: ["mails-bench"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.29.0"),
        // Dernière version publiée : 0.5.0 (la 1.0.0-alpha.1 n'existe pas). Épinglée : API encore pré-1.0.
        .package(url: "https://github.com/apple/swift-nio-imap.git", exact: "0.5.0")
    ],
    targets: [
        // Logique de MAiLS, sans aucune interface (voir docs/ARCHITECTURE.md § 2).
        .target(
            name: "MAiLSCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "IMAPCommands", package: "swift-nio-imap")
            ],
            path: "Sources/MAiLSCore"
        ),
        // Application : interface Socle uniquement.
        .executableTarget(
            name: "MAiLS",
            dependencies: [
                "MAiLSCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/MAiLS"
        ),
        // Banc d'essai du moteur en ligne de commande (non livré).
        .executableTarget(
            name: "mails-bench",
            dependencies: ["MAiLSCore"],
            path: "Sources/mails-bench"
        ),
        .testTarget(
            name: "MAiLSCoreTests",
            dependencies: ["MAiLSCore"],
            path: "Tests/MAiLSCoreTests"
        )
    ]
)
