import XCTest
@testable import SyncVault

@MainActor
final class OnboardingControllerTests: XCTestCase {

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "onboardingComplete")
    }

    func testInitialStepIsWelcome() {
        let c = OnboardingController()
        XCTAssertEqual(c.step, .welcome)
    }

    func testNextAdvancesStep() {
        let c = OnboardingController()
        c.next()
        XCTAssertEqual(c.step, .connect)
        c.next()
        XCTAssertEqual(c.step, .firstTask)
        c.next()
        XCTAssertEqual(c.step, .done)
    }

    func testNextOnDoneDoesNotAdvance() {
        let c = OnboardingController()
        c.step = .done
        c.next()
        XCTAssertEqual(c.step, .done)
    }

    func testBackOnWelcomeDoesNotRegress() {
        let c = OnboardingController()
        c.back()
        XCTAssertEqual(c.step, .welcome)
    }

    func testBackFromConnectReturnsToWelcome() {
        let c = OnboardingController()
        c.next()
        c.back()
        XCTAssertEqual(c.step, .welcome)
    }

    func testCompletePersistsFlag() {
        let c = OnboardingController()
        c.complete()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "onboardingComplete"))
    }

    func testNeedsOnboardingTrueWhenFlagUnset() {
        XCTAssertTrue(OnboardingController.needsOnboarding)
    }

    func testNeedsOnboardingFalseAfterComplete() {
        OnboardingController().complete()
        XCTAssertFalse(OnboardingController.needsOnboarding)
    }
}
