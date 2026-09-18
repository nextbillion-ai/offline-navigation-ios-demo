// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NextBillionNavigationLocal",
    platforms: [.iOS(.v13)],
    products: [
        .library(
            name: "NbmapNavigation",
            targets: ["NbmapNavigation", "NbmapCoreNavigation", "Nbmap", "Turf"]
        )
    ],
    targets: [
        .binaryTarget(name: "NbmapNavigation", path: "Artifacts/NbmapNavigation.xcframework"),
        .binaryTarget(name: "NbmapCoreNavigation", path: "Artifacts/NbmapCoreNavigation.xcframework"),
        .binaryTarget(name: "Nbmap", path: "Artifacts/Nbmap.xcframework"),
        .binaryTarget(name: "Turf", path: "Artifacts/Turf.xcframework")
    ]
)
