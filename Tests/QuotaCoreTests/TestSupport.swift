import Foundation

/// 极简测试框架。
///
/// 为什么不用 XCTest：XCTest.framework 只随完整 Xcode 提供，只装 Command Line Tools
/// 的机器上既没有它，也没有 `xcrun xctest` 可以运行测试包。为了让 `./scripts/test.sh`
/// 在任何 Mac 上都能跑，这里自带一套断言与执行器，不依赖任何测试框架。

/// 一个用例的失败记录。
struct TestFailure {
    let test: String
    let message: String
    let file: String
    let line: UInt
}

/// 断言失败。抛出它即结束当前用例，但不会中断整个测试运行。
struct AssertionFailure: Error {
    let message: String
    let file: String
    let line: UInt
}

enum Expect {
    static func isTrue(
        _ condition: Bool,
        _ message: @autoclosure () -> String = "条件为假",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard condition else {
            throw AssertionFailure(message: message(), file: "\(file)", line: line)
        }
    }

    static func equal<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard actual == expected else {
            let detail = message().isEmpty ? "" : "（\(message())）"
            throw AssertionFailure(
                message: "期望 \(expected)，实际 \(actual)\(detail)",
                file: "\(file)",
                line: line)
        }
    }

    static func equal(
        _ actual: Double,
        _ expected: Double,
        accuracy: Double,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard abs(actual - expected) <= accuracy else {
            let detail = message().isEmpty ? "" : "（\(message())）"
            throw AssertionFailure(
                message: "期望 \(expected) ±\(accuracy)，实际 \(actual)\(detail)",
                file: "\(file)",
                line: line)
        }
    }

    static func notNil<T>(
        _ value: T?,
        _ message: @autoclosure () -> String = "值不应为 nil",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        guard let value else {
            throw AssertionFailure(message: message(), file: "\(file)", line: line)
        }
        return value
    }

    static func isNil<T>(
        _ value: T?,
        _ message: @autoclosure () -> String = "值应为 nil",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard value == nil else {
            throw AssertionFailure(
                message: "\(message())，实际为 \(value!)",
                file: "\(file)",
                line: line)
        }
    }

    /// 断言表达式抛出错误，并把错误交给 `check` 做进一步判断。
    static func throwsError<T>(
        _ expression: @autoclosure () throws -> T,
        _ check: (Error) throws -> Void = { _ in },
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        do {
            _ = try expression()
            throw AssertionFailure(message: "期望抛出错误，但没有", file: "\(file)", line: line)
        } catch let failure as AssertionFailure {
            throw failure
        } catch {
            try check(error)
        }
    }
}

/// 一个测试套件。
struct TestSuite {
    let name: String
    let cases: [(String, () throws -> Void)]

    init(_ name: String, _ cases: [(String, () throws -> Void)]) {
        self.name = name
        self.cases = cases
    }
}

/// 执行所有套件并打印结果。返回进程退出码。
enum TestRunner {
    static func run(_ suites: [TestSuite]) -> Int32 {
        var passed = 0
        var failures: [TestFailure] = []
        let started = Date()

        for suite in suites {
            print("\n\u{001B}[1m\(suite.name)\u{001B}[0m")
            for (name, body) in suite.cases {
                do {
                    try body()
                    passed += 1
                    print("  \u{001B}[32m✓\u{001B}[0m \(name)")
                } catch let failure as AssertionFailure {
                    failures.append(TestFailure(
                        test: "\(suite.name) › \(name)",
                        message: failure.message,
                        file: failure.file,
                        line: failure.line))
                    print("  \u{001B}[31m✗\u{001B}[0m \(name)")
                } catch {
                    failures.append(TestFailure(
                        test: "\(suite.name) › \(name)",
                        message: "未捕获的错误：\(error)",
                        file: "", line: 0))
                    print("  \u{001B}[31m✗\u{001B}[0m \(name)")
                }
            }
        }

        let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
        print("")
        if failures.isEmpty {
            print("\u{001B}[32m全部通过\u{001B}[0m：\(passed) 个用例，耗时 \(elapsed)s")
            return 0
        }

        print("\u{001B}[31m失败 \(failures.count) 个\u{001B}[0m，通过 \(passed) 个，耗时 \(elapsed)s")
        for failure in failures {
            let location = failure.file.isEmpty ? "" : "（\(failure.file):\(failure.line)）"
            print("  • \(failure.test)：\(failure.message) \(location)")
        }
        return 1
    }
}

/// 测试里构造 JSON 对象用的小工具。
func jsonObject(_ text: String) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text.utf8))
}