import Foundation

/// `Strata --mcp`: a Model Context Protocol server on standard input and output, so an AI
/// assistant can look at what Strata scanned. It can only look: every tool reads, none
/// deletes, moves or empties anything (see `DiskTools`).
///
///   claude mcp add strata -- /Applications/Strata.app/Contents/MacOS/Strata --mcp
enum MCPServer {
    static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static func run() -> Never {
        let server = Session(tools: DiskTools())
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = server.handle(line) { write(reply) }
        }
        exit(0)
    }

    private static func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    /// One conversation with a client: turns each JSON-RPC message into its reply.
    final class Session {
        let tools: DiskTools

        init(tools: DiskTools) {
            self.tools = tools
        }

        /// The reply to one line, or nil for notifications.
        func handle(_ line: String) -> [String: Any]? {
            guard let data = line.data(using: .utf8),
                  let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return failure(id: NSNull(), code: -32700, message: "Parse error")
            }
            guard let method = message["method"] as? String else { return nil }
            guard let id = message["id"] else { return nil } // a notification
            let params = message["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                let asked = params["protocolVersion"] as? String ?? ""
                return success(id: id, [
                    "protocolVersion": versions.contains(asked) ? asked : versions[0],
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "strata", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
                    "instructions": MCPServer.instructions,
                ])
            case "ping":
                return success(id: id, [:])
            case "tools/list":
                return success(id: id, ["tools": MCPServer.toolList])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                do {
                    return success(id: id, ["content": [["type": "text", "text": try call(name, arguments)]]])
                } catch {
                    return success(id: id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
                }
            default:
                return failure(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }

        private func call(_ name: String, _ arguments: [String: Any]) throws -> String {
            let path = arguments["path"] as? String
            let limit = (arguments["limit"] as? Int).map { min(max($0, 1), 500) }
            switch name {
            case "list_disks":
                return Report.json(tools.listDisks())
            case "show_folder":
                return Report.json(try tools.showFolder(path, limit: limit ?? 30))
            case "find_largest":
                let kind = DiskTools.LargestKind(rawValue: arguments["kind"] as? String ?? "files") ?? .files
                return Report.json(try tools.findLargest(path, kind: kind, limit: limit ?? 20))
            case "find_by_name":
                guard let query = arguments["query"] as? String, !query.isEmpty else { throw Problem("query is required.") }
                return Report.json(try tools.findByName(query, in: path, limit: limit ?? 50))
            case "cleanup_suggestions":
                return Report.json(try tools.cleanupSuggestions())
            case "scan":
                return Report.json(try tools.scan(path))
            default:
                throw Problem("Unknown tool \(name).")
            }
        }

        private func success(id: Any, _ result: [String: Any]) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "result": result]
        }

        private func failure(id: Any, code: Int, message: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
        }
    }

    struct Problem: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    static let instructions = """
        Strata shows where the space on this Mac's disks went. Answers come from scans: the ones \
        the Strata app saved, or ones made with the scan tool in this session. Each answer says \
        when its scan was made. Sizes are the space files really take on disk; very small files \
        are grouped per folder as "small items". Paths are as the Finder shows them ("/" is the \
        startup disk, "~" the home folder). This server only reads: it cannot delete, move or \
        empty anything. Cleaning up is done by the user, in the Strata app or the Finder.
        """

    private static let pathProperty: [String: Any] = [
        "type": "string",
        "description": "Absolute path or ~/…; \"/\" is the startup disk. Defaults to \"/\".",
    ]
    private static let limitProperty: [String: Any] = ["type": "integer", "minimum": 1, "maximum": 500]
    private static let readOnly: [String: Any] = ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false]

    static let toolList: [[String: Any]] = [
        [
            "name": "list_disks",
            "description": "The local disks with their size and free space, and which disks and folders have a scan.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": readOnly.merging(["title": "List disks"]) { $1 },
        ],
        [
            "name": "show_folder",
            "description": "What is directly inside a folder, largest first, with sizes and the newest change below each entry.",
            "inputSchema": ["type": "object", "properties": [
                "path": pathProperty,
                "limit": limitProperty.merging(["description": "How many entries to list (default 30)."]) { $1 },
            ]],
            "annotations": readOnly.merging(["title": "Show folder"]) { $1 },
        ],
        [
            "name": "find_largest",
            "description": "The largest files below a folder, or with kind \"folders\" the folders where space gathers (folders not mostly made of one folder inside them).",
            "inputSchema": ["type": "object", "properties": [
                "path": pathProperty,
                "kind": ["type": "string", "enum": ["files", "folders"], "description": "Default \"files\"."],
                "limit": limitProperty.merging(["description": "How many to list (default 20)."]) { $1 },
            ]],
            "annotations": readOnly.merging(["title": "Find largest"]) { $1 },
        ],
        [
            "name": "find_by_name",
            "description": "Files and folders below a path whose name contains the text (case-insensitive), largest first. Only entries big enough to be kept on their own are searched.",
            "inputSchema": ["type": "object", "required": ["query"], "properties": [
                "query": ["type": "string"],
                "path": pathProperty,
                "limit": limitProperty.merging(["description": "How many to list (default 50)."]) { $1 },
            ]],
            "annotations": readOnly.merging(["title": "Find by name"]) { $1 },
        ],
        [
            "name": "cleanup_suggestions",
            "description": "What the Strata app lists under Safe to Clean on the startup disk (caches, logs, build products that are rebuilt when needed, the Trash), with sizes, plus the number of local Time Machine snapshots. Report only.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": readOnly.merging(["title": "Cleanup suggestions"]) { $1 },
        ],
        [
            "name": "scan",
            "description": "Scans a disk or folder now (the whole startup disk takes about half a minute) and answers from that scan for the rest of the session. Writes nothing.",
            "inputSchema": ["type": "object", "properties": ["path": pathProperty]],
            "annotations": readOnly.merging(["title": "Scan"]) { $1 },
        ],
    ]
}
