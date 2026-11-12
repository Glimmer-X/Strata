import Foundation

// Strata: see where the space on a disk went.
// With --snapshot it renders one still picture and exits (see Snapshot.swift);
// otherwise it runs as the app.

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--snapshot") {
    MainActor.assumeIsolated { Snapshot.run(arguments) }
} else {
    StrataApp.main()
}
