// swift-tools-version: 6.0
import PackageDescription

// 这个清单只用来给 QuotaCore 建模块、跑单元测试。
//
// 应用本体和小组件扩展是 Xcode 工程（ModelQuotaBar.xcodeproj）里的两个 target，
// 它们各自把 Sources/QuotaCore 的源码直接编进自己的模块 —— 小组件扩展不能依赖
// Swift Package 的产物，这样做也省掉了在工程里嵌一个 framework 的麻烦。
//
// 跑测试：./scripts/test.sh
let package = Package(
    name: "ModelQuotaBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "QuotaCore", targets: ["QuotaCore"]),
    ],
    targets: [
        // 与 Xcode 工程的 SWIFT_VERSION = 5.0 保持一致。QuotaCore 里还有
        // TaskGroup 传 `Any?` 之类的 Swift 5 写法，升级语言模式要单独改代码。
        .target(
            name: "QuotaCore",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)