import XCTest
@testable import MatchTrackerKit

final class CircuitBreakerTests: XCTestCase {

    func testStaysClosedUntilThresholdOfTransportFailures() {
        let breaker = CircuitBreaker(failureThreshold: 3, cooldown: 300)
        let now = Date(timeIntervalSince1970: 0)

        XCTAssertTrue(breaker.allowsRequest(now: now))
        breaker.recordFailure(transportLevel: true, now: now)
        XCTAssertTrue(breaker.allowsRequest(now: now), "one failure must not trip")
        breaker.recordFailure(transportLevel: true, now: now)
        XCTAssertTrue(breaker.allowsRequest(now: now), "two failures must not trip")
        breaker.recordFailure(transportLevel: true, now: now)
        XCTAssertFalse(breaker.allowsRequest(now: now), "third consecutive failure trips the breaker")
    }

    func testCooldownHalfOpensThenSuccessCloses() {
        let breaker = CircuitBreaker(failureThreshold: 2, cooldown: 300)
        let start = Date(timeIntervalSince1970: 0)
        breaker.recordFailure(transportLevel: true, now: start)
        breaker.recordFailure(transportLevel: true, now: start)
        XCTAssertFalse(breaker.allowsRequest(now: start))

        // Still suspended just before the cooldown elapses.
        XCTAssertFalse(breaker.allowsRequest(now: start.addingTimeInterval(299)))
        // Half-opens once the cooldown elapses: a single probe is allowed.
        let after = start.addingTimeInterval(300)
        XCTAssertTrue(breaker.allowsRequest(now: after))
        // A success fully closes it.
        breaker.recordSuccess()
        XCTAssertTrue(breaker.allowsRequest(now: after))
    }

    func testReachedServerFailureResetsTransportCounter() {
        let breaker = CircuitBreaker(failureThreshold: 2, cooldown: 300)
        let now = Date(timeIntervalSince1970: 0)
        breaker.recordFailure(transportLevel: true, now: now)
        // An HTTP-level failure means the server was reached: it resets the transport streak.
        breaker.recordFailure(transportLevel: false, now: now)
        breaker.recordFailure(transportLevel: true, now: now)
        XCTAssertTrue(breaker.allowsRequest(now: now), "streak was broken by a reached-server failure")
    }

    func testSuccessResetsFailureStreak() {
        let breaker = CircuitBreaker(failureThreshold: 2, cooldown: 300)
        let now = Date(timeIntervalSince1970: 0)
        breaker.recordFailure(transportLevel: true, now: now)
        breaker.recordSuccess()
        breaker.recordFailure(transportLevel: true, now: now)
        XCTAssertTrue(breaker.allowsRequest(now: now), "a success in between must reset the streak")
    }

    func testTransportFailureClassification() {
        XCTAssertTrue(CircuitBreaker.isTransportFailure(URLError(.secureConnectionFailed)))
        XCTAssertTrue(CircuitBreaker.isTransportFailure(URLError(.cannotConnectToHost)))
        XCTAssertTrue(CircuitBreaker.isTransportFailure(URLError(.notConnectedToInternet)))
        XCTAssertTrue(CircuitBreaker.isTransportFailure(URLError(.timedOut)))
        // A reached server that returned an error status is NOT a transport failure.
        XCTAssertFalse(CircuitBreaker.isTransportFailure(APIError.httpStatus(500)))
        XCTAssertFalse(CircuitBreaker.isTransportFailure(URLError(.badServerResponse)))
    }
}
