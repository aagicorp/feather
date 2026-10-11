// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Feather",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
        // In-app updates. It does nothing until build.sh puts a feed URL into Info.plist (release builds only).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // Syntax trees for highlighting and folding: the tree-sitter runtime, brought in by SwiftTreeSitter (ChimeHQ's
        // package, now under the tree-sitter organisation). The editor calls the C runtime itself (SyntaxTree.swift).
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter", .upToNextMinor(from: "0.25.0")),
        // Grammars, one C target each; the queries they ship are copied into Resources/queries. Four are pinned to
        // older tags: their newer manifests look for src/scanner.c relative to the current directory, which is not
        // the package when it is built as a dependency, and the scanner is left out.
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", from: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-java", from: "0.23.5"),
        .package(url: "https://github.com/UserNobody14/tree-sitter-dart", revision: "be07cf7118d3dba06236a3f19541685a68209934"),
        .package(url: "https://github.com/fwcd/tree-sitter-kotlin", from: "0.3.8"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.3-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", from: "0.23.2"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", from: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", from: "0.24.2"),
    ],
    targets: [
        .executableTarget(
            name: "Feather",
            dependencies: [
                "SwiftTerm", .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitter", package: "tree-sitter"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
                .product(name: "TreeSitterDart", package: "tree-sitter-dart"),
                .product(name: "TreeSitterKotlin", package: "tree-sitter-kotlin"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
            ],
            path: "Sources/Feather",
            // Inside Feather.app the framework lives in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // `swift test`: the parts that need no window (terminal heuristics, symbol scanning, git parsing…).
        .testTarget(name: "FeatherTests", dependencies: ["Feather"], path: "Tests/FeatherTests", exclude: ["README.md"]),
    ]
)
