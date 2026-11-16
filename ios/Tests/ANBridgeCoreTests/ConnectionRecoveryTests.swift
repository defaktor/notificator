import XCTest
@testable import ANBridgeCore

final class ConnectionRecoveryTests: XCTestCase {
    private let phone = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    func testAutomaticReconnectPreservesPendingKnownConnection() {
        var recovery = ConnectionRecovery()
        XCTAssertEqual(recovery.request(manual: false, available: true, current: nil, ready: false), .known)
        recovery.started(phone, now: 10)
        XCTAssertEqual(recovery.request(manual: false, available: true, current: phone, ready: false), .none)
    }

    func testManualRetryCancelsPendingConnectionThenRequestsFreshScan() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 10)
        XCTAssertEqual(recovery.request(manual: true, available: true, current: phone, ready: false), .cancel)
        XCTAssertFalse(recovery.acceptsCallback(from: phone, current: phone))
        XCTAssertTrue(recovery.closed(phone))
        XCTAssertEqual(recovery.request(manual: false, available: true, current: nil, ready: false), .scan)
    }

    func testRepeatedRetryWhileCancellationIsPendingDoesNotIssueAnotherOperation() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 0)
        XCTAssertEqual(recovery.request(manual: true, available: true, current: phone, ready: false), .cancel)
        XCTAssertEqual(recovery.request(manual: true, available: true, current: phone, ready: false), .none)
        XCTAssertEqual(recovery.request(manual: false, available: true, current: phone, ready: false), .none)
    }

    func testManualRetryWithoutCurrentPeripheralScansInsteadOfReusingCachedIdentifier() {
        var recovery = ConnectionRecovery()
        XCTAssertEqual(recovery.request(manual: true, available: true, current: nil, ready: false), .scan)
    }

    func testForegroundPendingConnectionFallsBackAfterTwelveSeconds() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 100)
        XCTAssertEqual(recovery.check(now: 111.9, foreground: true, available: true, current: phone, ready: false), .none)
        XCTAssertEqual(recovery.check(now: 112, foreground: true, available: true, current: phone, ready: false), .cancel)
        XCTAssertTrue(recovery.closed(phone))
        XCTAssertEqual(recovery.request(manual: false, available: true, current: nil, ready: false), .scan)
    }

    func testBackgroundConnectionRemainsRegisteredEvenAfterForegroundTimeout() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 0)
        XCTAssertEqual(recovery.check(now: 1000, foreground: false, available: true, current: phone, ready: false), .none)
        XCTAssertTrue(recovery.acceptsCallback(from: phone, current: phone))
        XCTAssertEqual(recovery.check(now: 1000, foreground: true, available: true, current: phone, ready: false), .cancel)
    }

    func testEstablishedLinkUsesHandshakeDeadlineInsteadOfConnectTimeout() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 0)
        recovery.linkConnected(phone)
        XCTAssertEqual(recovery.check(now: 1000, foreground: true, available: true, current: phone, ready: false), .none)
    }

    func testReadyConnectionIsPreservedUnlessUserExplicitlyRetries() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 0)
        recovery.authenticated()
        XCTAssertEqual(recovery.request(manual: false, available: true, current: phone, ready: true), .none)
        XCTAssertEqual(recovery.check(now: 1000, foreground: true, available: true, current: phone, ready: true), .none)
        XCTAssertEqual(recovery.request(manual: true, available: true, current: phone, ready: true), .cancel)
    }

    func testUnavailableBluetoothOrMissingPairCannotStartOrCancelTransport() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 0)
        XCTAssertEqual(recovery.request(manual: true, available: false, current: phone, ready: false), .none)
        XCTAssertEqual(recovery.request(manual: false, available: false, current: nil, ready: false), .none)
        XCTAssertEqual(recovery.check(now: 1000, foreground: true, available: false, current: phone, ready: false), .none)
    }

    func testLateCallbacksCannotAdvanceAnotherPeripheralOrCloseFence() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 0)
        XCTAssertFalse(recovery.acceptsCallback(from: other, current: phone))
        XCTAssertEqual(recovery.request(manual: true, available: true, current: phone, ready: false), .cancel)
        XCTAssertFalse(recovery.closed(other))
        XCTAssertTrue(recovery.isClosing(phone))
        XCTAssertTrue(recovery.closed(phone))
        recovery.started(other, now: 20)
        XCTAssertFalse(recovery.closed(phone))
        XCTAssertTrue(recovery.acceptsCallback(from: other, current: other))
    }

    func testAuthenticationCompletesRecoveryAndAllowsKnownDeviceNextTime() {
        var recovery = ConnectionRecovery()
        XCTAssertEqual(recovery.request(manual: true, available: true, current: nil, ready: false), .scan)
        recovery.started(phone, now: 0)
        recovery.authenticated()
        XCTAssertTrue(recovery.closed(phone))
        XCTAssertEqual(recovery.request(manual: false, available: true, current: nil, ready: false), .known)
    }

    func testRestoredConnectedLinkWaitsForBluetoothThenClosesBeforeScanning() {
        var recovery = ConnectionRecovery()
        recovery.restored(phone, connected: true, now: 0)
        XCTAssertEqual(recovery.request(manual: false, available: false, current: phone, ready: false), .none)
        XCTAssertEqual(recovery.request(manual: false, available: true, current: phone, ready: false), .cancel)
        XCTAssertFalse(recovery.acceptsCallback(from: phone, current: phone))
        XCTAssertTrue(recovery.closed(phone))
        XCTAssertEqual(recovery.request(manual: false, available: true, current: nil, ready: false), .scan)
    }

    func testRestoredPendingConnectionContinuesWhenBluetoothBecomesAvailable() {
        var recovery = ConnectionRecovery()
        recovery.restored(phone, connected: false, now: 0)
        XCTAssertEqual(recovery.request(manual: false, available: false, current: phone, ready: false), .none)
        XCTAssertEqual(recovery.request(manual: false, available: true, current: phone, ready: false), .none)
        XCTAssertTrue(recovery.acceptsCallback(from: phone, current: phone))
    }

    func testKnownPendingConnectionObservesDiscoveryAndCancelsBeforeUsingNewAdvertisement() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 0, observeDiscovery: true)
        XCTAssertTrue(recovery.shouldObserveDiscovery(available: true, current: phone, ready: false))
        XCTAssertEqual(recovery.discoveryWhilePending(available: true, current: phone, ready: false), .cancel)
        XCTAssertFalse(recovery.shouldObserveDiscovery(available: true, current: phone, ready: false))
        XCTAssertEqual(recovery.discoveryWhilePending(available: true, current: phone, ready: false), .none)
        XCTAssertTrue(recovery.closed(phone))
        XCTAssertEqual(recovery.request(manual: false, available: true, current: nil, ready: false), .scan)
    }

    func testKnownAttemptStartedInForegroundRemainsObservableAfterBackgrounding() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 0, observeDiscovery: true)
        XCTAssertEqual(recovery.check(now: 1000, foreground: false, available: true, current: phone, ready: false), .none)
        XCTAssertTrue(recovery.shouldObserveDiscovery(available: true, current: phone, ready: false))
        XCTAssertEqual(recovery.discoveryWhilePending(available: true, current: phone, ready: false), .cancel)
    }

    func testFreshlyDiscoveredConnectionCannotRecursivelyCancelItself() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 0)
        XCTAssertFalse(recovery.shouldObserveDiscovery(available: true, current: phone, ready: false))
        XCTAssertEqual(recovery.discoveryWhilePending(available: true, current: phone, ready: false), .none)
    }

    func testUnavailableStaleReadyAndClosingDiscoveryCannotCancelConnection() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 0, observeDiscovery: true)
        XCTAssertEqual(recovery.discoveryWhilePending(available: false, current: phone, ready: false), .none)
        XCTAssertEqual(recovery.discoveryWhilePending(available: true, current: other, ready: false), .none)
        XCTAssertEqual(recovery.discoveryWhilePending(available: true, current: phone, ready: true), .none)
        XCTAssertEqual(recovery.request(manual: true, available: true, current: phone, ready: false), .cancel)
        XCTAssertEqual(recovery.discoveryWhilePending(available: true, current: phone, ready: false), .none)
        XCTAssertTrue(recovery.closed(phone))
        XCTAssertEqual(recovery.discoveryWhilePending(available: true, current: phone, ready: false), .none)
    }

    func testRestoredPendingConnectionRegistersDiscoveryOnlyAfterBluetoothIsAvailable() {
        var recovery = ConnectionRecovery()
        recovery.restored(phone, connected: false, now: 0)
        XCTAssertFalse(recovery.shouldObserveDiscovery(available: false, current: phone, ready: false))
        XCTAssertTrue(recovery.shouldObserveDiscovery(available: true, current: phone, ready: false))
        XCTAssertEqual(recovery.discoveryWhilePending(available: true, current: phone, ready: false), .cancel)
    }

    func testPhysicalConnectionStopsDiscoveryObservationBeforeHandshakeCompletes() {
        var recovery = ConnectionRecovery()
        recovery.started(phone, now: 0, observeDiscovery: true)
        recovery.linkConnected(phone)
        XCTAssertFalse(recovery.shouldObserveDiscovery(available: true, current: phone, ready: false))
        XCTAssertEqual(recovery.discoveryWhilePending(available: true, current: phone, ready: false), .none)
    }
}
