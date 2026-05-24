import XCTest
import SwiftUI
@testable import SyncVault

final class TokensTests: XCTestCase {
    func testAccentBlueIsSystemBlue() {
        XCTAssertEqual(SVColor.accentBlue.description, Color(red: 0.039, green: 0.518, blue: 1.0).description)
    }

    func testSpacingScaleStrict() {
        // Only the documented values should exist in the scale
        XCTAssertEqual(SVSpacing.xs, 4)
        XCTAssertEqual(SVSpacing.s,  6)
        XCTAssertEqual(SVSpacing.m,  8)
        XCTAssertEqual(SVSpacing.l, 10)
        XCTAssertEqual(SVSpacing.xl, 14)
        XCTAssertEqual(SVSpacing.xxl, 18)
        XCTAssertEqual(SVSpacing.xxxl, 22)
    }

    func testMonoFontIsSystemMono() {
        let font = SVFont.mono(11)
        XCTAssertNotNil(font)
    }
}
