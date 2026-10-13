import Foundation

struct WorkSwitchPermission: Decodable {
    let configured: Bool
    let state: String
    let revision: Int
    let leaseSeconds: Double

    var valid: Bool {
        ["active", "standby", "unavailable"].contains(state) && revision >= 0 &&
        leaseSeconds.isFinite && (0...60).contains(leaseSeconds)
    }
    var label: String? {
        guard configured else { return nil }
        return state == "active" ? "Switchr: On" : state == "standby" ? "Switchr: Off" : "Switchr: Pending"
    }
}

struct WorkSwitchLease {
    private var permission: WorkSwitchPermission?
    private var expiresAt = -Double.infinity
    private var expiresUptime = -Double.infinity
    var label: String? {
        guard let permission else { return "Switchr: Pending" }
        guard permission.configured else { return nil }
        if permission.state == "active" && !allowsWork() { return "Switchr: Pending" }
        if permission.state == "standby" && !isConfirmedStandby() { return "Switchr: Pending" }
        return permission.label
    }
    func allowsWork(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        permission?.state == "active" && now.timeIntervalSince1970 < expiresAt && uptime < expiresUptime
    }
    func isConfirmedStandby(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        permission?.configured == true && permission?.state == "standby"
            && now.timeIntervalSince1970 < expiresAt && uptime < expiresUptime
    }
    mutating func accept(_ permission: WorkSwitchPermission, elapsed: Double,
                         now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard permission.valid else { invalidate(); return }
        self.permission = permission
        let remaining = max(0, permission.leaseSeconds - elapsed)
        expiresAt = now.timeIntervalSince1970 + remaining
        expiresUptime = uptime + remaining
    }
    mutating func invalidate() { permission = nil; expiresAt = -.infinity; expiresUptime = -.infinity }
}
