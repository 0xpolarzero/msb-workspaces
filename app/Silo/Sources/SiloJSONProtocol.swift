import Foundation

enum SiloClientError: Error, LocalizedError, Sendable, Equatable {
    case invalidExecutable
    case invalidArguments
    case timedOut(command: String)
    case cancelled
    case processFailed(command: String, status: Int32, message: String?)
    case invalidUTF8
    case malformedJSON(command: String)
    case protocolMismatch(command: String, detail: String)
    case unsupportedSchema(Int)
    case missingResult(command: String)
    case protocolFailure(SiloProtocolError)
    case unavailable(String)
    /// Typed error from a raw (non-app-protocol) CLI command that reports
    /// `{"ok":false,"error":{code,message,remedies}}` on stdout.
    case rawCLIError(code: String, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidExecutable: return "Silo executable is unavailable."
        case .invalidArguments: return "The requested Silo operation has invalid arguments."
        case .timedOut(let command): return "Silo operation timed out: \(command)."
        case .cancelled: return "The Silo operation was cancelled."
        case .processFailed(let command, let status, let message):
            return message ?? "Silo \(command) exited with status \(status) without returning error details."
        case .invalidUTF8: return "Silo returned invalid UTF-8 output."
        case .malformedJSON(let command): return "Silo returned malformed JSON for \(command)."
        case .protocolMismatch(let command, let detail):
            return "Silo returned an incompatible protocol response for \(command): \(detail)"
        case .unsupportedSchema(let version): return "Silo returned unsupported schema version \(version)."
        case .missingResult(let command): return "Silo returned no result for \(command)."
        case .protocolFailure(let error): return error.localizedDescription
        case .unavailable(let message): return message
        case .rawCLIError(_, let message): return message ?? "The Silo operation failed."
        }
    }
}

enum SiloProtocolDecoder {
    private static let envelopeKeys: Set<String> = [
        "schemaVersion", "requestId", "ok", "command", "observedAt", "result", "warnings", "error"
    ]

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 timestamp."
            )
        }
        return decoder
    }

    static func decodeEnvelope<Value: Codable & Sendable>(
        _ data: Data,
        as type: Value.Type,
        expectedCommand: String? = nil
    ) throws -> SiloEnvelope<Value> {
        let envelope: SiloEnvelope<Value>
        do {
            envelope = try decoder().decode(SiloEnvelope<Value>.self, from: data)
        } catch {
            throw SiloClientError.malformedJSON(command: expectedCommand ?? "unknown")
        }

        guard envelope.schemaVersion == 1 else {
            throw SiloClientError.unsupportedSchema(envelope.schemaVersion)
        }
        guard !envelope.requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SiloClientError.malformedJSON(command: expectedCommand ?? envelope.command)
        }
        if let expectedCommand, envelope.command != expectedCommand {
            throw SiloClientError.malformedJSON(command: expectedCommand)
        }
        if envelope.ok {
            guard envelope.error == nil, envelope.observedAt != nil, envelope.result != nil else {
                throw SiloClientError.malformedJSON(command: envelope.command)
            }
        } else {
            guard envelope.result == nil, let error = envelope.error else {
                throw SiloClientError.malformedJSON(command: envelope.command)
            }
            throw SiloClientError.protocolFailure(error)
        }
        return envelope
    }

    static func decodeStrictHandshake(_ data: Data) throws -> SiloEnvelope<SiloHandshake> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == envelopeKeys else {
            throw SiloClientError.malformedJSON(command: "handshake")
        }
        return try decodeEnvelope(data, as: SiloHandshake.self, expectedCommand: "handshake")
    }
}




struct SiloJSONLFramer: Sendable {
    private(set) var pending = Data()
    private(set) var bytesSeen = 0
    let maxLineBytes: Int
    let maxBufferedBytes: Int

    init(maxLineBytes: Int = 256 * 1024, maxBufferedBytes: Int = 4 * 1024 * 1024) {
        self.maxLineBytes = maxLineBytes
        self.maxBufferedBytes = maxBufferedBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        bytesSeen += data.count
        guard data.count <= maxBufferedBytes, pending.count + data.count <= maxBufferedBytes else {
            throw SiloClientError.unavailable("Silo JSONL output exceeded the capture limit.")
        }
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0a) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            guard line.count <= maxLineBytes else {
                throw SiloClientError.unavailable("Silo JSONL line exceeded the capture limit.")
            }
            if !line.isEmpty { lines.append(Data(line)) }
        }
        guard pending.count <= maxLineBytes else {
            throw SiloClientError.unavailable("Silo JSONL line exceeded the capture limit.")
        }
        return lines
    }

    mutating func finish() throws -> Data? {
        guard !pending.isEmpty else { return nil }
        guard pending.count <= maxLineBytes else {
            throw SiloClientError.unavailable("Silo JSONL line exceeded the capture limit.")
        }
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}

struct SiloProtocolRedactor: Sendable {
    private let patterns: [String] = [
        #"(?i)bearer\s+[A-Za-z0-9._~+\-/]+=*"#,
        #"(?i)basic\s+[A-Za-z0-9+/=]+"#,
        #"(?i)(token|authorization|x-access-token|GH_TOKEN|GITHUB_TOKEN|ACCESS_TOKEN|REFRESH_TOKEN|SILO_GITHUB_READ_TOKEN(?:_[A-Za-z0-9_]+)?|SILO_GITHUB_WRITE_TOKEN(?:_[A-Za-z0-9_]+)?)=[^\s\"',;\}\]]+"#,
        #"(?i)(gho_|ghs_|ghu_|ghr_|ghp_|github_pat_)[A-Za-z0-9_\-]+"#,
        #"(?i)https?://[^\s:@]+:[^\s@]+@"#
    ]

    func redact(_ string: String) -> String {
        var redacted = patterns.reduce(string) { partial, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return partial }
            let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
            return expression.stringByReplacingMatches(
                in: partial,
                options: [],
                range: range,
                withTemplate: "[REDACTED]"
            )
        }

        // Keep JSON logs valid while removing opaque credential fields whose
        // values do not have a recognizable GitHub token prefix.
        let jsonCredentialPattern = #"(?i)("(?:access[_-]?token|refresh[_-]?token|gh[_-]?token|github[_-]?token|client[_-]?secret|private[_-]?key)"\s*:\s*")[^"]*(")"#
        if let expression = try? NSRegularExpression(pattern: jsonCredentialPattern) {
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = expression.stringByReplacingMatches(
                in: redacted,
                options: [],
                range: range,
                withTemplate: "$1[REDACTED]$2"
            )
        }
        return redacted
    }
}
