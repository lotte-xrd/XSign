import Foundation

// Substitutos mínimos do app para compilar o injetor como ferramenta de linha de comando.
enum L {
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        args.isEmpty ? key : key + " " + args.map { "\($0)" }.joined(separator: " ")
    }
}

enum SignLogLevel: String {
    case info, detail, success, warning, error
}

enum Paths {
    static var tweaks: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xsign-smoke-tweaks", isDirectory: true)
    }
}
