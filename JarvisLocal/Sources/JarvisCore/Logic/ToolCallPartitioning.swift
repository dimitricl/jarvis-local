import Foundation

/// Partition des tool calls + divers purs, extraits à l'identique
/// depuis AppViewModel. Forwarders conservés côté ViewModel.
public enum ToolCallPartitioning {
    public static func partitionFreshToolCalls(_ calls: [ToolCall], seen: inout Set<String>) -> (fresh: [ToolCall], duplicates: [ToolCall]) {
        var fresh: [ToolCall] = []
        var duplicates: [ToolCall] = []
        for tc in calls {
            let sig = "\(tc.function.name):\(tc.function.arguments)"
            if seen.insert(sig).inserted {
                fresh.append(tc)
            } else {
                duplicates.append(tc)
            }
        }
        return (fresh, duplicates)
    }

    public static func partitionBudgetedToolCalls(_ calls: [ToolCall], counts: inout [String: Int], budget: Int) -> (allowed: [ToolCall], refused: [ToolCall]) {
        let limit = max(1, budget)
        var allowed: [ToolCall] = []
        var refused: [ToolCall] = []
        for tc in calls {
            let used = counts[tc.function.name, default: 0]
            if used < limit {
                counts[tc.function.name] = used + 1
                allowed.append(tc)
            } else {
                refused.append(tc)
            }
        }
        return (allowed, refused)
    }

    public static func argsSummary(_ args: [String: Any]) -> String {
        args.sorted { $0.key < $1.key }
            .map { "\($0.key)=\("\($0.value)".prefix(60))" }
            .joined(separator: ", ")
    }

    public static func confirmationKey(for tool: String, sensitive: Set<String>) -> String? {
        if sensitive.contains(tool) { return tool }
        if let native = MCPToolMapping.nativeToMCP.first(where: { $0.value == tool })?.key,
           sensitive.contains(native) {
            return native
        }
        return nil
    }
}
