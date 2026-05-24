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
            try await runServers(config: config)
        case .permissions:
            Permissions.printAndRequest()
        case .diagnose:
            Permissions.printStatus()
            MacScreenCapture.printDisplayDiagnostics()
        case .version:
            print("mac-vnc-server \(AppVersion.current)")
        }
    }

    private func runServers(config: ServerConfig) async throws {
        let configs = try await expandedConfigs(from: config)
        if configs.count == 1, let config = configs.first {
            try await Self.runServer(config: config)
            return
        }

        for config in configs {
            Task.detached {
                do {
                    try await Self.runServer(config: config)
                } catch {
                    fputs("mac-vnc-server \(config.bindAddress):\(config.port): \(error.localizedDescription)\n", stderr)
                    Foundation.exit(1)
                }
            }
        }

        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    private func expandedConfigs(from config: ServerConfig) async throws -> [ServerConfig] {
        guard config.displaySelection == .automatic else {
            return [config]
        }

        let displayCount = try await StreamingScreenCapture.displayCount()
        guard displayCount > 0 else {
            throw RFBError.captureFailed("ScreenCaptureKit found no displays")
        }
        guard Int(config.port) + displayCount <= Int(UInt16.max) else {
            throw CLIError.invalidArgument("not enough consecutive ports starting at \(config.port) for \(displayCount) display(s)")
        }

        var configs = [config.with(displaySelection: .all)]
        for displayIndex in 1...displayCount {
            configs.append(config.with(port: config.port + UInt16(displayIndex), displaySelection: .display(displayIndex)))
        }
        return configs
    }

    private static func runServer(config: ServerConfig) async throws {
        let capture = try await StreamingScreenCapture(scale: config.scale, fps: config.fps, displaySelection: config.displaySelection)
        let input = MacInputController()
        let clipboard = MacClipboard()
        let server = RFBServer(config: config, capture: capture, input: input, clipboard: clipboard)
        try server.run()
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
        var port: UInt16 = 5900
        var bindAddress = "127.0.0.1"
        var password: String? = "macvnc"
        var insecureAllowNoAuth = false
        var fps = 30
        var scale: Double = 1
        var encodingPreference = EncodingPreference.auto
        var displaySelection = DisplaySelection.automatic
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
            case "--display":
                index += 1
                guard index < arguments.count else {
                    throw CLIError.invalidArgument("--display requires all or a 1-based display number")
                }
                if arguments[index] == "all" {
                    displaySelection = .all
                } else if let parsed = Int(arguments[index]), parsed > 0 {
                    displaySelection = .display(parsed)
                } else {
                    throw CLIError.invalidArgument("--display requires all or a 1-based display number")
                }
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
            encodingPreference: encodingPreference,
            displaySelection: displaySelection
        )
    }

    private static func isLoopback(_ address: String) -> Bool {
        address == "127.0.0.1" || address.hasPrefix("127.")
    }

    static let helpText = """
    mac-vnc-server \(AppVersion.current)

    Usage:
      mac-vnc-server run [--bind 127.0.0.1] [--port 5900] [--password value]
                          [--fps 30] [--scale 1.0] [--encoding auto|zrle|zlib|raw]
                          [--display all|number]
      mac-vnc-server permissions
      mac-vnc-server diagnose
      mac-vnc-server version

    Default bind address is 127.0.0.1, default port is 5900, and default password is macvnc.
    Without --display, port 5900 serves all displays and 5901, 5902, ... serve each display.
    Use --display all to keep only the single combined-display server, or --display 1 for one display.
    Use --no-password only for clients that accept unauthenticated VNC.
    """
}

private extension ServerConfig {
    func with(port: UInt16? = nil, displaySelection: DisplaySelection) -> ServerConfig {
        ServerConfig(
            bindAddress: bindAddress,
            port: port ?? self.port,
            password: password,
            fps: fps,
            scale: scale,
            encodingPreference: encodingPreference,
            displaySelection: displaySelection
        )
    }
}
