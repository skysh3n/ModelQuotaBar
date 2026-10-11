import Foundation

/// 控制台网关的响应嵌套层级很深，且不同接口/不同版本的外层信封会变
/// （`data.DataV2.data.data`、数组、或直接就是业务对象）。
/// 这里用深度优先查找代替硬编码路径，避免因为信封多包或少包一层就解析失败。
enum JSONSearch {
    /// 在任意深度上查找第一个「同时包含指定全部键」的对象。
    ///
    /// 用于定位业务数据所在的那一层，例如同时含 `specCode` 与 `status` 的订阅对象。
    static func findObject(
        containingAllOf keys: [String],
        in value: Any
    ) -> [String: Any]? {
        guard !keys.isEmpty else { return nil }
        if let dictionary = value as? [String: Any] {
            if keys.allSatisfy({ dictionary[$0] != nil }) {
                return dictionary
            }
            for child in dictionary.values {
                if let found = findObject(containingAllOf: keys, in: child) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findObject(containingAllOf: keys, in: child) {
                    return found
                }
            }
        }
        return nil
    }

    /// 在任意深度上查找第一个含指定任一键的对象。
    static func findObject(
        containingAnyOf keys: [String],
        in value: Any
    ) -> [String: Any]? {
        guard !keys.isEmpty else { return nil }
        if let dictionary = value as? [String: Any] {
            if keys.contains(where: { dictionary[$0] != nil }) {
                return dictionary
            }
            for child in dictionary.values {
                if let found = findObject(containingAnyOf: keys, in: child) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findObject(containingAnyOf: keys, in: child) {
                    return found
                }
            }
        }
        return nil
    }

    /// 在任意深度上查找指定键的第一个非空值。
    static func findValue(forKeys keys: [String], in value: Any) -> Any? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let found = dictionary[key], !(found is NSNull) {
                    return found
                }
            }
            for child in dictionary.values {
                if let found = findValue(forKeys: keys, in: child) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findValue(forKeys: keys, in: child) {
                    return found
                }
            }
        }
        return nil
    }

    /// 把字符串或数字统一转成 `Double`。
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            double.isFinite ? double : nil
        case let int as Int:
            Double(int)
        case let number as NSNumber:
            number.doubleValue.isFinite ? number.doubleValue : nil
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespaces))
        default:
            nil
        }
    }

    /// 把字符串或数字统一转成 `String`，空串视为 nil。
    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    /// 解析时间戳。网关同时存在毫秒与秒两种量级，按数值大小判断。
    static func date(_ value: Any?) -> Date? {
        guard let raw = number(value), raw > 0 else { return nil }
        // 1e11 秒 ≈ 公元 5138 年，真实时间戳不会超过它，超过即视为毫秒。
        let seconds = raw > 1e11 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}