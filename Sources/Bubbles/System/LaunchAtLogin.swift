import ServiceManagement

/// "Open at login" through `SMAppService.mainApp` (macOS asks nothing; the user sees it in
/// System Settings → General → Login Items).
enum LaunchAtLogin {
    @MainActor static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @MainActor static func set(_ on: Bool) throws {
        if on {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
