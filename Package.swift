// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShelfCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ShelfCore", targets: ["ShelfCore"])],
    targets: [.target(name: "ShelfCore", path: "Sources/ShelfCore/ShelfCore")]
)
