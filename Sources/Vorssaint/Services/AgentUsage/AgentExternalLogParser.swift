// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Parsers for the local JSONL formats used by Grok Build, Kiro CLI and Pi.
/// They reduce records to counters and turn boundaries; message contents are
/// never copied into the usage store.
extension AgentLogParser {
    static func seed(path: String, provider: AgentProvider, state: inout AgentLogState) {
        let url = URL(fileURLWithPath: path)
        switch provider {
        case .grok:
            let encodedProject = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            if let projectPath = encodedProject.removingPercentEncoding, projectPath.hasPrefix("/") {
                state.project = projectName(projectPath)
            }
            if state.session.isEmpty { state.session = url.deletingLastPathComponent().lastPathComponent }
        case .kiro:
            if state.session.isEmpty {
                let parent = url.deletingLastPathComponent().lastPathComponent
                state.session = parent.hasPrefix("sess_") ? String(parent.dropFirst(5)) : url.deletingPathExtension().lastPathComponent
            }
        case .pi:
            break // Pi's session header contains its real working directory.
        default:
            break
        }
    }

    static func parseGrok(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let params = json["params"] as? [String: Any],
              let update = params["update"] as? [String: Any] else { return [] }
        if let session = params["sessionId"] as? String, !session.isEmpty { state.session = native(session) }
        let metadata = params["_meta"] as? [String: Any] ?? [:]
        let date = timestamp(metadata["agentTimestampMs"]) ?? timestamp(json["timestamp"]) ?? now
        let kind = update["sessionUpdate"] as? String ?? ""
        var entries: [AgentLogEntry] = []

        switch kind {
        case "user_message_chunk":
            if state.turnOpen { entries.append(.turnActive(date)) }
            else {
                state.turnOpen = true
                entries.append(.turnBegan(date))
            }
        case "agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update":
            if state.turnOpen { entries.append(.turnActive(date)) }
        case "turn_completed":
            if let usage = update["usage"] as? [String: Any] {
                let prompt = update["prompt_id"] as? String ?? metadata["promptId"] as? String
                    ?? metadata["eventId"] as? String ?? "\(date.timeIntervalSince1970)"
                let modelUsage = usage["modelUsage"] as? [String: [String: Any]] ?? [:]
                let models = modelUsage.isEmpty ? [(state.model.isEmpty ? "Grok" : state.model, usage)]
                    : modelUsage.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
                for (model, values) in models {
                    let inputTotal = int(values["inputTokens"])
                    let cacheRead = int(values["cachedReadTokens"])
                    let cacheWrite = int(values["cacheCreationTokens"])
                    let output = int(values["outputTokens"])
                    let reasoning = int(values["reasoningTokens"])
                    let tokens = AgentTokens(input: max(0, inputTotal - cacheRead - cacheWrite),
                                             cacheWrite: cacheWrite, cacheRead: cacheRead,
                                             output: output, reasoning: reasoning)
                    guard tokens.total > 0 || int(values["costUsdTicks"]) > 0 else { continue }
                    let cost = Double(int(values["costUsdTicks"])) / 10_000_000_000
                    let billable = AgentBillable(tokens: tokens)
                    let key = "grok:\(state.session):\(prompt):\(model)"
                    entries.append(.usage(key: key, record: AgentUsageRecord(
                        provider: .grok, date: date, model: native(model), project: state.project,
                        session: state.session, tokens: tokens, cost: cost, savings: 0, reportedCost: true
                    ), billable: billable))
                }
            }
            if state.turnOpen {
                state.turnOpen = false
                entries.append(.turnEnded(date, completed: true, duration: nil))
            }
        default:
            break
        }
        return entries
    }

    static func parseKiro(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return [] }
        let date = timestamp(json["timestamp"]) ?? now

        // Current Kiro sessions are event records wrapped in `payload`.
        if let payload = json["payload"] as? [String: Any], let kind = payload["type"] as? String {
            if kind == "session_start", let session = payload["sessionId"] as? String, !session.isEmpty {
                state.session = native(session)
            }
            if kind == "assistant" {
                let meta = payload["_meta"] as? [String: Any] ?? [:]
                let kiro = meta["kiro"] as? [String: Any] ?? [:]
                if let model = payload["reasoningModelId"] as? String ?? kiro["reasoningModelId"] as? String,
                   !model.isEmpty { state.model = native(model) }
            }
            switch kind {
            case "turn_start":
                state.turnOpen = true
                return [.turnBegan(date)]
            case "turn_end":
                guard state.turnOpen else { return [] }
                state.turnOpen = false
                let stop = (payload["stopReason"] as? String ?? "").lowercased()
                return [.turnEnded(date, completed: !["error", "aborted", "cancelled", "canceled"].contains(stop), duration: nil)]
            case "user":
                if state.turnOpen { return [.turnActive(date)] }
                state.turnOpen = true
                return [.turnBegan(date)]
            case "assistant", "tool_call", "tool_result", "pending_interaction", "interaction_resolved":
                return state.turnOpen ? [.turnActive(date)] : []
            default:
                // Kiro's usage_summary reports subscription credits and
                // context percentages, not tokens or a dollar charge.
                return []
            }
        }

        // Kiro 2.x classic sessions use Prompt/AssistantMessage/ToolResults.
        let kind = json["kind"] as? String ?? ""
        let data = json["data"] as? [String: Any] ?? [:]
        let messageDate = timestamp((data["meta"] as? [String: Any])?["timestamp"]) ?? date
        switch kind {
        case "Prompt":
            var entries: [AgentLogEntry] = []
            if state.turnOpen { entries.append(.turnEnded(messageDate, completed: true, duration: nil)) }
            state.turnOpen = true
            entries.append(.turnBegan(messageDate))
            return entries
        case "AssistantMessage", "ToolResults":
            var hasToolUse = false
            if kind == "AssistantMessage", let blocks = data["content"] as? [[String: Any]] {
                for block in blocks {
                    if block["kind"] as? String == "toolUse" { hasToolUse = true }
                    if let value = block["data"] as? [String: Any],
                       let model = value["modelId"] as? String, !model.isEmpty { state.model = native(model) }
                }
            }
            guard state.turnOpen else { return [] }
            if kind == "AssistantMessage", !hasToolUse,
               let blocks = data["content"] as? [[String: Any]], !blocks.isEmpty {
                state.turnOpen = false
                return [.turnEnded(messageDate, completed: true, duration: nil)]
            }
            // Legacy Kiro transcripts omit timestamps on model and tool
            // records. The file modification time is the freshest reliable
            // activity signal and keeps old completed logs from looking live.
            return [.turnActive(nil)]
        default:
            return []
        }
    }

    static func parsePi(_ line: Data, state: inout AgentLogState, now: Date) -> [AgentLogEntry] {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return [] }
        let type = json["type"] as? String ?? ""
        let outerDate = timestamp(json["timestamp"]) ?? now
        if type == "session" {
            if let session = json["id"] as? String { state.session = native(session) }
            if let cwd = json["cwd"] as? String, !cwd.isEmpty { state.project = projectName(cwd) }
            return []
        }
        if type == "model_change" {
            let provider = json["provider"] as? String ?? ""
            let model = json["modelId"] as? String ?? ""
            if !model.isEmpty { state.model = native(provider.isEmpty ? model : "\(provider)/\(model)") }
            return []
        }
        guard type == "message", let message = json["message"] as? [String: Any],
              let role = message["role"] as? String else { return [] }
        let date = timestamp(message["timestamp"]) ?? outerDate
        switch role {
        case "user":
            if state.turnOpen { return [.turnActive(date)] }
            state.turnOpen = true
            return [.turnBegan(date)]
        case "toolResult":
            return state.turnOpen ? [.turnActive(date)] : []
        case "assistant":
            if let provider = message["provider"] as? String, let model = message["model"] as? String {
                state.model = native("\(provider)/\(model)")
            } else if let model = message["model"] as? String { state.model = native(model) }
            var entries: [AgentLogEntry] = []
            let usage = message["usage"] as? [String: Any] ?? [:]
            let tokens = AgentTokens(input: int(usage["input"]), cacheWrite: int(usage["cacheWrite"]),
                                     cacheRead: int(usage["cacheRead"]), output: int(usage["output"]),
                                     reasoning: int(usage["reasoning"]))
            let costFields = usage["cost"] as? [String: Any] ?? [:]
            let rawCost = (costFields["total"] as? NSNumber)?.doubleValue
            let hasReportedCost = rawCost.map { $0.isFinite && $0 >= 0 } == true
            if tokens.total > 0 || (hasReportedCost && rawCost! > 0) {
                let id = json["id"] as? String ?? "\(date.timeIntervalSince1970)"
                let cost = hasReportedCost ? rawCost : nil
                let billable = AgentBillable(tokens: tokens)
                entries.append(.usage(key: "pi:\(id):\(date.timeIntervalSince1970):\(state.model)", record: AgentUsageRecord(
                    provider: .pi, date: date, model: state.model, project: state.project, session: state.session,
                    tokens: tokens, cost: cost, savings: 0, reportedCost: cost != nil
                ), billable: billable))
            }
            switch message["stopReason"] as? String {
            case "stop", "length":
                if state.turnOpen {
                    state.turnOpen = false
                    entries.append(.turnEnded(date, completed: true, duration: nil))
                }
            case "error", "aborted":
                if state.turnOpen {
                    state.turnOpen = false
                    entries.append(.turnEnded(date, completed: false, duration: nil))
                }
            default:
                if state.turnOpen { entries.append(.turnActive(date)) }
            }
            return entries
        default:
            return []
        }
    }
}
