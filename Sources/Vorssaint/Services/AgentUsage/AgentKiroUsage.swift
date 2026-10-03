// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The Kiro CLI's account usage, as printed by its non-interactive `/usage` command.
enum AgentKiroUsage {
    struct Reading {
        let limits: AgentLimits
        let plan: AgentPlan
    }

    static func fetch(home: URL, environment baseEnvironment: [String: String]) -> Reading? {
        let path = executable(home: home, environment: baseEnvironment)
        guard let path else { return nil }

        var environment = baseEnvironment
        let binaryDirectory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let searchPath = [binaryDirectory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                          baseEnvironment["PATH"] ?? ""].joined(separator: ":")
        environment["PATH"] = searchPath
        let result = BoundedProcessRunner.run(path, ["chat", "--no-interactive", "/usage"],
                                              timeout: 30, maxOutputBytes: 32_768,
                                              environment: environment)
        guard result.status == 0, !result.timedOut,
              let output = String(data: result.output, encoding: .utf8),
              let reading = parse(output, now: Date()) else { return nil }
        return reading
    }

    static func parse(_ output: String, now: Date = Date()) -> Reading? {
        let clean = output.replacingOccurrences(of: "\u{001B}\\[[;?0-9]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let header = #"Estimated Usage\s*\|\s*resets on (\d{4}-\d{2}-\d{2})\s*\|\s*(.+)"#
        let credits = #"Credits\s*\(([\d,]+(?:\.\d+)?)\s+of\s+([\d,]+(?:\.\d+)?)\s+covered in plan\),\s*([\d.]+)%"#
        guard let h = firstMatch(header, in: clean), h.count == 3,
              let c = firstMatch(credits, in: clean), c.count == 4,
              let used = number(c[1]), let total = number(c[2]), total > 0,
              let reportedPercent = Double(c[3]) else { return nil }

        let percent = min(100, max(0, reportedPercent))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let reset = formatter.date(from: h[1])
        let planName = h[2].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !planName.isEmpty else { return nil }

        let creditsLabel = "Credits \(format(used)) / \(format(total))"
        let limit = AgentLimitWindow(id: "kiro.credits", kind: .other, minutes: nil,
                                     scope: creditsLabel, usedPercent: percent, resetsAt: reset)
        return Reading(limits: AgentLimits(provider: .kiro, windows: [limit], observedAt: now,
                                           source: .account),
                       plan: AgentPlan(name: planName, monthlyPrice: nil))
    }

    private static func executable(home: URL, environment: [String: String]) -> String? {
        let candidates = [home.appendingPathComponent(".local/bin/kiro-cli").path,
                          "/opt/homebrew/bin/kiro-cli", "/usr/local/bin/kiro-cli"]
            + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/kiro-cli" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
    }

    private static func number(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: ""))
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = value.rounded() == value ? 0 : 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
