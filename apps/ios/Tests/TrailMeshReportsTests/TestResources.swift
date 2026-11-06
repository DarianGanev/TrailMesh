import Foundation
import TrailMeshReports
import XCTest

enum TestResources {
    static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return Bundle(for: TestBundleMarker.self)
        #endif
    }
}

private final class TestBundleMarker {}

final class ProductPublicAPITests: XCTestCase {
    func testProductCanOpenRepositoryWithoutBlockingItsCaller() async throws {
        let repository = try await ReportRepository.open(path: ":memory:")
        let current = try await repository.forwardable(now: 1)
        XCTAssertTrue(current.isEmpty)
    }
}
