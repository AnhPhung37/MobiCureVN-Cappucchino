import Foundation

public struct ToolExecutor: Sendable {
    public init() {}

    public func execute(name: String, args: [String: Any]) -> String {
        guard name == "calculator" else {
            return "Unknown tool: \(name)."
        }
        guard let expression = args["expression"] as? String else {
            return "Invalid tool arguments."
        }
        guard let result = SimpleCalculator.evaluate(expression) else {
            return "Invalid expression."
        }
        return String(result)
    }
}

private enum SimpleCalculator {
    static func evaluate(_ expression: String) -> Double? {
        let cleaned = expression.replacingOccurrences(of: " ", with: "")
        let operators: [Character] = ["+", "-", "*", "/"]
        for op in operators {
            if let index = cleaned.firstIndex(of: op) {
                let lhs = String(cleaned[..<index])
                let rhs = String(cleaned[cleaned.index(after: index)...])
                guard let left = Double(lhs), let right = Double(rhs) else { return nil }
                switch op {
                case "+": return left + right
                case "-": return left - right
                case "*": return left * right
                case "/": return right == 0 ? nil : left / right
                default: return nil
                }
            }
        }
        return Double(cleaned)
    }
}
