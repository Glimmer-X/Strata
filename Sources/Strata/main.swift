import Foundation

// Strata: see where the space on a disk went.
// With --snapshot it renders one still picture and exits (see Snapshot.swift);
// with --mcp it answers questions about the scans on standard input (see MCPServer.swift);
// otherwise it runs as the app.

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--snapshot") {
    MainActor.assumeIsolated { Snapshot.run(arguments) }
} else if arguments.contains("--mcp") {
    MCPServer.run()
} else {
    StrataApp.main()
}
