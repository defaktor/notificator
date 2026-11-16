import Foundation

/// Decisions for retrying a transport without discarding the authenticated pair.
/// Core Bluetooth operations remain in the application; cancellation is a fence,
/// so a fresh search never starts before the previous attempt has closed.
public struct ConnectionRecovery {
    public enum Action: Equatable { case none, known, scan, cancel }
    public private(set) var closing: UUID?
    private var current: UUID?
    private var connectingSince: TimeInterval?
    private var preferScan = false
    private var resetRestoredLink = false
    private var observePendingDiscovery = false

    public init() {}

    public mutating func request(manual: Bool, available: Bool, current: UUID?, ready: Bool) -> Action {
        guard available, closing == nil else { return .none }
        if manual || resetRestoredLink {
            resetRestoredLink = false
            preferScan = true
            if let current {
                self.current = current
                closing = current
                return .cancel
            }
            return .scan
        }
        guard !ready, current == nil else { return .none }
        return preferScan ? .scan : .known
    }

    public mutating func started(_ identifier: UUID, now: TimeInterval, observeDiscovery: Bool = false) {
        current = identifier
        connectingSince = now
        resetRestoredLink = false
        observePendingDiscovery = observeDiscovery
    }

    /// Restoration can precede Bluetooth becoming powered on. Keep the reset
    /// intent until a later request is allowed to issue Core Bluetooth operations.
    public mutating func restored(_ identifier: UUID, connected: Bool, now: TimeInterval) {
        started(identifier, now: now, observeDiscovery: !connected)
        resetRestoredLink = connected
        if connected { preferScan = true }
    }

    public mutating func linkConnected(_ identifier: UUID) {
        guard current == identifier, closing == nil else { return }
        connectingSince = nil
        observePendingDiscovery = false
    }

    public mutating func authenticated() {
        connectingSince = nil
        preferScan = false
        resetRestoredLink = false
        observePendingDiscovery = false
    }

    public func isClosing(_ identifier: UUID) -> Bool { closing == identifier }

    public func acceptsCallback(from identifier: UUID, current: UUID?) -> Bool {
        closing == nil && self.current == identifier && current == identifier
    }

    /// Used by both terminal Core Bluetooth callbacks, including a failed attempt.
    @discardableResult public mutating func closed(_ identifier: UUID) -> Bool {
        guard current == identifier else { return false }
        current = nil
        connectingSince = nil
        resetRestoredLink = false
        observePendingDiscovery = false
        if closing == identifier { closing = nil }
        return true
    }

    public mutating func preferDiscovery() { preferScan = true }

    /// A cached identity may have changed while the app was suspended. Keep a
    /// filtered discovery operation alongside only that pending known attempt.
    public func shouldObserveDiscovery(available: Bool, current: UUID?, ready: Bool) -> Bool {
        available && !ready && closing == nil && observePendingDiscovery &&
        current != nil && current == self.current && connectingSince != nil
    }

    public mutating func discoveryWhilePending(available: Bool, current: UUID?, ready: Bool) -> Action {
        guard shouldObserveDiscovery(available: available, current: current, ready: ready), let current else { return .none }
        preferScan = true
        closing = current
        observePendingDiscovery = false
        return .cancel
    }

    public mutating func stopped() { self = ConnectionRecovery() }

    public mutating func check(now: TimeInterval, foreground: Bool, available: Bool,
                               current: UUID?, ready: Bool) -> Action {
        guard foreground, available, !ready, closing == nil,
              let current, self.current == current, let connectingSince,
              now - connectingSince >= 12 else { return .none }
        preferScan = true
        closing = current
        return .cancel
    }
}
