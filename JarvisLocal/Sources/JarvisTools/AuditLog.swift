import Foundation
import JarvisKit
import JarvisAgent

/// L2 — journal d'audit append-only (JSONL, une ligne par exécution).
///
/// Champs compatibles avec la table `tool_runs` v0.9.1 (outil, args,
/// statut, résultat tronqué, run, date) pour une migration sans perte en
/// phase 4. Écriture atomique par ligne (append) : un crash ne corrompt
/// jamais les lignes précédentes.
public struct AuditEntry: Sendable, Codable, Equatable {
    public var date: Date
    public var runId: UUID
    public var tool: String
    public var argsPreview: String
    public var status: String
    public var durationMs: Double
    public var resultPreview: String

    public init(
        date: Date = Date(),
        runId: UUID,
        tool: String,
        argsPreview: String,
        status: String,
        durationMs: Double,
        resultPreview: String
    ) {
        self.date = date
        self.runId = runId
        self.tool = tool
        self.argsPreview = argsPreview
        self.status = status
        self.durationMs = durationMs
        self.resultPreview = resultPreview
    }
}

public actor AuditLog {
    private let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func append(_ entry: AuditEntry) throws {
        let line = try JSONEncoder().encode(entry) + Data("\n".utf8)
        if FileManager.default.fileExists(atPath: file.path) {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line.write(to: file, options: .atomic)
        }
    }

    public func readAll() throws -> [AuditEntry] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let data = try Data(contentsOf: file)
        return try data.split(separator: UInt8(ascii: "\n")).map { line in
            try JSONDecoder().decode(AuditEntry.self, from: Data(line))
        }
    }
}

/// Enrobe une définition d'un audit (statut + durée + aperçus, jamais le
/// contenu intégral) : l'audit ne fuit pas les données, il prouve l'action.
public enum AuditedTool {
    public static func wrap(
        _ definition: ToolDefinition,
        log: AuditLog,
        runId: UUID,
        maxPreviewChars: Int = 300
    ) -> ToolDefinition {
        ToolDefinition(
            name: definition.name,
            description: definition.description,
            parameters: definition.parameters,
            isCore: definition.isCore,
            isNetworkEgress: definition.isNetworkEgress,
            isWrite: definition.isWrite,
            producesUntrustedContent: definition.producesUntrustedContent
        ) { args, context in
            let start = Date()
            let result: ToolResult
            do {
                result = try await definition.execute(args, context)
            } catch {
                result = .failure(code: "executor_error", message: "Panne : \(error).", hint: "Conclus.")
            }
            let status = result.ok ? "ok" : "error"
            let resultText = (try? String(data: result.toJSON().encoded(), encoding: .utf8)) ?? "?"
            try? await log.append(AuditEntry(
                runId: runId,
                tool: definition.name,
                argsPreview: String(args.preview(maxChars: maxPreviewChars)),
                status: status,
                durationMs: Date().timeIntervalSince(start) * 1000.0,
                resultPreview: String(resultText.prefix(maxPreviewChars))))
            return result
        }
    }
}
