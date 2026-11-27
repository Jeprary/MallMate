import XCTest
@testable import RouteWalk

final class RouteWebReturnChecks: XCTestCase {
    func testSafeHTTPSReturnPreservesStorePathQueryAndFragment() {
        // Production hosting is not fixed; ordinary HTTPS hosts remain supported.
        for target in ["https://mallmate.example/stores/B02001HUD4?lang=zh&from=ar#details",
                       "https://other.example:443/stores/uniqlo",
                       "https://mallmate.example/stores/优衣库"] {
            XCTAssertEqual(RouteWebReturnPolicy.validated(target), URL(string: target), target)
        }
    }

    func testUnsafeOrInvocationLoopReturnIsRejected() {
        let rejected = ["", "/stores/uniqlo", "//mallmate.example/stores/uniqlo",
                        "mallmate-route://guide/B02001HUD4", "javascript:alert(1)",
                        "file:///tmp/map.routewalk", "http://mallmate.example/stores/uniqlo",
                        "https://user@mallmate.example/store", "https://user:pass@mallmate.example/store",
                        "https://mallmate.example:0/store", "https://mallmate.example:65536/store",
                        "https://mallmate.example/guide/B02001HUD4",
                        "https://mallmate.example/Guide/B02001HUD4"]
        XCTAssertNil(RouteWebReturnPolicy.validated(nil))
        for target in rejected {
            XCTAssertNil(RouteWebReturnPolicy.validated(target), target)
        }
    }

    func testDevelopmentHTTPReturnIsRestrictedToPreviewHostPortAndPage() {
        let local = ["http://localhost:8766/ar-demo.html?lang=zh#store",
                     "http://127.0.0.1:8770/ar-test.html",
                     "http://192.168.1.8:8766/", "http://10.0.0.8:8770/ar-demo.html",
                     "http://172.16.0.8:8770/ar-test.html",
                     "http://127.0.0.1:59323/?screen=detail&store=uniqlo",
                     "http://192.168.1.8:59323/"]
        for target in local {
#if DEBUG
            XCTAssertEqual(RouteWebReturnPolicy.validated(target), URL(string: target), target)
#else
            XCTAssertNil(RouteWebReturnPolicy.validated(target), target)
#endif
        }
        for target in ["http://example.com:8766/ar-demo.html",
                       "http://example.com:59323/", "http://127.0.0.1:59323/index.html",
                       "http://192.168.1.8:8080/ar-demo.html",
                       "http://192.168.1.8:8766/other.html",
                       "http://172.32.0.1:8770/ar-test.html",
                       "http://192.168.1.256:8766/ar-demo.html",
                       "http://localhost:8766/guide/B02001HUD4"] {
            XCTAssertNil(RouteWebReturnPolicy.validated(target), target)
        }
    }
}
