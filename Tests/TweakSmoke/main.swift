import Foundation

// Uso: tweaksmoke <pasta-do-app> <tweak1> [tweak2 ...]
let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("uso: tweaksmoke <app> <tweaks...>")
    exit(2)
}

let app = URL(fileURLWithPath: arguments[1])
let files = arguments.dropFirst(2).map { URL(fileURLWithPath: $0) }
let injector = TweakInjector(appDirectory: app) { text, level in
    print("[\(level.rawValue)] \(text)")
}

do {
    let summary = try injector.inject(Array(files))
    print("INJECTED=\(summary.injected.joined(separator: ",")) SUBSTRATE=\(summary.substrateAdded)")
} catch {
    print("ERROR: \(error)")
    exit(1)
}
