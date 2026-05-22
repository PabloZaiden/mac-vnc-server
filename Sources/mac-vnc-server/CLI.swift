import Foundation

enum CLIError: LocalizedError {
    case helpRequested(String)
    case invalidArgument(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case .invalidArgument(let message):
            return message
        }
    }
}

enum CLICommand {
    case run(ServerConfig)
    case permissions
    case diagnose
    case version

    func run() async throws {
        switch self {
        case .run(let config):
            let capture = try await StreamingScreenCapture(scale: config.scale, fps: config.fps)
            let input = MacInputController()
            let clipboard = MacClipboard()
            let server = RFBServer(config: config, capture: capture, input: input, clipboard: clipboard)
            try server.run()
        case .permissions:
            Permissions.printAndRequest()
        case .diagnose:
            Permissions.printStatus()
            MacScreenCapture.printDisplayDiagnostics()
        case .version:
            print("mac-vnc-server \(AppVersion.current)")
        }
    }
}

enum CLI {
    static func parse(arguments: [String]) throws -> CLICommand {
        guard let subcommand = arguments.first else {
            return .run(try parseRun(Array(arguments.dropFirst())))
        }

        if subcommand.hasPrefix("-") {
            return .run(try parseRun(arguments))
        }

        switch subcommand {
        case "run":
            return .run(try parseRun(Array(arguments.dropFirst())))
        case "permissions":
            return .permissions
        case "diagnose":
            return .diagnose
        case "version", "--version", "-V":
            return .version
        case "-h", "--help", "help":
            throw CLIError.helpRequested(helpText)
        default:
            throw CLIError.invalidArgument("unknown command '\(subcommand)'\n\n\(helpText)")
        }
    }

    private static func parseRun(_ arguments: [String]) throws -> ServerConfig {
        var port: UInt16 = 5902
        var bindAddress = "127.0.0.1"
        var password: String? = "macvnc"
        var insecureAllowNoAuth = false
        var fps = 30
        var scale: Double = 1
        var encodingPreference = EncodingPreference.auto
        var index = 0

        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--port", "-p":
                index += 1
                guard index < arguments.count, let parsed = UInt16(arguments[index]) else {
                    throw CLIError.invalidArgument("--port requires a valid TCP port")
                }
                port = parsed
            case "--bind":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--bind requires an IPv4 address")
                }
                bindAddress = arguments[index]
            case "--password":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--password requires a value")
                }
                password = arguments[index]
            case "--no-password":
                password = nil
            case "--insecure-allow-no-auth":
                insecureAllowNoAuth = true
            case "--fps":
                index += 1
                guard index < arguments.count, let parsed = Int(arguments[index]), (1...120).contains(parsed) else {
                    throw CLIError.invalidArgument("--fps requires a value between 1 and 120")
                }
                fps = parsed
            case "--scale":
                index += 1
                guard index < arguments.count, let parsed = Double(arguments[index]), parsed > 0, parsed <= 4 else {
                    throw CLIError.invalidArgument("--scale requires a value greater than 0 and at most 4")
                }
                scale = parsed
            case "--encoding":
                index += 1
                guard index < arguments.count, let parsed = EncodingPreference(rawValue: arguments[index]) else {
                    throw CLIError.invalidArgument("--encoding must be auto, zrle, zlib, or raw")
                }
                encodingPreference = parsed
            case "--help", "-h":
                throw CLIError.helpRequested(helpText)
            default:
                throw CLIError.invalidArgument("unknown run argument '\(arg)'")
            }
            index += 1
        }

        if !isLoopback(bindAddress), password == nil, !insecureAllowNoAuth {
            throw CLIError.invalidArgument("""
            refusing to expose unauthenticated VNC on \(bindAddress)
            Use --password for LAN, or pass --insecure-allow-no-auth if you explicitly want no auth.
            """)
        }

        return ServerConfig(
            bindAddress: bindAddress,
            port: port,
            password: password,
            fps: fps,
            scale: scale,
            encodingPreference: encodingPreference
        )
    }

    private static func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address.hasPrefix("127.")
    }

    static let helpText = """
    mac-vnc-server \(AppVersion.current)

    Usage:
      mac-vnc-server run [--bind 127.0.0.1] [--port 5902] [--password value]
                          [--fps 30] [--scale 1.0] [--encoding auto|zrle|zlib|raw]
      mac-vnc-server permissions
      mac-vnc-server diagnose
      mac-vnc-server version

    Default bind address is 127.0.0.1, default port is 5902, and default password is macvnc.
    Use --no-password only for clients that accept unauthenticated VNC.
    """
}
