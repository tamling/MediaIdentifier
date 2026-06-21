import XCTest
@testable import MediaIdentifierCore

final class YearParserTests: XCTestCase {
    func testExtractsYearFromVariousDateFormats() {
        XCTAssertEqual(YearParser.firstYear(in: "1999-03-31"), 1999)
        XCTAssertEqual(YearParser.firstYear(in: "2021"), 2021)
        XCTAssertEqual(YearParser.firstYear(in: "2014-08-01T00:00:00Z"), 2014)
        XCTAssertEqual(YearParser.firstYear(in: "Released 2008 remaster"), 2008)
    }

    func testReturnsNilWhenNoYear() {
        XCTAssertNil(YearParser.firstYear(in: "no year here"))
        XCTAssertNil(YearParser.firstYear(in: ""))
        XCTAssertNil(YearParser.firstYear(in: "1850"))
    }
}
