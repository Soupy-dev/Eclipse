import CryptoKit
import Darwin
import Security
import SwiftSoup
import UIKit
import WebKit
import XCTest
@testable import Eclipse

#if os(iOS)
final class ReaderExtensionCoreTests: XCTestCase {
    private let publicBaseURL = URL(string: "https://93.184.216.34")!

    func testRuntimeDateParserRejectsNonFiniteAndUnboundedTimestamps() {
        XCTAssertNil(ReaderExtensionJavaScriptRuntime.date(Double.nan))
        XCTAssertNil(ReaderExtensionJavaScriptRuntime.date(Double.infinity))
        XCTAssertNil(ReaderExtensionJavaScriptRuntime.date(1e300))
        XCTAssertNil(ReaderExtensionJavaScriptRuntime.date("nan"))
        XCTAssertNil(ReaderExtensionJavaScriptRuntime.date("inf"))
        XCTAssertEqual(
            ReaderExtensionJavaScriptRuntime.date(1_700_000_000),
            Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(
            ReaderExtensionJavaScriptRuntime.date("1700000000000"),
            Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testRepositoryCatalogHydrationDoesNotConfuseFreshMetadataWithLoadedCatalog() {
        var repository = ReaderExtensionRepositoryRecord(
            indexURL: URL(string: "https://repo.example/index.json")!
        )
        repository.lastRefreshedAt = Date()
        repository.sourceCount = 324

        XCTAssertTrue(ReaderExtensionRepositoryCatalogHydrationPolicy.needsHydration(
            repository: repository,
            hasLoadedCatalog: false
        ))
        XCTAssertFalse(ReaderExtensionRepositoryCatalogHydrationPolicy.needsHydration(
            repository: repository,
            hasLoadedCatalog: true
        ))

        repository.isEnabled = false
        XCTAssertFalse(ReaderExtensionRepositoryCatalogHydrationPolicy.needsHydration(
            repository: repository,
            hasLoadedCatalog: false
        ))
        XCTAssertFalse(ReaderExtensionRepositoryCatalogHydrationPolicy.needsHydration(
            repository: nil,
            hasLoadedCatalog: false
        ))
    }

    func testRepositoryInputAcceptsMangayomiAddRepoLinksWithoutRelaxingCatalogURLPolicy() throws {
        let direct = "https://repo.example/catalog/index.json"
        XCTAssertEqual(
            try ReaderExtensionRepositoryInput.repositoryURLs(from: direct).map(\.absoluteString),
            [direct]
        )

        let deepLink = "mangayomi://add-repo?repo_name=fixture&repo_url=https://github.com/example/extensions&manga_url=https://repo.example/catalog/index.json&anime_url=https://repo.example/catalog/anime_index.json&novel_url=https://repo.example/catalog/novel_index.json"
        XCTAssertEqual(
            try ReaderExtensionRepositoryInput.repositoryURLs(from: deepLink).map(\.absoluteString),
            [
                "https://repo.example/catalog/index.json",
                "https://repo.example/catalog/novel_index.json"
            ]
        )

        let wrapped = "https://intradeus.github.io/http-protocol-redirector?r=mangayomi://add-repo?repo_name=fixture%26manga_url=https://repo.example/catalog/index.json%26novel_url=https://repo.example/catalog/novel_index.json"
        XCTAssertEqual(
            try ReaderExtensionRepositoryInput.repositoryURLs(from: wrapped).map(\.absoluteString),
            [
                "https://repo.example/catalog/index.json",
                "https://repo.example/catalog/novel_index.json"
            ]
        )

        XCTAssertThrowsError(try ReaderExtensionRepositoryInput.repositoryURLs(
            from: "mangayomi://add-repo?manga_url=http://repo.example/index.json"
        ))
        XCTAssertThrowsError(try ReaderExtensionRepositoryInput.repositoryURLs(
            from: "https://untrusted.example/redirect?r=mangayomi://add-repo?manga_url=https://repo.example/index.json"
        ))
        XCTAssertThrowsError(try ReaderExtensionRepositoryInput.repositoryURLs(
            from: "mangayomi://add-repo?repo_url=https://github.com/example/extensions"
        ))
    }

    func testReaderExtensionSourceWebsiteUsesExternalBrowserBoundaryWithoutCredentialURLs() {
        XCTAssertNotNil(
            ReaderExtensionExternalBrowserBoundary.validatedURL(
                URL(string: "https://reader.example/sign-in")!
            )
        )
        XCTAssertNotNil(
            ReaderExtensionExternalBrowserBoundary.validatedURL(
                URL(string: "http://reader.example/")!
            )
        )
        XCTAssertNil(
            ReaderExtensionExternalBrowserBoundary.validatedURL(
                URL(string: "https://user:secret@reader.example/sign-in")!
            )
        )
        XCTAssertNil(
            ReaderExtensionExternalBrowserBoundary.validatedURL(
                URL(string: "javascript:alert(1)")!
            )
        )
        XCTAssertNil(
            ReaderExtensionExternalBrowserBoundary.validatedURL(
                URL(string: "file:///tmp/sign-in.html")!
            )
        )
        XCTAssertTrue(
            ReaderExtensionExternalBrowserBoundary.disclosure.contains("not imported into Eclipse")
        )
        XCTAssertTrue(
            ReaderExtensionExternalBrowserBoundary.disclosure.contains("use Sign In above")
        )
    }

    func testInstalledDeclaredDomainsAutoAuthorizeExactlyAndRemainProfileDeviceScoped() throws {
        var source = installedSource(implementation: .javascript)
        source.activeContentDigest = String(repeating: "a", count: 64)
        source.declaredDomains = [
            "reader.example",
            "api.reader.example",
            "BÜCHER.example.",
            "127.0.0.1",
            "localhost"
        ]
        let expected: Set<String> = [
            "reader.example",
            "api.reader.example",
            "xn--bcher-kva.example"
        ]
        let profileA = "domain-policy-profile-a-\(UUID().uuidString)"
        let profileB = "domain-policy-profile-b-\(UUID().uuidString)"
        let deviceA = ReaderExtensionInjectedKeychainAccess(accounts: [:])
        let deviceB = ReaderExtensionInjectedKeychainAccess(accounts: [:])
        let profileAStore = ReaderExtensionKeychainStore(
            sourceID: source.id,
            namespace: profileA,
            keychain: deviceA
        )
        let profileBStore = ReaderExtensionKeychainStore(
            sourceID: source.id,
            namespace: profileB,
            keychain: deviceA
        )
        let otherDeviceStore = ReaderExtensionKeychainStore(
            sourceID: source.id,
            namespace: profileA,
            keychain: deviceB
        )

        XCTAssertTrue(profileAStore.approvedDomains().isEmpty)
        XCTAssertEqual(
            try ReaderExtensionInstalledDomainAuthorizationPolicy.reconcile(
                source: source,
                store: profileAStore
            ),
            expected
        )
        XCTAssertEqual(profileAStore.approvedDomains(), expected)
        XCTAssertTrue(profileBStore.approvedDomains().isEmpty)
        XCTAssertTrue(otherDeviceStore.approvedDomains().isEmpty)

        // A stale approval is replaced, not merged, so a redirect that the
        // installed source does not declare cannot inherit network authority.
        try profileAStore.setApprovedDomains(expected.union([
            "redirect.reader.example",
            "127.0.0.1"
        ]))
        XCTAssertEqual(
            try ReaderExtensionInstalledDomainAuthorizationPolicy.reconcile(
                source: source,
                store: profileAStore
            ),
            expected
        )
        XCTAssertEqual(profileAStore.approvedDomains(), expected)
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.validateApprovedDomain(
            URL(string: "https://redirect.reader.example/chapter")!,
            approvedDomains: profileAStore.approvedDomains()
        )) { error in
            XCTAssertEqual(
                error as? ReaderExtensionError,
                .domainConsentRequired("redirect.reader.example")
            )
        }
    }

    func testInstalledDeclaredDomainAuthorizationRefusesInertSourceMetadata() throws {
        var source = installedSource(implementation: .javascript)
        source.activeContentDigest = String(repeating: "a", count: 64)
        source.declaredDomains = ["reader.example"]
        let keychain = ReaderExtensionInjectedKeychainAccess(accounts: [:])
        let store = ReaderExtensionKeychainStore(
            sourceID: source.id,
            namespace: "domain-policy-inert-\(UUID().uuidString)",
            keychain: keychain
        )
        try store.setApprovedDomains(["reader.example"])

        source.requiresReinstall = true
        XCTAssertTrue(try ReaderExtensionInstalledDomainAuthorizationPolicy.reconcile(
            source: source,
            store: store
        ).isEmpty)
        XCTAssertTrue(store.approvedDomains().isEmpty)

        source.requiresReinstall = false
        source.activeContentDigest = nil
        try store.setApprovedDomains(["reader.example"])
        XCTAssertTrue(try ReaderExtensionInstalledDomainAuthorizationPolicy.reconcile(
            source: source,
            store: store
        ).isEmpty)
        XCTAssertTrue(store.approvedDomains().isEmpty)
    }

    func testInstalledDeclaredDomainRuntimeAuthoritySurvivesKeychainMirrorFailure() throws {
        var source = installedSource(implementation: .javascript)
        source.activeContentDigest = String(repeating: "a", count: 64)
        source.declaredDomains = ["api.mangadex.org", "127.0.0.1"]
        let keychain = ReaderExtensionInjectedKeychainAccess(
            accounts: [:],
            addFailure: errSecInteractionNotAllowed
        )
        let store = ReaderExtensionKeychainStore(
            sourceID: source.id,
            namespace: "domain-policy-write-failure-\(UUID().uuidString)",
            keychain: keychain
        )
        var persistenceFailureCount = 0

        let runtimeDomains = ReaderExtensionInstalledDomainAuthorizationPolicy
            .runtimeAuthorizedDomains(
                source: source,
                store: store,
                onPersistenceFailure: { persistenceFailureCount += 1 }
            )

        XCTAssertEqual(runtimeDomains, ["api.mangadex.org"])
        XCTAssertEqual(persistenceFailureCount, 1)
        XCTAssertTrue(store.approvedDomains().isEmpty, "the failed mirror must not be reported as durable")
        XCTAssertNoThrow(try ReaderExtensionSecurityPolicy.validateApprovedDomain(
            URL(string: "https://api.mangadex.org/manga")!,
            approvedDomains: runtimeDomains
        ))
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.validateApprovedDomain(
            URL(string: "https://undeclared.mangadex.org/manga")!,
            approvedDomains: runtimeDomains
        ))
    }

    func testUserApprovedDomainsSurviveDeclaredMirrorReconciliation() throws {
        var source = installedSource(implementation: .javascript)
        source.activeContentDigest = String(repeating: "a", count: 64)
        source.declaredDomains = ["reader.example"]
        let keychain = ReaderExtensionInjectedKeychainAccess(accounts: [:])
        let store = ReaderExtensionKeychainStore(
            sourceID: source.id,
            namespace: "domain-policy-user-approval-\(UUID().uuidString)",
            keychain: keychain
        )

        try store.setUserApprovedDomains(["cdn.reader.example"])
        for _ in 0..<3 {
            let authorized = ReaderExtensionInstalledDomainAuthorizationPolicy.runtimeAuthorizedDomains(
                source: source,
                store: store,
                onPersistenceFailure: { XCTFail("mirror persistence must succeed") }
            )
            XCTAssertEqual(
                authorized,
                ["reader.example", "cdn.reader.example"],
                "an explicit user approval must survive repeated declared-mirror reconciliation"
            )
        }
        XCTAssertEqual(
            store.approvedDomains(),
            ["reader.example"],
            "the declared mirror must not absorb user approvals"
        )
        XCTAssertEqual(store.userApprovedDomains(), ["cdn.reader.example"])

        try store.setUserApprovedDomains(["cdn.reader.example", "127.0.0.1", "localhost"])
        let filtered = ReaderExtensionInstalledDomainAuthorizationPolicy.runtimeAuthorizedDomains(
            source: source,
            store: store,
            onPersistenceFailure: { XCTFail("mirror persistence must succeed") }
        )
        XCTAssertEqual(
            filtered,
            ["reader.example", "cdn.reader.example"],
            "private and local user entries must be refused at read time"
        )

        source.requiresReinstall = true
        XCTAssertTrue(
            ReaderExtensionInstalledDomainAuthorizationPolicy.runtimeAuthorizedDomains(
                source: source,
                store: store,
                onPersistenceFailure: {}
            ).isEmpty,
            "user approvals grant nothing while the source is not runnable"
        )
    }

    @MainActor
    func testReaderDomainConsentHasOneContextualOwnerOrOneDelayedGlobalPrompt() async throws {
        let coordinator = ReaderExtensionDomainConsentCoordinator(claimWindow: 0.02)
        let sourceID = ReaderExtensionSourceID(rawValue: "reader:owned-consent")
        let contextual = ReaderExtensionDomainConsentRequest(
            scopeID: UUID().uuidString,
            sourceID: sourceID,
            host: "reader.example"
        )
        XCTAssertTrue(coordinator.claim(contextual))
        coordinator.enqueue(contextual)
        XCTAssertFalse(coordinator.claim(contextual), "the exact request can have only one contextual owner")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNil(coordinator.pendingRequest, "a claimed request must not also reach the global alert")
        coordinator.defer(contextual)

        let background = ReaderExtensionDomainConsentRequest(
            scopeID: contextual.scopeID,
            sourceID: sourceID,
            host: "images.reader.example"
        )
        coordinator.enqueue(background)
        XCTAssertNil(coordinator.pendingRequest, "global presentation waits for a contextual claim")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(coordinator.pendingRequest, background)
        coordinator.defer(background)
        XCTAssertNil(coordinator.pendingRequest)
    }

    @MainActor
    func testReaderDomainConsentBacklogIsBoundedAndStaleClaimsRecover() async throws {
        let sourceA = ReaderExtensionSourceID(rawValue: String(repeating: "a", count: 64))
        let sourceB = ReaderExtensionSourceID(rawValue: String(repeating: "b", count: 64))
        let scope = UUID().uuidString
        let bounded = ReaderExtensionDomainConsentCoordinator(
            claimWindow: 1,
            requestLifetime: 5,
            claimLifetime: 1,
            maximumPendingRequests: 3,
            maximumPendingRequestsPerSource: 2
        )
        let a1 = ReaderExtensionDomainConsentRequest(scopeID: scope, sourceID: sourceA, host: "one.example")
        let a2 = ReaderExtensionDomainConsentRequest(scopeID: scope, sourceID: sourceA, host: "two.example")
        let a3 = ReaderExtensionDomainConsentRequest(scopeID: scope, sourceID: sourceA, host: "three.example")
        let b1 = ReaderExtensionDomainConsentRequest(scopeID: scope, sourceID: sourceB, host: "four.example")
        let b2 = ReaderExtensionDomainConsentRequest(scopeID: scope, sourceID: sourceB, host: "five.example")
        bounded.enqueue(a1)
        bounded.enqueue(a2)
        bounded.enqueue(a3)
        bounded.enqueue(b1)
        bounded.enqueue(b2)
        XCTAssertEqual(bounded.queuedRequestCount, 3)
        XCTAssertTrue(bounded.claim(a1))
        XCTAssertEqual(bounded.claimedRequestCount, 1)
        XCTAssertLessThanOrEqual(bounded.claimedRequestCount, bounded.queuedRequestCount)
        bounded.resetForScopeChange()

        let stale = ReaderExtensionDomainConsentCoordinator(
            claimWindow: 0.005,
            requestLifetime: 1,
            claimLifetime: 0.03,
            maximumPendingRequests: 4,
            maximumPendingRequestsPerSource: 2
        )
        XCTAssertTrue(stale.claim(a1), "claiming first must also create its bounded queued owner")
        XCTAssertEqual(stale.queuedRequestCount, 1)
        XCTAssertEqual(stale.claimedRequestCount, 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(stale.pendingRequest, a1, "an abandoned contextual claim must return to global fallback")
        XCTAssertEqual(stale.claimedRequestCount, 0)
        stale.defer(a1)
        XCTAssertEqual(stale.queuedRequestCount, 0)
    }

    func testReaderSignInProxyIsHTTPSOnlyRoundTripsAndRejectsUnapprovedTargets() throws {
        let original = URL(string: "https://reader.example/sign-in?next=%2Flibrary#form")!
        let proxied = try ReaderExtensionSignInURLProxy.proxyURL(for: original)
        XCTAssertEqual(proxied.scheme, ReaderExtensionSignInURLProxy.secureScheme)
        XCTAssertEqual(
            try ReaderExtensionSignInURLProxy.originalURL(
                from: proxied,
                approvedDomains: ["reader.example"]
            ),
            original
        )
        XCTAssertThrowsError(try ReaderExtensionSignInURLProxy.proxyURL(
            for: URL(string: "http://reader.example/sign-in")!
        ))
        XCTAssertThrowsError(try ReaderExtensionSignInURLProxy.proxyURL(
            for: URL(string: "https://127.0.0.1/private")!
        ))
        XCTAssertThrowsError(try ReaderExtensionSignInURLProxy.proxyURL(
            for: URL(string: "https://reader.example/\(String(repeating: "x", count: ReaderExtensionSignInURLProxy.maximumURLBytes))")!
        ))
        let tracker = URL(string: "\(ReaderExtensionSignInURLProxy.secureScheme)://tracker.example/pixel")!
        XCTAssertThrowsError(try ReaderExtensionSignInURLProxy.originalURL(
            from: tracker,
            approvedDomains: ["reader.example"]
        ))
        XCTAssertThrowsError(try ReaderExtensionSignInURLProxy.originalURL(
            from: original,
            approvedDomains: ["reader.example"]
        ), "a direct WebKit HTTPS load is never accepted by the proxy handler")
        XCTAssertFalse(ReaderExtensionSignInURLProxy.contentSecurityPolicy.contains(" https:"))
        XCTAssertFalse(ReaderExtensionSignInURLProxy.contentSecurityPolicy.contains(" http:"))
    }

    func testReaderSignInRewriteInstallsPolicyBeforePreHeadScriptAndRewritesTraffic() throws {
        let base = URL(string: "https://reader.example/login")!
        let remoteScript = "<script>window.preHeadRan=true;fetch('https://tracker.example/x')</script>"
        let html = remoteScript + """
        <html><head><link href="/login.css" rel="stylesheet"></head>
        <body style="background:url(https://reader.example/bg.png)">
        <form action="/session" method="post"><img src="http://reader.example/insecure.png"></form>
        <img src="https://127.0.0.1/private"><img src="https://tracker.example/pixel">
        <a href="javascript:window.stolen=true">blocked</a>
        </body></html>
        """
        let rewritten = try ReaderExtensionSignInContentRewriter.rewriteHTML(
            html,
            baseURL: base
        )
        let csp = try XCTUnwrap(rewritten.range(of: "Content-Security-Policy"))
        let bootstrap = try XCTUnwrap(rewritten.range(of: "const secureScheme"))
        let preHead = try XCTUnwrap(rewritten.range(of: "window.preHeadRan"))
        XCTAssertLessThan(csp.lowerBound, bootstrap.lowerBound)
        XCTAssertLessThan(bootstrap.lowerBound, preHead.lowerBound)
        XCTAssertTrue(rewritten.contains("\(ReaderExtensionSignInURLProxy.secureScheme)://reader.example/session"))
        XCTAssertTrue(rewritten.contains("\(ReaderExtensionSignInURLProxy.secureScheme)://reader.example/login.css"))
        XCTAssertTrue(rewritten.contains("about:blank#blocked-insecure-reader-auth-load"))
        XCTAssertTrue(rewritten.contains("about:blank#blocked-reader-auth-target"))
        XCTAssertTrue(rewritten.contains("\(ReaderExtensionSignInURLProxy.secureScheme)://tracker.example/pixel"))
        XCTAssertTrue(rewritten.contains("about:blank#blocked-reader-auth-scheme"))
        XCTAssertFalse(rewritten.contains("src=\"https://127.0.0.1/private\""))
        XCTAssertTrue(rewritten.contains("XMLHttpRequest.prototype.open"))
        XCTAssertTrue(rewritten.contains("HTMLFormElement.prototype.submit"))
    }

    func testReaderSignInFramePolicyAllowsOnlyApprovedProxyFrames() throws {
        let base = URL(string: "https://reader.example/login")!
        let rewritten = try ReaderExtensionSignInContentRewriter.rewriteHTML(
            "<iframe src=\"https://reader.example/captcha\"></iframe>",
            baseURL: base
        )
        XCTAssertTrue(
            ReaderExtensionSignInURLProxy.contentSecurityPolicy.contains(
                "frame-ancestors \(ReaderExtensionSignInURLProxy.secureScheme):"
            )
        )
        XCTAssertFalse(ReaderExtensionSignInURLProxy.contentSecurityPolicy.contains("frame-ancestors 'none'"))
        XCTAssertTrue(rewritten.contains(
            "\(ReaderExtensionSignInURLProxy.secureScheme)://reader.example/captcha"
        ))
        let trackerFrame = URL(
            string: "\(ReaderExtensionSignInURLProxy.secureScheme)://tracker.example/captcha"
        )!
        XCTAssertThrowsError(try ReaderExtensionSignInURLProxy.originalURL(
            from: trackerFrame,
            approvedDomains: ["reader.example"]
        ))
    }

    func testReaderSignInPOSTBodyAndCSRFHeadersReachSecureRequestTranslation() throws {
        let sourceID = ReaderExtensionSourceID(rawValue: "reader:owned-sign-in")
        let page = URL(string: "https://reader.example/login")!
        let proxyPage = try ReaderExtensionSignInURLProxy.proxyURL(for: page)
        var request = URLRequest(url: try ReaderExtensionSignInURLProxy.proxyURL(
            for: URL(string: "https://reader.example/session")!
        ))
        request.httpMethod = "POST"
        request.httpBody = Data("username=owned%40example.test&password=fixture".utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("\(ReaderExtensionSignInURLProxy.secureScheme)://reader.example", forHTTPHeaderField: "Origin")
        request.setValue(proxyPage.absoluteString, forHTTPHeaderField: "Referer")

        let translated = try ReaderExtensionSignInRequestTranslator.networkRequest(
            from: request,
            sourceID: sourceID,
            approvedDomains: ["reader.example"],
            baseDomain: "reader.example"
        )
        XCTAssertEqual(translated.method, .post)
        XCTAssertEqual(translated.url.absoluteString, "https://reader.example/session")
        XCTAssertEqual(translated.body, request.httpBody)
        XCTAssertEqual(translated.headers["Origin"], "https://reader.example")
        XCTAssertEqual(translated.headers["Referer"], page.absoluteString)
        XCTAssertEqual(translated.baseDomain, "reader.example")
        XCTAssertTrue(translated.allowsCookies)

        var nullOrigin = request
        nullOrigin.setValue("null", forHTTPHeaderField: "Origin")
        nullOrigin.setValue("https://untranslated.example/path", forHTTPHeaderField: "Referer")
        let stripped = try ReaderExtensionSignInRequestTranslator.networkRequest(
            from: nullOrigin,
            sourceID: sourceID,
            approvedDomains: ["reader.example"],
            baseDomain: "reader.example"
        )
        XCTAssertNil(stripped.headers["Origin"])
        XCTAssertNil(stripped.headers["Referer"])
        XCTAssertNil(stripped.baseDomain)
        XCTAssertFalse(stripped.allowsCookies)

        // Missing browser initiator headers are not evidence that this is a
        // same-origin request. In particular, an approved B frame can suppress
        // both headers before requesting approved A; A's cookie must stay out.
        var missingInitiator = URLRequest(url: try ReaderExtensionSignInURLProxy.proxyURL(
            for: URL(string: "https://reader.example/session")!
        ))
        missingInitiator.httpMethod = "POST"
        missingInitiator.httpBody = Data("from=approved-b".utf8)
        let missingTranslated = try ReaderExtensionSignInRequestTranslator.networkRequest(
            from: missingInitiator,
            sourceID: sourceID,
            approvedDomains: ["reader.example", "auth.reader.example"],
            baseDomain: "reader.example"
        )
        XCTAssertNil(missingTranslated.baseDomain)
        XCTAssertFalse(missingTranslated.allowsCookies)
        XCTAssertFalse(ReaderExtensionCookieAdmissionPolicy.allowsCookies(
            for: missingTranslated.url,
            request: missingTranslated
        ), "approved B to A traffic without a trustworthy initiator must not receive A's cookie")

        var explicitInitial = URLRequest(url: try ReaderExtensionSignInURLProxy.proxyURL(for: page))
        explicitInitial.httpMethod = "GET"
        let initialTranslated = try ReaderExtensionSignInRequestTranslator.networkRequest(
            from: explicitInitial,
            sourceID: sourceID,
            approvedDomains: ["reader.example", "auth.reader.example"],
            baseDomain: "reader.example",
            isExplicitInitialTopLevelNavigation: true
        )
        XCTAssertEqual(initialTranslated.baseDomain, "reader.example")
        XCTAssertTrue(initialTranslated.allowsCookies)

        let alternateOriginal = URL(string: "https://reader.example:8443/session")!
        var alternate = URLRequest(url: try ReaderExtensionSignInURLProxy.proxyURL(for: alternateOriginal))
        alternate.setValue(
            "\(ReaderExtensionSignInURLProxy.secureScheme)://reader.example:8443",
            forHTTPHeaderField: "Origin"
        )
        let alternateTranslated = try ReaderExtensionSignInRequestTranslator.networkRequest(
            from: alternate,
            sourceID: sourceID,
            approvedDomains: ["reader.example"],
            baseDomain: "reader.example"
        )
        XCTAssertEqual(alternateTranslated.url, alternateOriginal)
        XCTAssertEqual(alternateTranslated.headers["Origin"], "https://reader.example:8443")

        var crossOrigin = URLRequest(url: try ReaderExtensionSignInURLProxy.proxyURL(
            for: URL(string: "https://auth.reader.example/session")!
        ))
        crossOrigin.httpMethod = "POST"
        crossOrigin.httpBody = Data("action=owned".utf8)
        crossOrigin.setValue(
            "\(ReaderExtensionSignInURLProxy.secureScheme)://reader.example",
            forHTTPHeaderField: "Origin"
        )
        let crossTranslated = try ReaderExtensionSignInRequestTranslator.networkRequest(
            from: crossOrigin,
            sourceID: sourceID,
            approvedDomains: ["reader.example", "auth.reader.example"],
            baseDomain: "reader.example"
        )
        XCTAssertEqual(crossTranslated.baseDomain, "reader.example")
        XCTAssertFalse(crossTranslated.allowsCookies)
        XCTAssertFalse(ReaderExtensionCookieAdmissionPolicy.allowsCookies(
            for: crossTranslated.url,
            request: crossTranslated
        ), "approved origin A must not attach ambient auth cookies to approved origin B")

        let redirectTarget = URL(string: "https://auth.reader.example/callback")!
        XCTAssertTrue(ReaderExtensionCookieAdmissionPolicy.allowsCookies(
            for: page,
            request: translated
        ))
        XCTAssertFalse(ReaderExtensionCookieAdmissionPolicy.allowsCookies(
            for: redirectTarget,
            request: translated
        ), "a same-origin request must not regain target cookies after a cross-origin redirect")

        let providerScoped = ReaderExtensionNetworkRequest(
            url: redirectTarget,
            sourceID: sourceID,
            approvedDomains: ["reader.example", "auth.reader.example"],
            baseDomain: "reader.example"
        )
        XCTAssertTrue(ReaderExtensionCookieAdmissionPolicy.allowsCookies(
            for: redirectTarget,
            request: providerScoped
        ), "provider/download authentication retains its explicit source-scoped behavior")

        let cors = ReaderExtensionSignInResponseHeaderPolicy.sanitizedHeaders(
            [
                "Access-Control-Allow-Origin": "https://reader.example:8443",
                "Set-Cookie": "owned=secret",
                "Location": "https://tracker.example/collect"
            ],
            bodyCount: 2,
            approvedDomains: ["reader.example"]
        )
        XCTAssertEqual(
            cors["Access-Control-Allow-Origin"],
            "\(ReaderExtensionSignInURLProxy.secureScheme)://reader.example:8443"
        )
        XCTAssertNil(cors["Set-Cookie"])
        XCTAssertNil(cors["Location"])
        let rejectedCORS = ReaderExtensionSignInResponseHeaderPolicy.sanitizedHeaders(
            ["Access-Control-Allow-Origin": "https://tracker.example"],
            bodyCount: 0,
            approvedDomains: ["reader.example"]
        )
        XCTAssertNil(rejectedCORS["Access-Control-Allow-Origin"])
    }

    @MainActor
    func testReaderSignInOwnedWebKitFormPOSTCarriesURLEncodedBody() async throws {
        let expectation = expectation(description: "custom-scheme form POST reached translator")
        let handler = ReaderExtensionFormPOSTFixtureHandler(expectation: expectation)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(
            handler,
            forURLScheme: ReaderExtensionSignInURLProxy.secureScheme
        )
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        webView.load(URLRequest(url: URL(
            string: "\(ReaderExtensionSignInURLProxy.secureScheme)://reader.example/login"
        )!))
        // WKWebView's first load in a fresh test clone can take well over
        // five seconds while WebKit warms up; the deadline guards against a
        // hang, not ordinary cold-start latency.
        await fulfillment(of: [expectation], timeout: 60)
        let captured = try XCTUnwrap(handler.capturedRequest)
        XCTAssertEqual(captured.method, .post)
        XCTAssertEqual(captured.url.absoluteString, "https://reader.example/session")
        XCTAssertEqual(captured.headers["Origin"], "https://reader.example")
        // WebKit may omit Referer for a custom-scheme form. If it supplies
        // one, the production translator must restore the original HTTPS URL.
        if let referer = captured.headers["Referer"] {
            XCTAssertEqual(referer, "https://reader.example/login")
        }
        XCTAssertEqual(
            String(data: try XCTUnwrap(captured.body), encoding: .utf8),
            "username=owned%40example.test&password=fixture"
        )
        _ = webView
    }

    func testReaderSignInCookiePoliciesPersistOnlyCurrentApprovedOrigin() throws {
        let urlA = URL(string: "https://a.reader.example/login")!
        let urlB = URL(string: "https://b.reader.example/login")!
        let approved: Set<String> = ["a.reader.example", "b.reader.example"]
        let cookieA = try XCTUnwrap(HTTPCookie(properties: [
            .name: "session_a", .value: "old", .domain: "a.reader.example", .path: "/", .secure: "TRUE"
        ]))
        let cookieB = try XCTUnwrap(HTTPCookie(properties: [
            .name: "session_b", .value: "private-b", .domain: "b.reader.example", .path: "/", .secure: "TRUE"
        ]))
        let merged = try XCTUnwrap(ReaderExtensionSecureHTTPClient.cookiesByMergingResponse(
            ["session_a=new; Path=/; Secure; HttpOnly"],
            responseURL: urlA,
            approvedDomains: approved,
            existing: [cookieA, cookieB]
        ))
        XCTAssertEqual(merged.first(where: { $0.name == "session_a" })?.value, "new")
        XCTAssertEqual(merged.first(where: { $0.name == "session_b" })?.value, "private-b")
        XCTAssertFalse(ReaderExtensionSecurityPolicy.cookie(
            cookieB,
            mayBeSentTo: urlA,
            approvedDomains: approved
        ), "one approved frame must not see another approved host's cookie")

        let scriptMerged = try ReaderExtensionSignInCookieBridge.cookiesByMergingScriptWrite(
            "theme=dark; Path=/; Secure",
            originalURL: urlA,
            approvedDomains: approved,
            existing: merged
        )
        XCTAssertEqual(scriptMerged.first(where: { $0.name == "theme" })?.value, "dark")
        XCTAssertThrowsError(try ReaderExtensionSignInCookieBridge.cookiesByMergingScriptWrite(
            "stolen=value; Domain=b.reader.example; Path=/; Secure",
            originalURL: urlA,
            approvedDomains: approved,
            existing: scriptMerged
        ))
        XCTAssertThrowsError(try ReaderExtensionSignInCookieBridge.cookiesByMergingScriptWrite(
            "hidden=value; Path=/; Secure; HttpOnly",
            originalURL: urlA,
            approvedDomains: approved,
            existing: scriptMerged
        ))
        _ = urlB
    }

    func testReaderCookieStorePrunesBoundsAndKeepsCurrentRotations() throws {
        let sourceID = ReaderExtensionSourceID(rawValue: "reader:owned-cookie-bounds")
        let keychain = ReaderExtensionInjectedKeychainAccess(accounts: [:])
        let store = ReaderExtensionKeychainStore(
            sourceID: sourceID,
            namespace: UUID().uuidString,
            keychain: keychain
        )
        let existing = try (0..<ReaderExtensionKeychainStore.maximumStoredCookieCount).map { index in
            try XCTUnwrap(HTTPCookie(properties: [
                .name: String(format: "cookie%03d", index),
                .value: "old-\(index)",
                .domain: "reader.example",
                .path: "/",
                .secure: "TRUE"
            ]))
        }
        let merged = try XCTUnwrap(ReaderExtensionSecureHTTPClient.cookiesByMergingResponse(
            [
                "cookie199=rotated; Path=/; Secure; SameSite=Strict",
                "cookie200=fresh; Path=/; Secure",
                "cookie201=freshest; Path=/; Secure",
                "cookie050=deleted; Path=/; Secure; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
            ],
            responseURL: URL(string: "https://reader.example/login")!,
            approvedDomains: ["reader.example"],
            existing: existing
        ))
        try store.setCookies(merged)
        let persisted = store.cookies()
        XCTAssertEqual(persisted.count, ReaderExtensionKeychainStore.maximumStoredCookieCount)
        XCTAssertEqual(persisted.first(where: { $0.name == "cookie199" })?.value, "rotated")
        XCTAssertEqual(
            persisted.first(where: { $0.name == "cookie199" })?.sameSitePolicy,
            HTTPCookieStringPolicy.sameSiteStrict
        )
        XCTAssertEqual(persisted.first(where: { $0.name == "cookie200" })?.value, "fresh")
        XCTAssertEqual(persisted.first(where: { $0.name == "cookie201" })?.value, "freshest")
        XCTAssertNil(persisted.first(where: { $0.name == "cookie050" }))
        XCTAssertNil(persisted.first(where: { $0.name == "cookie000" }), "oldest existing row is evicted before current incoming cookies")
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(keychain.accounts.values.first).count,
            ReaderExtensionKeychainStore.maximumStoredCookieBytes
        )

        let aggregateKeychain = ReaderExtensionInjectedKeychainAccess(accounts: [:])
        let aggregateStore = ReaderExtensionKeychainStore(
            sourceID: sourceID,
            namespace: UUID().uuidString,
            keychain: aggregateKeychain
        )
        let largeCookies = try (0..<ReaderExtensionKeychainStore.maximumStoredCookieCount).map { index in
            try XCTUnwrap(HTTPCookie(properties: [
                .name: String(format: "large%03d", index),
                .value: String(repeating: "x", count: 4_000),
                .domain: "reader.example",
                .path: "/",
                .secure: "TRUE"
            ]))
        }
        try aggregateStore.setCookies(largeCookies)
        let aggregatePersisted = aggregateStore.cookies()
        XCTAssertLessThan(aggregatePersisted.count, largeCookies.count)
        XCTAssertNotNil(aggregatePersisted.first(where: { $0.name == "large199" }))
        XCTAssertNil(aggregatePersisted.first(where: { $0.name == "large000" }))
        XCTAssertLessThanOrEqual(
            try XCTUnwrap(aggregateKeychain.accounts.values.first).count,
            ReaderExtensionKeychainStore.maximumStoredCookieBytes
        )

        let oversized = try XCTUnwrap(HTTPCookie(properties: [
            .name: String(repeating: "n", count: ReaderExtensionKeychainStore.maximumCookieNameBytes + 1),
            .value: "oversized",
            .domain: "reader.example",
            .path: "/",
            .secure: "TRUE"
        ]))
        XCTAssertThrowsError(try aggregateStore.setCookies([oversized]))
    }

    func testReaderSignInResourceBudgetStopsDeterministically() throws {
        let countBudget = ReaderExtensionSignInResourceBudget(
            maximumTotalRequests: 2,
            maximumRequestBytes: 10,
            maximumResponseBytes: 12
        )
        XCTAssertNoThrow(try countBudget.reserveRequest())
        XCTAssertNoThrow(try countBudget.reserveRequest())
        XCTAssertThrowsError(try countBudget.reserveRequest()) { error in
            XCTAssertEqual(error as? ReaderExtensionSignInResourceLimitError, .totalRequests)
        }
        XCTAssertTrue(countBudget.isStopped)

        let byteBudget = ReaderExtensionSignInResourceBudget(
            maximumTotalRequests: 4,
            maximumRequestBytes: 5,
            maximumResponseBytes: 6
        )
        try byteBudget.reserveRequest()
        try byteBudget.recordRequestBytes(5)
        XCTAssertThrowsError(try byteBudget.recordRequestBytes(1))
        XCTAssertTrue(byteBudget.isStopped)

        let responseBudget = ReaderExtensionSignInResourceBudget(
            maximumTotalRequests: 4,
            maximumRequestBytes: 5,
            maximumResponseBytes: 6
        )
        try responseBudget.reserveRequest()
        try responseBudget.recordResponseBytes(6)
        XCTAssertThrowsError(try responseBudget.recordResponseBytes(1))
        XCTAssertTrue(responseBudget.isStopped)
    }

    func testReaderSignInRewriteRejectsDenseAmplificationInput() {
        let dense = String(repeating: "<img src=x>", count: ReaderExtensionSignInContentRewriter.maximumRewriteCandidates + 1)
        XCTAssertThrowsError(try ReaderExtensionSignInContentRewriter.rewrittenBody(
            Data(dense.utf8),
            contentType: "text/html; charset=utf-8",
            finalURL: URL(string: "https://reader.example/")!
        ))
    }

    func testReaderSignInRewriteStopsLongBaseAmplificationIncrementally() throws {
        let longPath = String(repeating: "a", count: 12 * 1_024)
        let base = try XCTUnwrap(URL(string: "https://reader.example/\(longPath)/login"))
        let manyShortReferences = String(repeating: "<img src=x>", count: 400)
        XCTAssertThrowsError(try ReaderExtensionSignInContentRewriter.rewriteHTML(
            manyShortReferences,
            baseURL: base
        )) { error in
            guard let readerError = error as? ReaderExtensionError,
                  case .contentTooLarge = readerError else {
                XCTFail("expected bounded transform failure, got \(error)")
                return
            }
        }
    }

    func testReaderSignInAuthenticationGenerationInvalidatesHeldClient() throws {
        let sourceID = ReaderExtensionSourceID(rawValue: "reader:owned-sign-in-generation")
        let namespace = UUID().uuidString
        let client = ReaderExtensionSecureHTTPClient(
            keychainNamespace: namespace,
            authenticationSourceID: sourceID
        )
        XCTAssertNoThrow(try client.validateAuthenticationAdmission(for: sourceID))
        ReaderExtensionAuthenticationGenerationRegistry.revokeNamespace(namespace)
        XCTAssertThrowsError(try client.validateAuthenticationAdmission(for: sourceID))
    }

    func testRetainedReaderSettingsChildFailsClosedAfterKidsProfileSwitch() {
        XCTAssertNoThrow(try ReaderExtensionAdministrativeAdmissionPolicy.validate(
            isKidsModeActive: false
        ))
        XCTAssertThrowsError(try ReaderExtensionAdministrativeAdmissionPolicy.validate(
            isKidsModeActive: true
        ))
    }

    func testSemanticVersionPrecedenceRejectsEqualAndOrdersPrereleases() {
        XCTAssertEqual(ReaderExtensionVersion.compare("1.2.3", "1.2.3"), .orderedSame)
        XCTAssertEqual(ReaderExtensionVersion.compare("1.2.3", "1.2.3-rc.1"), .orderedDescending)
        XCTAssertEqual(ReaderExtensionVersion.compare("1.2.3-rc.1", "1.2.3"), .orderedAscending)
        XCTAssertEqual(ReaderExtensionVersion.compare("1.0.0-alpha.2", "1.0.0-alpha.10"), .orderedAscending)
        XCTAssertEqual(
            ReaderExtensionVersion.compare("1.0.0-alpha.184467440737095516160", "1.0.0-alpha.184467440737095516161"),
            .orderedAscending
        )
        XCTAssertEqual(ReaderExtensionVersion.compare("1.0.0+owned.2", "1.0.0+owned.1"), .orderedSame)
        XCTAssertTrue(ReaderExtensionVersion.isStrictlyNewer("1.2.3", than: "1.2.3-rc.1"))
        XCTAssertFalse(ReaderExtensionVersion.isStrictlyNewer("1.2.3-rc.1", than: "1.2.3"))
        XCTAssertFalse(ReaderExtensionVersion.isStrictlyNewer("1.2.3+new-bytes", than: "1.2.3+old-bytes"))
        XCTAssertNil(ReaderExtensionVersion.compare("release-2", "1.0.0"))
        XCTAssertNil(ReaderExtensionVersion.compare("1.0", "1.0.0"))
    }

    func testReaderAdministrativeMutationsFailClosedInKidsMode() {
        XCTAssertNoThrow(try ReaderExtensionAdministrativeAdmissionPolicy.validate(isKidsModeActive: false))
        XCTAssertThrowsError(try ReaderExtensionAdministrativeAdmissionPolicy.validate(isKidsModeActive: true)) {
            XCTAssertEqual($0 as? ReaderExtensionError, .unsupportedSource)
        }
    }

    func testIdentityIncludesRepositoryLanguageAndMediaType() {
        let repository = URL(string: "https://93.184.216.34/index.json")!
        let manga = ReaderExtensionSourceID(repositoryURL: repository, upstreamID: "one", language: "EN", mediaType: .manga)
        XCTAssertEqual(manga, ReaderExtensionSourceID(repositoryURL: repository, upstreamID: "one", language: "en", mediaType: .manga))
        XCTAssertNotEqual(manga, ReaderExtensionSourceID(repositoryURL: repository, upstreamID: "one", language: "en", mediaType: .novel))
        XCTAssertTrue(manga.isValid)

        let rooted = URL(string: "https://BÜCHER.example./index.json")!
        let canonical = URL(string: "https://xn--bcher-kva.example/index.json")!
        XCTAssertEqual(
            ReaderExtensionURLCanonicalizer.canonicalString(rooted),
            ReaderExtensionURLCanonicalizer.canonicalString(canonical)
        )
        XCTAssertEqual(
            ReaderExtensionRepositoryRecord(indexURL: rooted).id,
            ReaderExtensionRepositoryRecord(indexURL: canonical).id
        )
        XCTAssertEqual(
            ReaderExtensionSourceID(
                repositoryURL: rooted,
                upstreamID: "one",
                language: "en",
                mediaType: .manga
            ),
            ReaderExtensionSourceID(
                repositoryURL: canonical,
                upstreamID: "one",
                language: "en",
                mediaType: .manga
            )
        )
    }

    func testLanguagePriorityKeepsPreferredThenEnglishAheadOfArabic() {
        let preferredLanguages = ["fr-CA"]
        let preferred = ReaderExtensionLanguageInfo.priority(
            "fr-FR",
            preferredLanguages: preferredLanguages
        )
        let english = ReaderExtensionLanguageInfo.priority(
            "en",
            preferredLanguages: preferredLanguages
        )
        let arabic = ReaderExtensionLanguageInfo.priority(
            "ar",
            preferredLanguages: preferredLanguages
        )

        XCTAssertLessThan(preferred, english)
        XCTAssertLessThan(english, arabic)
        XCTAssertLessThan(
            ReaderExtensionLanguageInfo.priority("en-GB", preferredLanguages: ["en-US"]),
            ReaderExtensionLanguageInfo.priority("ar", preferredLanguages: ["en-US"])
        )
    }

    func testLegacyMangaDexArabicCompatibilityUsesEnglishAtRuntimeWithoutChangingDurableIdentity() throws {
        let durable = try mangaDexArabicSource(languageSelectionVersion: nil)

        let identity = ReaderExtensionLanguageCompatibilityPolicy.runtimeIdentity(
            for: durable,
            preferredLanguages: ["en-US"]
        )

        XCTAssertTrue(identity.isCompatibilityRepair)
        XCTAssertEqual(identity.language, "en")
        XCTAssertEqual(identity.upstreamID, "810342358")
        XCTAssertEqual(
            durable.id.rawValue,
            "842777284c7656c54922835625169381aeaa2ea532bd1d5fb7ece85750c163cf"
        )
        XCTAssertEqual(
            durable.codeProvenanceFingerprint,
            "4eae8a59504b92be41f616502c367d04d5f6616e008071365940009ecbad4924"
        )
        XCTAssertEqual(durable.language, "ar", "the persisted value must remain unchanged")
        XCTAssertEqual(durable.upstreamID, "202373705")
    }

    func testLegacyMangaDexRuntimeIdentityOnlyChangesJavaScriptPrelude() async throws {
        let durable = try mangaDexArabicSource(languageSelectionVersion: nil)
        let identity = ReaderExtensionLanguageCompatibilityPolicy.runtimeIdentity(
            for: durable,
            preferredLanguages: ["en-US"]
        )
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) {
            return {
              list: [{name: this.source.id + '|' + this.source.lang, url: '/manga/owned'}],
              hasNextPage: false
            };
          }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: 'Owned', chapters: []}; }
          async getPageList(url) { return []; }
        }
        """.utf8)
        let provider = try JavaScriptReaderProvider(
            source: durable,
            scriptData: script,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            consentScopeID: "legacy-language-prelude",
            preferenceStore: ReaderExtensionInMemoryPreferenceStore(),
            runtimeIdentity: identity
        )

        XCTAssertEqual(provider.source.id, durable.id)
        XCTAssertEqual(provider.source.upstreamID, "202373705")
        XCTAssertEqual(provider.source.language, "ar")
        let popular = try await provider.popular(page: 1)
        XCTAssertEqual(popular.items.first?.title, "810342358|en")
    }

    func testLegacyMangaDexArabicCompatibilityHonorsArabicDevicePreference() throws {
        let durable = try mangaDexArabicSource(languageSelectionVersion: nil)

        let identity = ReaderExtensionLanguageCompatibilityPolicy.runtimeIdentity(
            for: durable,
            preferredLanguages: ["ar-SA", "en-US"]
        )
        XCTAssertFalse(identity.isCompatibilityRepair)
        XCTAssertEqual(identity.language, "ar")
        XCTAssertEqual(identity.upstreamID, "202373705")
    }

    func testExplicitMangaDexArabicLanguageSelectionIsNeverCompatibilityRepaired() throws {
        let explicit = try mangaDexArabicSource(
            languageSelectionVersion: ReaderExtensionLanguageCompatibilityPolicy
                .explicitSelectionVersion
        )

        let identity = ReaderExtensionLanguageCompatibilityPolicy.runtimeIdentity(
            for: explicit,
            preferredLanguages: ["en-US"]
        )
        XCTAssertFalse(identity.isCompatibilityRepair)
        XCTAssertEqual(identity.language, "ar")
        XCTAssertEqual(identity.upstreamID, "202373705")
    }

    func testMangaDexArabicCompatibilityRejectsNearMatchesAndDifferentScripts() throws {
        var wrongProvenance = try mangaDexArabicSource(languageSelectionVersion: nil)
        wrongProvenance.codeProvenanceFingerprint = String(repeating: "b", count: 64)
        let fixtures = [
            try mangaDexArabicSource(
                languageSelectionVersion: nil,
                upstreamID: "202373706"
            ),
            try mangaDexArabicSource(
                languageSelectionVersion: nil,
                name: "MangaDex Mirror"
            ),
            try mangaDexArabicSource(
                languageSelectionVersion: nil,
                scriptURL: "https://raw.githubusercontent.com/m2k3a/mangayomi-extensions/main/javascript/manga/src/all/mangadex-copy.js"
            ),
            try mangaDexArabicSource(
                languageSelectionVersion: nil,
                repositoryURL: "https://mirror.example/mangayomi-extensions/index.json"
            ),
            wrongProvenance
        ]

        for source in fixtures {
            let identity = ReaderExtensionLanguageCompatibilityPolicy.runtimeIdentity(
                for: source,
                preferredLanguages: ["en-US"]
            )
            XCTAssertFalse(identity.isCompatibilityRepair)
            XCTAssertEqual(identity.language, "ar")
            XCTAssertEqual(identity.upstreamID, source.upstreamID)
        }
    }

    func testLanguageSelectionMarkerCodableDistinguishesLegacyFromExplicitInstall() throws {
        let explicit = try mangaDexArabicSource(
            languageSelectionVersion: ReaderExtensionLanguageCompatibilityPolicy
                .explicitSelectionVersion
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let explicitData = try encoder.encode(explicit)
        let explicitObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: explicitData) as? [String: Any]
        )
        XCTAssertEqual(
            explicitObject["languageSelectionVersion"] as? Int,
            ReaderExtensionLanguageCompatibilityPolicy.explicitSelectionVersion
        )
        XCTAssertEqual(
            try decoder.decode(ReaderExtensionInstalledSource.self, from: explicitData)
                .languageSelectionVersion,
            ReaderExtensionLanguageCompatibilityPolicy.explicitSelectionVersion
        )

        var legacyObject = explicitObject
        legacyObject.removeValue(forKey: "languageSelectionVersion")
        let legacyData = try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.sortedKeys]
        )
        let decodedLegacy = try decoder.decode(
            ReaderExtensionInstalledSource.self,
            from: legacyData
        )
        XCTAssertNil(decodedLegacy.languageSelectionVersion)
    }

    @MainActor
    func testPassiveHTTPSAssetAdmissionRetainsMangaDexCDNWithoutConsent() async throws {
        let coordinator = ReaderExtensionDomainConsentCoordinator.shared
        coordinator.resetForScopeChange()
        defer { coordinator.resetForScopeChange() }

        let sourceID = ReaderExtensionSourceID(rawValue: String(repeating: "a", count: 64))
        let cover = try XCTUnwrap(URL(
            string: "https://uploads.mangadex.org/covers/owned-title/owned-cover.jpg"
        ))
        let admitted = ReaderExtensionSecurityPolicy.validatedAssetURL(
            cover,
            sourceID: sourceID,
            approvedDomains: [],
            consentScopeID: "passive-mangadex-cover"
        )

        XCTAssertEqual(admitted, cover)
        await Task.yield()
        XCTAssertEqual(coordinator.queuedRequestCount, 0)
        XCTAssertNil(coordinator.pendingRequest)
    }

    func testExactNormalizedNameAndLanguageLegacyCandidateRemainsManual() throws {
        let legacy = try JSONDecoder().decode(
            BackupLegacyAidokuSourceMetadata.self,
            from: Data("""
            {
              "id":"multi.mangadex",
              "name":"MangaDex",
              "version":1,
              "languages":["EN_us"],
              "originHost":"aidoku-community.github.io",
              "contentRatingRawValue":0,
              "isEnabled":true,
              "order":0,
              "lastUpdated":null
            }
            """.utf8)
        )
        var replacement = installedSource(implementation: .madara)
        replacement.upstreamID = "810342358"
        replacement.name = "  mangadex  "
        replacement.language = "en-US"
        replacement.baseURL = try XCTUnwrap(URL(string: "https://mangadex.org"))
        replacement.apiURL = try XCTUnwrap(URL(string: "https://api.mangadex.org"))
        replacement.id = ReaderExtensionSourceID(
            repositoryURL: replacement.repositoryURL,
            upstreamID: replacement.upstreamID,
            language: replacement.language,
            mediaType: replacement.mediaType
        )

        let candidate = try XCTUnwrap(
            ReaderExtensionLegacyReconnectManager.candidates(
                legacySources: [legacy],
                installedSources: [replacement]
            ).first
        )
        XCTAssertTrue(candidate.matchesSourceName)
        XCTAssertTrue(candidate.matchesLanguage)
        XCTAssertFalse(candidate.matchesUpstreamSourceID)
        XCTAssertFalse(candidate.matchesOriginHost)
        XCTAssertFalse(candidate.isStrongUniqueMatchCandidate)
        XCTAssertTrue(
            ReaderExtensionLegacyReconnectManager.uniqueStrongCandidates(
                legacySources: [legacy],
                installedSources: [replacement]
            ).isEmpty
        )
    }

    func testCatalogRejectsConflictingDuplicateIdentityAndIgnoresVideoRows() throws {
        let index = URL(string: "https://93.184.216.34/index.json")!
        let repository = ReaderExtensionRepositoryRecord(indexURL: index)
        let videoOnly = Data("""
        {"sources":[{"name":"Video","id":"v","baseUrl":"https://93.184.216.34","lang":"en","itemType":1,"sourceCodeLanguage":0,"typeSource":"Madara"}]}
        """.utf8)
        XCTAssertTrue(try ReaderExtensionRepositoryCatalog.decode(data: videoOnly, indexURL: index, repository: repository).sources.isEmpty)

        let conflict = Data("""
        {"sources":[
          {"name":"One","id":"same","baseUrl":"https://93.184.216.34","lang":"en","sourceCodeLanguage":0,"typeSource":"Madara"},
          {"name":"Two","id":"same","baseUrl":"https://93.184.216.34","lang":"en","sourceCodeLanguage":0,"typeSource":"Madara"}
        ]}
        """.utf8)
        XCTAssertThrowsError(try ReaderExtensionRepositoryCatalog.decode(data: conflict, indexURL: index, repository: repository))

        var licensedRepository = repository
        licensedRepository.license = ReaderExtensionLicense(
            kind: .apache2,
            name: "Apache License 2.0",
            url: nil,
            textSHA256: nil,
            detectedAt: Date()
        )
        let independentlyHostedScript = Data("""
        {"sources":[{"name":"Script","id":"js","baseUrl":"https://93.184.216.34","lang":"en","sourceCodeLanguage":1,"sourceCodeUrl":"https://93.184.216.34/source.js","typeSource":"single"}]}
        """.utf8)
        let decoded = try ReaderExtensionRepositoryCatalog.decode(
            data: independentlyHostedScript,
            indexURL: index,
            repository: licensedRepository
        )
        XCTAssertEqual(decoded.sources.first?.license.kind, .unknown, "a catalog license must not be assigned to linked JavaScript")
    }

    func testCatalogSkipsInvalidMangayomiRowsWithoutRejectingValidSiblings() throws {
        let index = URL(string: "https://93.184.216.34/index.json")!
        let repository = ReaderExtensionRepositoryRecord(indexURL: index)
        let mixedCatalog = Data("""
        {"sources":[
          {"name":"Broken Script","id":"broken","baseUrl":"https://reader.example","lang":"en","sourceCodeLanguage":1,"sourceCodeUrl":"https://raw.githubusercontent.com/example/extensions/main/javascript/","typeSource":"single"},
          {"name":"Private Base","id":"private","baseUrl":"http://127.0.0.1","lang":"en","sourceCodeLanguage":0,"typeSource":"Madara"},
          {"name":"Working","id":"working","baseUrl":"https://reader.example","lang":"en","sourceCodeLanguage":0,"typeSource":"Madara"}
        ]}
        """.utf8)

        let decoded = try ReaderExtensionRepositoryCatalog.decode(
            data: mixedCatalog,
            indexURL: index,
            repository: repository
        )
        XCTAssertEqual(decoded.sources.map(\.name), ["Working"])
    }

    func testCatalogIconURLIsValidatedAndSurvivesInstalledSourcePersistence() throws {
        let index = URL(string: "https://93.184.216.34/index.json")!
        var repository = ReaderExtensionRepositoryRecord(indexURL: index)
        repository.license = ReaderExtensionLicense(
            kind: .mit,
            name: "MIT License",
            url: nil,
            textSHA256: nil,
            detectedAt: Date()
        )
        let catalog = try ReaderExtensionRepositoryCatalog.decode(
            data: Data("""
            {"sources":[
              {"name":"MangaDex","id":"valid-icon","baseUrl":"https://mangadex.org","lang":"en","sourceCodeLanguage":0,"typeSource":"Madara","iconUrl":"https://uploads.mangadex.org/covers/owned/icon.jpg"},
              {"name":"Insecure Icon","id":"invalid-icon","baseUrl":"https://reader.example","lang":"en","sourceCodeLanguage":0,"typeSource":"Madara","iconUrl":"http://images.example/icon.jpg"}
            ]}
            """.utf8),
            indexURL: index,
            repository: repository
        )

        let decoded = try XCTUnwrap(catalog.sources.first)
        XCTAssertEqual(catalog.sources.map(\.name), ["MangaDex"])
        XCTAssertEqual(
            decoded.iconURL,
            URL(string: "https://uploads.mangadex.org/covers/owned/icon.jpg")
        )

        let suite = "ReaderExtensionIconPersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let installed = ReaderExtensionInstalledSource(catalog: decoded, sortIndex: 0)
        try ReaderExtensionPersistence.persist(
            repositories: [repository],
            installedSources: [installed],
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: defaults
        )
        XCTAssertEqual(
            try ReaderExtensionPersistence.loadInstalledSources(from: defaults).first?.iconURL,
            decoded.iconURL
        )
    }

    func testMangayomiCacheBustingIconInstallPersistsAndFailureCleanupRetainsConcurrentContent() throws {
        let repositoryURL = try XCTUnwrap(URL(
            string: "https://m2k3a.github.io/mangayomi-extensions/index.json"
        ))
        let repository = ReaderExtensionRepositoryRecord(indexURL: repositoryURL)
        let catalog = try ReaderExtensionRepositoryCatalog.decode(
            data: Data("""
            [{
              "name":"Mangafire",
              "id":463934370,
              "baseUrl":"https://mangafire.to",
              "apiUrl":"",
              "lang":"en",
              "typeSource":"single",
              "dateFormat":"",
              "dateFormatLocale":"",
              "isNsfw":false,
              "hasCloudflare":false,
              "sourceCodeUrl":"https://raw.githubusercontent.com/m2k3a/mangayomi-extensions/main/javascript/manga/src/all/mangafire.js",
              "iconUrl":"https://mangafire.to/assets/sites/mangafire/favicon.png?v3",
              "version":"0.2.20",
              "isManga":true,
              "itemType":0,
              "additionalParams":"",
              "sourceCodeLanguage":1
            }]
            """.utf8),
            indexURL: repositoryURL,
            repository: repository
        )
        let source = try XCTUnwrap(catalog.sources.first)
        XCTAssertEqual(catalog.sources.count, 1)
        XCTAssertEqual(source.name, "Mangafire")
        XCTAssertEqual(
            source.iconURL,
            URL(string: "https://mangafire.to/assets/sites/mangafire/favicon.png?v3"),
            "a benign icon query is resource identity (favicon services 404 without it) and must persist"
        )
        XCTAssertEqual(
            ReaderExtensionSecurityPolicy.sanitizedIconURL(
                try XCTUnwrap(URL(string: "https://icons.example/lookup?domain=reader.example&sz=128&token=leaked"))
            ),
            URL(string: "https://icons.example/lookup?domain=reader.example&sz=128"),
            "credential-bearing icon query parameters must not become durable authorization material"
        )

        let suite = "ReaderExtensionMangafirePersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let contentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderExtensionMangafirePersistence.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: contentRoot) }
        let contentStore = try ReaderExtensionContentStore(rootURL: contentRoot)
        let failedScript = Data("class DefaultExtension extends MProvider { getPopular() { return []; } }".utf8)
        let concurrentScript = Data("class DefaultExtension extends MProvider { search() { return []; } }".utf8)
        let failedDigest = try contentStore.activate(contentStore.stageExactScript(failedScript))
        let concurrentDigest = try contentStore.activate(contentStore.stageExactScript(concurrentScript))

        let baseline = installedSource(implementation: .madara)
        try ReaderExtensionPersistence.persist(
            repositories: [repository],
            installedSources: [baseline],
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: defaults
        )
        let durableSourcesBeforeFailure = defaults.data(
            forKey: ReaderExtensionPersistence.installedSourcesKey
        )

        var previouslyRejected = ReaderExtensionInstalledSource(catalog: source, sortIndex: 1)
        previouslyRejected.activeContentDigest = failedDigest
        // Catalog decoding strips credential-like icon parameters, so a
        // persisted record still carrying one can only be forged or stale;
        // persistence must reject the whole source rather than store it.
        previouslyRejected.iconURL = try XCTUnwrap(URL(
            string: "https://mangafire.to/assets/sites/mangafire/favicon.png?token=leaked"
        ))
        var liveSources = [baseline]
        var didRunPostCommitCleanup = false
        XCTAssertThrowsError(try ReaderExtensionDurableMutation.commit(
            candidate: [baseline, previouslyRejected],
            persist: { candidate in
                try ReaderExtensionPersistence.persist(
                    repositories: [repository],
                    installedSources: candidate,
                    showMature: false,
                    autoUpdate: true,
                    lastAutoUpdate: nil,
                    to: defaults
                )
            },
            publish: { liveSources = $0 },
            afterCommit: { didRunPostCommitCleanup = true }
        ))
        XCTAssertEqual(liveSources, [baseline], "a rejected install must not become live")
        XCTAssertFalse(didRunPostCommitCleanup)
        XCTAssertEqual(
            defaults.data(forKey: ReaderExtensionPersistence.installedSourcesKey),
            durableSourcesBeforeFailure,
            "the prior durable source bytes must survive a rejected install transaction"
        )
        let durableAfterFailure = try ReaderExtensionPersistence.loadInstalledSources(from: defaults)
        XCTAssertEqual(durableAfterFailure.map(\.id), [baseline.id])
        XCTAssertFalse(durableAfterFailure.contains(where: { $0.id == previouslyRejected.id }))

        var pending = ReaderExtensionPendingInstallContent()
        pending.register(digest: failedDigest, sourceID: previouslyRejected.id)
        let concurrentID = ReaderExtensionSourceID(rawValue: String(repeating: "c", count: 64))
        pending.register(digest: concurrentDigest, sourceID: concurrentID)
        pending.release(sourceID: previouslyRejected.id)
        contentStore.removeUnreferencedContent(keeping: pending.retainedDigests)
        XCTAssertThrowsError(try contentStore.scriptData(digest: failedDigest), "the rejected install must not leave executable bytes orphaned")
        XCTAssertEqual(
            try contentStore.scriptData(digest: concurrentDigest),
            concurrentScript,
            "cleanup for one failed install must retain another install awaiting its metadata commit"
        )

        let validDigest = try contentStore.activate(contentStore.stageExactScript(failedScript))
        var installed = ReaderExtensionInstalledSource(catalog: source, sortIndex: 1)
        installed.activeContentDigest = validDigest
        try ReaderExtensionPersistence.persist(
            repositories: [repository],
            installedSources: [baseline, installed],
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: defaults
        )
        let persisted = try ReaderExtensionPersistence.loadInstalledSources(from: defaults)
        XCTAssertEqual(persisted.map(\.id), [baseline.id, installed.id])
        XCTAssertEqual(persisted.last?.iconURL, source.iconURL)
    }

    func testRepositoryRedirectPolicyIsExplicitAndFinalURLOwnsCatalogIdentity() throws {
        let requested = URL(string: "https://repo.example/index.json")!
        let resolved = URL(string: "https://cdn.example/catalog/index.json")!
        let repository = ReaderExtensionRepositoryRecord(indexURL: requested)
        let request = ReaderExtensionNetworkRequest(
            url: requested,
            sourceID: ReaderExtensionSourceID(rawValue: repository.id),
            approvedDomains: ["repo.example"],
            allowsCookies: false,
            redirectPolicy: .publicHTTPS
        )
        XCTAssertEqual(request.redirectPolicy, .publicHTTPS)
        XCTAssertFalse(request.allowsCookies)

        let catalog = try ReaderExtensionRepositoryCatalog.decode(
            data: Data("""
            {"sources":[{"name":"Redirected","id":"redirected","baseUrl":"https://reader.example","lang":"en","sourceCodeLanguage":0,"typeSource":"Madara"}]}
            """.utf8),
            indexURL: resolved,
            repository: repository
        )
        let source = try XCTUnwrap(catalog.sources.first)
        XCTAssertEqual(source.repositoryURL, resolved)
        XCTAssertEqual(
            source.id,
            ReaderExtensionSourceID(
                repositoryURL: resolved,
                upstreamID: "redirected",
                language: "en",
                mediaType: .manga
            )
        )
    }

    func testCatalogAndPersistenceRejectCapPlusOneWithoutTruncating() throws {
        let index = publicBaseURL.appendingPathComponent("index.json")
        let repository = ReaderExtensionRepositoryRecord(indexURL: index)
        let minimalRows = (0...ReaderExtensionPersistence.maximumInstalledSourceCount).map { index in
            "{\"name\":\"Owned\",\"id\":\"minimal-\(index)\",\"baseUrl\":\"https://93.184.216.34\",\"sourceCodeLanguage\":0,\"typeSource\":\"Madara\"}"
        }.joined(separator: ",")
        let directCapPlusOne = Data("[\(minimalRows)]".utf8)
        XCTAssertLessThan(directCapPlusOne.count, ReaderExtensionSecurityPolicy.maximumRepositoryBytes)
        XCTAssertThrowsError(try ReaderExtensionRepositoryCatalog.decode(
            data: directCapPlusOne,
            indexURL: index,
            repository: repository
        )) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }

        let denseRows = (0...ReaderExtensionPersistence.maximumInstalledSourceCount).map { index in
            """
            {"name":"Owned \(index)","id":"dense-\(index)","baseUrl":"https://93.184.216.34","lang":"en","typeSource":"Madara","dateFormat":"yyyy-MM-dd","dateFormatLocale":"en_US_POSIX","isNsfw":false,"hasCloudflare":false,"apiUrl":"https://93.184.216.34/api","version":"1.0.0","isManga":true,"itemType":0,"additionalParams":"owned","sourceCodeLanguage":0,"notes":"owned fixture"}
            """
        }.joined(separator: ",")
        let envelopeCapPlusOne = Data("{\"name\":\"Owned Repo\",\"sources\":[\(denseRows)]}".utf8)
        XCTAssertLessThan(envelopeCapPlusOne.count, ReaderExtensionSecurityPolicy.maximumRepositoryBytes)
        XCTAssertThrowsError(try ReaderExtensionRepositoryCatalog.decode(
            data: envelopeCapPlusOne,
            indexURL: index,
            repository: repository
        )) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }

        let oversizedEnvelope = Data("""
        {"name":"\(String(repeating: "n", count: 513))","sources":[]}
        """.utf8)
        XCTAssertThrowsError(try ReaderExtensionRepositoryCatalog.decode(
            data: oversizedEnvelope,
            indexURL: index,
            repository: repository
        ))
        let oversizedURL = Data("""
        {"sources":[{"name":"Owned","id":"one","baseUrl":"https://93.184.216.34/\(String(repeating: "p", count: 16 * 1_024))","lang":"en","sourceCodeLanguage":0,"typeSource":"Madara"}]}
        """.utf8)
        XCTAssertThrowsError(try ReaderExtensionRepositoryCatalog.decode(
            data: oversizedURL,
            indexURL: index,
            repository: repository
        ))

        let suite = "ReaderExtensionCapacity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tooManyRepositories = Array(
            repeating: repository,
            count: ReaderExtensionPersistence.maximumRepositoryCount + 1
        )
        XCTAssertThrowsError(try ReaderExtensionPersistence.persist(
            repositories: tooManyRepositories,
            installedSources: [],
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: defaults
        ))
        XCTAssertNil(defaults.data(forKey: ReaderExtensionPersistence.repositoriesKey))

        let source = installedSource(implementation: .madara)
        let tooManySources = Array(
            repeating: source,
            count: ReaderExtensionPersistence.maximumInstalledSourceCount + 1
        )
        XCTAssertThrowsError(try ReaderExtensionPersistence.persist(
            repositories: [],
            installedSources: tooManySources,
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: defaults
        ))
        XCTAssertNil(defaults.data(forKey: ReaderExtensionPersistence.installedSourcesKey))
    }

    func testReaderLocalServiceStoreJSONPreflightRejectsCapPlusOneAndDensePayloads() throws {
        let suite = "ReaderExtensionLocalJSONPreflight.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let repositoryCapPlusOne = Data((
            "[" + Array(
                repeating: "null",
                count: ReaderExtensionPersistence.maximumRepositoryCount + 1
            ).joined(separator: ",") + "]"
        ).utf8)
        defaults.set(repositoryCapPlusOne, forKey: ReaderExtensionPersistence.repositoriesKey)
        XCTAssertThrowsError(try ReaderExtensionPersistence.loadRepositories(from: defaults)) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }

        let sourceCapPlusOne = Data((
            "[" + Array(
                repeating: "null",
                count: ReaderExtensionPersistence.maximumInstalledSourceCount + 1
            ).joined(separator: ",") + "]"
        ).utf8)
        defaults.set(sourceCapPlusOne, forKey: ReaderExtensionPersistence.installedSourcesKey)
        XCTAssertThrowsError(try ReaderExtensionPersistence.loadInstalledSources(from: defaults)) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }

        let denseRepository = Data((
            "[{\"dense\":{" + (0..<129).map { "\"k\($0)\":0" }.joined(separator: ",") + "}}]"
        ).utf8)
        defaults.set(denseRepository, forKey: ReaderExtensionPersistence.repositoriesKey)
        XCTAssertThrowsError(try ReaderExtensionPersistence.loadRepositories(from: defaults)) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }

        let denseSource = Data((
            "[{\"dense\":[" + Array(repeating: "0", count: 257).joined(separator: ",") + "]}]"
        ).utf8)
        defaults.set(denseSource, forKey: ReaderExtensionPersistence.installedSourcesKey)
        XCTAssertThrowsError(try ReaderExtensionPersistence.loadInstalledSources(from: defaults)) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }
    }

    func testLicenseDetectionPrioritizesRestrictionsAndUsesOnlySourceHeader() {
        XCTAssertEqual(
            ReaderExtensionLicenseDetector.kind(nameOrText: "MIT License\nAll rights reserved; no redistribution"),
            .restrictive
        )
        XCTAssertEqual(ReaderExtensionLicenseDetector.kind(nameOrText: "unlicensed source"), .unknown)
        XCTAssertEqual(
            ReaderExtensionLicenseDetector.sourceHeader(in: "// SPDX-License-Identifier: MIT\nclass DefaultExtension {}"),
            "// SPDX-License-Identifier: MIT"
        )
        XCTAssertTrue(ReaderExtensionLicenseDetector.sourceHeader(in: "class DefaultExtension {}\n// MIT License").isEmpty)
    }

    func testLicenseDetectionRequiresExactSPDXOrCanonicalBodyAndBindsUnknownText() throws {
        XCTAssertEqual(ReaderExtensionLicenseDetector.kind(nameOrText: "MIT"), .mit)
        XCTAssertEqual(
            ReaderExtensionLicenseDetector.kind(nameOrText: "// SPDX-License-Identifier: Apache-2.0"),
            .apache2
        )
        XCTAssertEqual(ReaderExtensionLicenseDetector.kind(nameOrText: "MIT License"), .unknown)
        XCTAssertEqual(
            ReaderExtensionLicenseDetector.kind(
                nameOrText: "MIT License; non-commercial/no derivatives only"
            ),
            .restrictive
        )
        XCTAssertEqual(
            ReaderExtensionLicenseDetector.kind(
                nameOrText: "// SPDX-License-Identifier: MIT\n// Additional advertising approval required"
            ),
            .unknown,
            "an SPDX token must not hide additional terms"
        )

        let canonicalMIT = """
        MIT License

        Copyright (c) 2026 Owned Fixture

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is furnished
        to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.
        """
        XCTAssertEqual(ReaderExtensionLicenseDetector.kind(nameOrText: canonicalMIT), .mit)
        XCTAssertEqual(
            ReaderExtensionLicenseDetector.kind(nameOrText: canonicalMIT + "\nNon-commercial use only."),
            .restrictive
        )

        let licenseURL = try XCTUnwrap(URL(string: "https://93.184.216.34/LICENSE"))
        let unknownA = try XCTUnwrap(ReaderExtensionLicenseDetector.fetchedLicense(
            data: Data("Custom terms version A".utf8),
            finalURL: licenseURL
        ))
        let unknownB = try XCTUnwrap(ReaderExtensionLicenseDetector.fetchedLicense(
            data: Data("Custom terms version B".utf8),
            finalURL: licenseURL
        ))
        XCTAssertEqual(unknownA.kind, .unknown)
        XCTAssertEqual(unknownB.kind, .unknown)
        XCTAssertNotEqual(
            unknownA.provenanceFingerprint,
            unknownB.provenanceFingerprint,
            "changed ambiguous license text must require renewed consent"
        )
    }

    func testSourceHeaderLicenseProvenancePreservesGPLVariantAndCopyrightOwner() throws {
        let gplOnly = """
        // SPDX-License-Identifier: GPL-3.0-only
        // Copyright 2026 Owned Author
        """
        let gplLater = """
        // SPDX-License-Identifier: GPL-3.0-or-later
        // Copyright 2026 Owned Author
        """
        let mitOwnerA = """
        // SPDX-License-Identifier: MIT
        // Copyright 2026 Owner A
        """
        let mitOwnerB = """
        // SPDX-License-Identifier: MIT
        // Copyright 2026 Owner B
        """

        let gplOnlyDeclaration = ReaderExtensionLicenseDetector.declaration(
            in: gplOnly,
            kind: .gpl3
        )
        let gplLaterDeclaration = ReaderExtensionLicenseDetector.declaration(
            in: gplLater,
            kind: .gpl3
        )
        XCTAssertNotEqual(gplOnlyDeclaration, gplLaterDeclaration)
        XCTAssertEqual(
            ReaderExtensionLicenseDetector.displayName(
                .gpl3,
                recognizedDeclaration: gplOnlyDeclaration
            ),
            "GNU GPL v3 only"
        )
        XCTAssertEqual(
            ReaderExtensionLicenseDetector.displayName(
                .gpl3,
                recognizedDeclaration: gplLaterDeclaration
            ),
            "GNU GPL v3 or later"
        )

        func license(_ header: String, kind: ReaderExtensionLicenseKind) -> ReaderExtensionLicense {
            let declaration = ReaderExtensionLicenseDetector.declaration(in: header, kind: kind)
            return ReaderExtensionLicense(
                kind: kind,
                name: ReaderExtensionLicenseDetector.displayName(
                    kind,
                    recognizedDeclaration: declaration
                ),
                url: URL(string: "https://93.184.216.34/source.js"),
                textSHA256: SHA256.hash(data: Data(declaration.utf8))
                    .map { String(format: "%02x", $0) }.joined(),
                detectedAt: Date(timeIntervalSince1970: 1)
            )
        }

        let onlyLicense = license(gplOnly, kind: .gpl3)
        let laterLicense = license(gplLater, kind: .gpl3)
        XCTAssertNotEqual(onlyLicense.provenanceFingerprint, laterLicense.provenanceFingerprint)
        XCTAssertThrowsError(try ReaderExtensionLicenseUpdatePolicy.validateTransition(
            from: onlyLicense,
            to: laterLicense,
            allowScopeExpansion: false
        ))

        let ownerA = license(mitOwnerA, kind: .mit)
        let ownerB = license(mitOwnerB, kind: .mit)
        XCTAssertNotEqual(ownerA.provenanceFingerprint, ownerB.provenanceFingerprint)
        XCTAssertThrowsError(try ReaderExtensionLicenseUpdatePolicy.validateTransition(
            from: ownerA,
            to: ownerB,
            allowScopeExpansion: false
        ))
    }

    func testExecutableFetchRejectsRedirectedOwnerOrPath() throws {
        let requested = try XCTUnwrap(URL(string: "https://93.184.216.34/source.js"))
        XCTAssertEqual(
            try ReaderExtensionExecutableFetchPolicy.validatedFinalURL(
                requested: requested,
                response: URL(string: "https://93.184.216.34:443/source.js")!
            ),
            URL(string: "https://93.184.216.34:443/source.js")!
        )
        XCTAssertThrowsError(try ReaderExtensionExecutableFetchPolicy.validatedFinalURL(
            requested: requested,
            response: URL(string: "https://93.184.216.34/other.js")!
        ))
        XCTAssertThrowsError(try ReaderExtensionExecutableFetchPolicy.validatedFinalURL(
            requested: requested,
            response: URL(string: "https://93.184.216.35/source.js")!
        ))
    }

    func testCatalogRevalidationStillRequiresConsentForChangedLicenseProvenance() throws {
        let previous = ReaderExtensionLicense(
            kind: .mit,
            name: "MIT",
            url: URL(string: "https://93.184.216.34/LICENSE-MIT"),
            textSHA256: String(repeating: "a", count: 64),
            detectedAt: .distantPast
        )
        let incoming = ReaderExtensionLicense(
            kind: .mpl2,
            name: "MPL-2.0",
            url: URL(string: "https://93.184.216.34/LICENSE-MPL"),
            textSHA256: String(repeating: "b", count: 64),
            detectedAt: Date()
        )

        XCTAssertThrowsError(try ReaderExtensionLicenseUpdatePolicy.validateTransition(
            from: previous,
            to: incoming,
            allowScopeExpansion: false
        )) { error in
            guard case ReaderExtensionError.updateConsentRequired(let reason) = error else {
                XCTFail("expected license consent requirement, got \(error)")
                return
            }
            XCTAssertEqual(reason, "the source license")
        }
        XCTAssertNoThrow(try ReaderExtensionLicenseUpdatePolicy.validateTransition(
            from: previous,
            to: incoming,
            allowScopeExpansion: true
        ))
        XCTAssertNoThrow(try ReaderExtensionLicenseUpdatePolicy.validateTransition(
            from: previous,
            to: previous,
            allowScopeExpansion: false
        ))
    }

    func testUnknownLicenseUpdateRoutesToExplicitOverrideDisclosure() {
        XCTAssertEqual(
            ReaderExtensionSourceUpdateConsentPolicy.reason(for: .unknownLicenseNeedsConsent),
            ReaderExtensionSourceUpdateConsentPolicy.unknownLicenseReason
        )
        XCTAssertTrue(
            ReaderExtensionSourceUpdateConsentPolicy.unknownLicenseReason
                .localizedCaseInsensitiveContains("license")
        )
        XCTAssertEqual(
            ReaderExtensionSourceUpdateConsentPolicy.reason(
                for: .updateConsentRequired("the source maturity rating")
            ),
            "the source maturity rating"
        )
        XCTAssertNil(
            ReaderExtensionSourceUpdateConsentPolicy.reason(for: .runtimeUnavailable),
            "ordinary update failures must remain errors rather than becoming destructive consent prompts"
        )
    }

    func testLicenseFetchNeverContactsManifestDeclaredCrossOrigin() throws {
        let repository = try XCTUnwrap(URL(string: "https://93.184.216.34/catalog/index.json"))
        XCTAssertTrue(ReaderExtensionLicenseFetchPolicy.allowsCandidate(
            URL(string: "https://93.184.216.34/catalog/LICENSE")!,
            owner: repository
        ))
        XCTAssertFalse(ReaderExtensionLicenseFetchPolicy.allowsCandidate(
            URL(string: "https://93.184.216.35/LICENSE")!,
            owner: repository
        ), "a manifest licenseURL must not silently grant network consent to another operator")
        XCTAssertFalse(ReaderExtensionLicenseFetchPolicy.allowsCandidate(
            URL(string: "https://93.184.216.34/LICENSE?token=secret")!,
            owner: repository
        ))
        XCTAssertFalse(ReaderExtensionLicenseFetchPolicy.allowsCandidate(
            URL(string: "http://93.184.216.34/LICENSE")!,
            owner: repository
        ))

        let script = try XCTUnwrap(URL(string: "https://93.184.216.34/providers/source.js"))
        XCTAssertTrue(ReaderExtensionLicenseFetchPolicy.allowsCandidate(
            URL(string: "https://93.184.216.34/providers/LICENSE")!,
            owner: script
        ))
        XCTAssertFalse(ReaderExtensionLicenseFetchPolicy.allowsCandidate(
            URL(string: "https://93.184.216.35/LICENSE")!,
            owner: script
        ), "an approved secondary host must not launder a JavaScript source's license after redirect")
    }

    func testDurableMutationDoesNotPublishOrCleanupAfterPersistenceFailure() throws {
        enum InjectedFailure: Error { case unavailable }
        var liveState = ["old"]
        var events: [String] = []
        var didRunIrreversibleCleanup = false

        XCTAssertThrowsError(try ReaderExtensionDurableMutation.commit(
            candidate: ["new"],
            persist: { _ in
                events.append("persist")
                throw InjectedFailure.unavailable
            },
            publish: {
                events.append("publish")
                liveState = $0
            },
            afterCommit: {
                events.append("cleanup")
                didRunIrreversibleCleanup = true
            }
        ))
        XCTAssertEqual(liveState, ["old"], "failed installs must not become runnable in memory")
        XCTAssertEqual(events, ["persist"])
        XCTAssertFalse(didRunIrreversibleCleanup, "failed uninstalls must retain authentication state")

        try ReaderExtensionDurableMutation.commit(
            candidate: ["new"],
            persist: { _ in events.append("persist-success") },
            publish: {
                events.append("publish-success")
                liveState = $0
            },
            afterCommit: {
                events.append("cleanup-success")
                didRunIrreversibleCleanup = true
            }
        )
        XCTAssertEqual(liveState, ["new"])
        XCTAssertTrue(didRunIrreversibleCleanup)
        XCTAssertEqual(Array(events.suffix(3)), ["persist-success", "publish-success", "cleanup-success"])
    }

    func testPreferenceMutationCoordinatesMetadataLiveStateAndKeychainOrdering() throws {
        enum InjectedFailure: Error { case metadata, keychain }

        var ordinaryLiveValue = "old"
        XCTAssertThrowsError(try ReaderExtensionDurableMutation.commit(
            candidate: "new",
            persist: { _ in throw InjectedFailure.metadata },
            publish: { ordinaryLiveValue = $0 }
        ))
        XCTAssertEqual(ordinaryLiveValue, "old", "an unpersisted ordinary preference must not become live")

        var secretLiveMarker = "old-marker"
        var secureValue = "old-secret"
        var didAttemptSecureWrite = false
        var didRollbackMetadata = false
        XCTAssertThrowsError(try ReaderExtensionDurableMutation.commitCoordinated(
            candidate: "new-marker",
            persist: { _ in throw InjectedFailure.metadata },
            applySecondary: {
                didAttemptSecureWrite = true
                secureValue = "new-secret"
            },
            rollbackPersistence: { didRollbackMetadata = true },
            publish: { secretLiveMarker = $0 }
        ))
        XCTAssertFalse(didAttemptSecureWrite, "Keychain must not change before marker persistence succeeds")
        XCTAssertFalse(didRollbackMetadata, "no rollback is needed when the candidate was never persisted")
        XCTAssertEqual(secureValue, "old-secret")
        XCTAssertEqual(secretLiveMarker, "old-marker")

        XCTAssertThrowsError(try ReaderExtensionDurableMutation.commitCoordinated(
            candidate: "new-marker",
            persist: { _ in },
            applySecondary: { throw InjectedFailure.keychain },
            rollbackPersistence: { didRollbackMetadata = true },
            publish: { secretLiveMarker = $0 }
        ))
        XCTAssertTrue(didRollbackMetadata, "a failed Keychain write must restore the prior metadata snapshot")
        XCTAssertEqual(secretLiveMarker, "old-marker")
    }

    func testBlockMutationKeepsSourceAndAuthenticationWhenBlockPersistenceFails() throws {
        enum InjectedFailure: Error { case blockedSet }
        var liveSources = ["installed"]
        var liveBlocked = Set<String>()
        var didRollbackInstalledMetadata = false
        var didClearAuthentication = false
        let candidate = (sources: [String](), blocked: Set(["source-id"]))

        XCTAssertThrowsError(try ReaderExtensionDurableMutation.commitCoordinated(
            candidate: candidate,
            persist: { _ in },
            applySecondary: { throw InjectedFailure.blockedSet },
            rollbackPersistence: { didRollbackInstalledMetadata = true },
            publish: {
                liveSources = $0.sources
                liveBlocked = $0.blocked
            },
            afterCommit: { didClearAuthentication = true }
        ))
        XCTAssertTrue(didRollbackInstalledMetadata)
        XCTAssertEqual(liveSources, ["installed"])
        XCTAssertTrue(liveBlocked.isEmpty)
        XCTAssertFalse(didClearAuthentication)
    }

    func testURLAndArchivePolicyRejectsPrivateAndTokenizedInputs() throws {
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.validateRepositoryURLSyntax(URL(string: "https://127.0.0.1/index.json")!))
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.validateRepositoryURLSyntax(URL(string: "https://93.184.216.34/index.json?token=secret")!))
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.validateScriptURLSyntax(URL(string: "https://93.184.216.34/source.js?signature=secret")!))
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.validateNotArchive(
            data: Data([0x50, 0x4b, 0x03, 0x04]),
            response: nil,
            url: URL(string: "https://93.184.216.34/content")!
        ))
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.validateNotArchive(
            data: Data([0x50, 0x4b, 0x05, 0x06]),
            response: nil,
            url: URL(string: "https://93.184.216.34/content")!
        ))
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.validateNotArchive(
            data: Data([0x50, 0x4b, 0x07, 0x08]),
            response: nil,
            url: URL(string: "https://93.184.216.34/content")!
        ))
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.validateNotArchive(
            data: Data(repeating: 0x20, count: 900) + Data("%PDF-1.7".utf8),
            response: nil,
            url: URL(string: "https://93.184.216.34/content")!
        ))
        XCTAssertFalse(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes([
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1
        ]))
        XCTAssertFalse(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes([
            0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0, 192, 168, 1, 1
        ]))
        XCTAssertTrue(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes([
            0x26, 0x06, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11
        ]))
    }

    func testOpaquePageRequestRegistryIsLowCountByteAwareLRUAndRetainsReusableHandles() throws {
        let sourceA = ReaderExtensionSourceID(rawValue: String(repeating: "a", count: 64))
        let sourceB = ReaderExtensionSourceID(rawValue: String(repeating: "b", count: 64))
        let sourceC = ReaderExtensionSourceID(rawValue: String(repeating: "c", count: 64))
        func requests(
            sourceID: ReaderExtensionSourceID,
            count: Int,
            headerBytes: Int = 0
        ) -> [(UUID, ReaderExtensionEphemeralPageRequest)] {
            (0..<count).map { index in
                let id = UUID()
                return (id, ReaderExtensionEphemeralPageRequest(
                    sourceID: sourceID,
                    sourceRevision: "1",
                    scopeID: UUID().uuidString,
                    key: "page-\(index)",
                    url: publicBaseURL.appendingPathComponent("page-\(index).jpg"),
                    headers: headerBytes == 0 ? [:] : ["X-Owned": String(repeating: "v", count: headerBytes)]
                ))
            }
        }

        let registry = ReaderExtensionPageRequestRegistry()
        XCTAssertThrowsError(try registry.insert(
            requests(sourceID: sourceA, count: ReaderExtensionPageRequestRegistry.maximumPerSourceCount + 1),
            for: sourceA
        ))
        XCTAssertThrowsError(try registry.insert(
            requests(sourceID: sourceA, count: 65, headerBytes: 32 * 1_024),
            for: sourceA
        ))

        let reusableRegistry = ReaderExtensionPageRequestRegistry()
        let priorChapter = requests(sourceID: sourceA, count: 1)
        let nextChapter = requests(sourceID: sourceA, count: 1)
        try reusableRegistry.insert(priorChapter, for: sourceA)
        try reusableRegistry.insert(nextChapter, for: sourceA)
        XCTAssertNotNil(reusableRegistry.material(for: priorChapter[0].0))
        XCTAssertNotNil(reusableRegistry.material(for: priorChapter[0].0))
        XCTAssertTrue(reusableRegistry.contains(nextChapter[0].0))
        reusableRegistry.remove(sourceID: sourceA)
        XCTAssertEqual(reusableRegistry.count, 0, "auth/source invalidation must drop every retained handle")

        let a = requests(
            sourceID: sourceA,
            count: ReaderExtensionPageRequestRegistry.maximumPerSourceCount
        )
        let b = requests(
            sourceID: sourceB,
            count: ReaderExtensionPageRequestRegistry.maximumPerSourceCount
        )
        try registry.insert(a, for: sourceA)
        try registry.insert(b, for: sourceB)
        XCTAssertNotNil(registry.material(for: a[0].0), "touch must move the handle to the LRU tail")
        let c = requests(sourceID: sourceC, count: 1)
        try registry.insert(c, for: sourceC)
        XCTAssertEqual(registry.count, ReaderExtensionPageRequestRegistry.maximumGlobalCount)
        XCTAssertTrue(registry.contains(a[0].0))
        XCTAssertFalse(registry.contains(a[1].0))
        XCTAssertTrue(registry.contains(c[0].0))
        let beforeReuseBytes = registry.retainedByteCount
        XCTAssertNotNil(registry.material(for: c[0].0))
        XCTAssertNotNil(registry.material(for: c[0].0), "image retry/download reuse must retain the opaque handle")
        XCTAssertTrue(registry.contains(c[0].0))
        XCTAssertEqual(registry.count, ReaderExtensionPageRequestRegistry.maximumGlobalCount)
        XCTAssertEqual(registry.retainedByteCount, beforeReuseBytes)
    }

    func testRuntimeQuarantineIsDurableAndIndependentOfSourceMetadataTransaction() throws {
        let suite = "ReaderExtensionQuarantine.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let quarantineRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderExtensionQuarantine.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: quarantineRoot) }
        let fileStore = try ReaderExtensionRuntimeQuarantineFileStore(rootURL: quarantineRoot)
        let sourceID = ReaderExtensionSourceID(rawValue: String(repeating: "d", count: 64))
        let digest = String(repeating: "e", count: 64)

        try ReaderExtensionPersistence.markRuntimeQuarantined(
            sourceID: sourceID,
            digest: digest,
            in: defaults,
            fileStore: fileStore,
            checkpoint: { _ in false }
        )
        XCTAssertTrue(try ReaderExtensionPersistence.runtimeQuarantineContains(
            sourceID: sourceID,
            digest: digest,
            in: defaults,
            fileStore: ReaderExtensionRuntimeQuarantineFileStore(rootURL: quarantineRoot)
        ))

        let tooManySources = Array(
            repeating: installedSource(implementation: .madara),
            count: ReaderExtensionPersistence.maximumInstalledSourceCount + 1
        )
        XCTAssertThrowsError(try ReaderExtensionPersistence.persist(
            repositories: [],
            installedSources: tooManySources,
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: defaults
        ))
        XCTAssertTrue(try ReaderExtensionPersistence.runtimeQuarantineContains(
            sourceID: sourceID,
            digest: digest,
            in: defaults,
            fileStore: fileStore
        ))

        XCTAssertThrowsError(try ReaderExtensionPersistence.clearRuntimeQuarantine(
            sourceIDs: [sourceID],
            in: defaults,
            fileStore: fileStore,
            checkpoint: { _ in false }
        ))
        XCTAssertTrue(try ReaderExtensionPersistence.runtimeQuarantineContains(
            sourceID: sourceID,
            digest: digest,
            in: defaults,
            fileStore: ReaderExtensionRuntimeQuarantineFileStore(rootURL: quarantineRoot)
        ))
        try ReaderExtensionPersistence.clearRuntimeQuarantine(
            sourceIDs: [sourceID],
            in: defaults,
            fileStore: fileStore,
            checkpoint: { _ in true }
        )
        XCTAssertFalse(try ReaderExtensionPersistence.runtimeQuarantineContains(
            sourceID: sourceID,
            digest: digest,
            in: defaults,
            fileStore: ReaderExtensionRuntimeQuarantineFileStore(rootURL: quarantineRoot)
        ))
    }

    func testRuntimeQuarantineClearingRetainsExactDigestReferencedByAnotherProfile() throws {
        let suiteA = "ReaderExtensionQuarantineProfileA.\(UUID().uuidString)"
        let suiteB = "ReaderExtensionQuarantineProfileB.\(UUID().uuidString)"
        let storeA = try XCTUnwrap(UserDefaults(suiteName: suiteA))
        let storeB = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        defer {
            storeA.removePersistentDomain(forName: suiteA)
            storeB.removePersistentDomain(forName: suiteB)
        }
        var sourceA = installedSource(implementation: .javascript)
        let badDigest = String(repeating: "a", count: 64)
        let replacementDigest = String(repeating: "b", count: 64)
        sourceA.activeContentDigest = badDigest
        var sourceB = sourceA
        sourceB.activeContentDigest = replacementDigest
        func persist(_ sources: [ReaderExtensionInstalledSource], to store: UserDefaults) throws {
            try ReaderExtensionPersistence.persist(
                repositories: [],
                installedSources: sources,
                showMature: false,
                autoUpdate: true,
                lastAutoUpdate: nil,
                to: store
            )
        }
        try persist([sourceA], to: storeA)
        try persist([sourceB], to: storeB)

        let badEntry = ReaderExtensionRuntimeQuarantineEntry(sourceID: sourceA.id, digest: badDigest)
        let replacementEntry = ReaderExtensionRuntimeQuarantineEntry(sourceID: sourceA.id, digest: replacementDigest)
        let available: Set<ReaderExtensionRuntimeQuarantineEntry> = [badEntry, replacementEntry]
        let referenced = try XCTUnwrap(ReaderExtensionRuntimeQuarantineReferencePolicy.referencedEntries(
            rosterStoreIsReadable: true,
            stores: [storeA, storeB]
        ))
        XCTAssertEqual(referenced, available)
        XCTAssertTrue(ReaderExtensionRuntimeQuarantineClearPolicy.eligibleEntries(
            available: available,
            sourceIDs: [sourceA.id],
            referenced: referenced
        ).isEmpty, "Profile B replacing the source must not clear Profile A's bad digest")

        try persist([], to: storeA)
        let afterGlobalRemoval = try XCTUnwrap(ReaderExtensionRuntimeQuarantineReferencePolicy.referencedEntries(
            rosterStoreIsReadable: true,
            stores: [storeA, storeB]
        ))
        XCTAssertEqual(afterGlobalRemoval, [replacementEntry])
        XCTAssertEqual(
            ReaderExtensionRuntimeQuarantineClearPolicy.eligibleEntries(
                available: available,
                sourceIDs: [sourceA.id],
                referenced: afterGlobalRemoval
            ),
            [badEntry]
        )
        XCTAssertNil(ReaderExtensionRuntimeQuarantineReferencePolicy.referencedEntries(
            rosterStoreIsReadable: false,
            stores: [storeA, storeB]
        ))
    }

    func testQuarantineMarkerAndRollbackFailureFallsBackToDurableBlobRemoval() throws {
        enum InjectedFailure: Error { case markerStorage }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderExtensionQuarantineBlob.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contentStore = try ReaderExtensionContentStore(rootURL: root)
        let script = Data(requiredMangaScript(preferenceBody: "return [];").utf8)
        let staged = try contentStore.stageExactScript(script)
        let digest = try contentStore.activate(staged)
        XCTAssertEqual(try contentStore.scriptData(digest: digest), script)

        XCTAssertTrue(ReaderExtensionRuntimeQuarantineDurability.enforce(
            persistMarker: { throw InjectedFailure.markerStorage },
            removeExactExecutable: { try contentStore.removeExecutable(digest: digest) }
        ))
        let relaunchedStore = try ReaderExtensionContentStore(rootURL: root)
        XCTAssertThrowsError(try relaunchedStore.scriptData(digest: digest))
    }

    func testReaderExtensionPersistedCoverMetadataDropsProviderCredentials() {
        XCTAssertEqual(
            ReaderExtensionSafeMetadata.sanitizedURLString(
                URL(string: "https://cdn.example/title.jpg?token=owned-secret#signed"),
                fallback: "https://old.example/title.jpg?access_token=old-secret"
            ),
            "https://cdn.example/title.jpg"
        )
        XCTAssertEqual(
            ReaderExtensionSafeMetadata.sanitizedURLString(
                URL(string: "file:///private/provider-cover.jpg"),
                fallback: "https://old.example/title.jpg?access_token=old-secret"
            ),
            "https://old.example/title.jpg"
        )
        XCTAssertEqual(
            ReaderExtensionSafeMetadata.sanitizedURLString(
                URL(string: "file:///private/provider-cover.jpg"),
                fallback: "https://user:password@old.example/title.jpg?token=secret"
            ),
            "https://old.example/title.jpg"
        )
    }

    func testDownloadChapterKeysRejectPersistedCredentialsButKeepOrdinaryIDs() {
        XCTAssertEqual(
            ReaderDownloadManager.persistableReaderExtensionChapterKey("/chapter/read?number=12&volume=2"),
            "/chapter/read?number=12&volume=2"
        )
        XCTAssertNil(ReaderDownloadManager.persistableReaderExtensionChapterKey(
            "https://user:password@93.184.216.34/chapter/12"
        ))
        XCTAssertNil(ReaderDownloadManager.persistableReaderExtensionChapterKey(
            "https://93.184.216.34/chapter/12?access_token=owned-secret"
        ))
        XCTAssertNil(ReaderDownloadManager.persistableReaderExtensionChapterKey(
            "https://93.184.216.34/chapter/12?Signature=owned-secret"
        ))
        XCTAssertNil(ReaderDownloadManager.persistableReaderExtensionChapterKey(
            "/chapter/12#token=owned-secret"
        ))
    }

    func testUnsafeMigrationGateStillLoadsOnlyVerifiedCompletedDownloadsReadOnly() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "reader-offline-fallback-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceID = ReaderExtensionSourceID(rawValue: String(repeating: "d", count: 64))
        let completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        func makeItem(itemKey: String, chapterNumber: String, isNovel: Bool) -> ReaderDownloadItem {
            let route = MangaContentRoute.readerExtension(
                source: sourceID,
                itemKey: itemKey,
                legacyStableKey: nil
            )
            return ReaderDownloadItem(
                id: ReaderDownloadManager.downloadId(route: route, chapterNumber: chapterNumber),
                route: route,
                routeKey: route.stableKey,
                mangaId: route.stableNegativeId,
                mangaTitle: isNovel ? "Owned Novel" : "Owned Manga",
                coverURL: "https://covers.example/owned.jpg?token=must-not-survive",
                sourceName: "Owned Fixture",
                format: isNovel ? "Novel" : "Manga",
                chapterNumber: chapterNumber,
                chapterTitle: "Chapter \(chapterNumber)",
                chapterKey: ChapterIdentityNormalizer.key(for: chapterNumber),
                contentRating: ReaderContentRating.safe.rawValue,
                provider: ReaderDownloadProvider(
                    kind: .readerExtension,
                    sourceId: sourceID.rawValue,
                    mangaKey: itemKey,
                    moduleUUID: nil,
                    contentParams: nil,
                    isNovel: isNovel,
                    chapterParams: "/chapter/\(chapterNumber)?temporary=discarded"
                ),
                status: .completed,
                progress: 1,
                completedPages: 1,
                totalPages: 1,
                downloadedBytes: 999_999,
                error: nil,
                dateAdded: completedAt,
                dateCompleted: completedAt,
                legacyResumeStatus: nil
            )
        }

        func installFiles(
            for item: ReaderDownloadItem,
            kind: String,
            fileName: String,
            payload: Data,
            omitPayload: Bool = false
        ) throws {
            let chapterDirectory = root
                .appendingPathComponent(
                    ReaderDownloadManager.stableHash(item.routeKey),
                    isDirectory: true
                )
                .appendingPathComponent(
                    ReaderDownloadManager.stableHash(item.chapterKey),
                    isDirectory: true
                )
            try fileManager.createDirectory(at: chapterDirectory, withIntermediateDirectories: true)
            if !omitPayload {
                try payload.write(to: chapterDirectory.appendingPathComponent(fileName))
            }
            let routeObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoder.encode(item.route)) as? [String: Any]
            )
            let manifest: [String: Any] = [
                "version": 1,
                "itemId": item.id,
                "route": routeObject,
                "mangaTitle": item.mangaTitle,
                "chapterNumber": item.chapterNumber,
                "pages": [["index": 0, "kind": kind, "fileName": fileName]],
                "dateCompleted": ISO8601DateFormatter().string(from: completedAt)
            ]
            try JSONSerialization.data(withJSONObject: manifest).write(
                to: chapterDirectory.appendingPathComponent("chapter.json")
            )
        }

        let manga = makeItem(itemKey: "/owned/manga", chapterNumber: "1", isNovel: false)
        let novel = makeItem(itemKey: "/owned/novel", chapterNumber: "2", isNovel: true)
        let missingPage = makeItem(itemKey: "/owned/corrupt", chapterNumber: "3", isNovel: false)
        let traversal = makeItem(itemKey: "/owned/traversal", chapterNumber: "4", isNovel: false)
        let symlink = makeItem(itemKey: "/owned/symlink", chapterNumber: "5", isNovel: false)
        try installFiles(
            for: manga,
            kind: "image",
            fileName: "0001.jpg",
            payload: Data([0xff, 0xd8, 0xff, 0xd9])
        )
        try installFiles(
            for: novel,
            kind: "text",
            fileName: "0001.txt",
            payload: Data("Literal <style> text remains offline".utf8)
        )
        try installFiles(
            for: missingPage,
            kind: "image",
            fileName: "0001.jpg",
            payload: Data([0xff, 0xd8, 0xff, 0xd9]),
            omitPayload: true
        )
        try installFiles(
            for: traversal,
            kind: "image",
            fileName: "../0001.jpg",
            payload: Data([0xff, 0xd8, 0xff, 0xd9]),
            omitPayload: true
        )
        try installFiles(
            for: symlink,
            kind: "image",
            fileName: "0001.jpg",
            payload: Data([0xff, 0xd8, 0xff, 0xd9])
        )
        let externalPage = fileManager.temporaryDirectory.appendingPathComponent(
            "reader-offline-external-\(UUID().uuidString).jpg"
        )
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: externalPage)
        defer { try? fileManager.removeItem(at: externalPage) }
        let symlinkPage = root
            .appendingPathComponent(ReaderDownloadManager.stableHash(symlink.routeKey))
            .appendingPathComponent(ReaderDownloadManager.stableHash(symlink.chapterKey))
            .appendingPathComponent("0001.jpg")
        try fileManager.removeItem(at: symlinkPage)
        try fileManager.createSymbolicLink(at: symlinkPage, withDestinationURL: externalPage)

        let encodedRows: [Any] = try [manga, novel, missingPage, traversal, symlink].map {
            try JSONSerialization.jsonObject(with: encoder.encode($0))
        } + [["status": "completed", "id": "malformed-row"]]
        let indexURL = root.appendingPathComponent(".reader_downloads.json")
        let originalIndex = try JSONSerialization.data(withJSONObject: encodedRows)
        try originalIndex.write(to: indexURL)

        let loaded = ReaderDownloadManager.verifiedCompletedDownloadsForReadOnlyFallback(
            indexURL: indexURL,
            downloadsRoot: root,
            fileManager: fileManager
        )
        XCTAssertEqual(Set(loaded.map(\.id)), Set([manga.id, novel.id]))
        XCTAssertTrue(loaded.allSatisfy { $0.status == .completed })
        XCTAssertTrue(loaded.allSatisfy { $0.provider.chapterParams == nil })
        XCTAssertTrue(loaded.allSatisfy { $0.coverURL == "https://covers.example/owned.jpg" })
        XCTAssertEqual(loaded.first(where: { $0.id == manga.id })?.downloadedBytes, 4)

        var interruptedAfterManifest = manga
        interruptedAfterManifest.status = .downloading
        interruptedAfterManifest.progress = 0.5
        interruptedAfterManifest.completedPages = 0
        interruptedAfterManifest.totalPages = 1
        interruptedAfterManifest.downloadedBytes = 0
        interruptedAfterManifest.dateCompleted = nil
        let recoveredAfterIndexWriteFailure = try XCTUnwrap(
            ReaderDownloadManager.recoverableCompletedCopy(
                interruptedAfterManifest,
                downloadsRoot: root,
                fileManager: fileManager
            )
        )
        XCTAssertEqual(recoveredAfterIndexWriteFailure.status, .completed)
        XCTAssertEqual(recoveredAfterIndexWriteFailure.completedPages, 1)
        XCTAssertEqual(recoveredAfterIndexWriteFailure.downloadedBytes, 4)

        let loadedManga = try XCTUnwrap(loaded.first(where: { $0.id == manga.id }))
        let loadedNovel = try XCTUnwrap(loaded.first(where: { $0.id == novel.id }))
        let mangaPages = try XCTUnwrap(ReaderDownloadManager.verifiedReadOnlyPages(
            loadedManga,
            downloadsRoot: root,
            fileManager: fileManager
        ))
        XCTAssertEqual(mangaPages.count, 1)
        XCTAssertNotNil(mangaPages[0].urlString)
        let novelPages = try XCTUnwrap(ReaderDownloadManager.verifiedReadOnlyPages(
            loadedNovel,
            downloadsRoot: root,
            fileManager: fileManager
        ))
        XCTAssertEqual(novelPages.map(\.textContent), ["Literal <style> text remains offline"])

        var duplicateManga = manga
        duplicateManga.status = .failed
        let firstByID = ReaderDownloadManager.firstDownloadPerID([
            manga,
            duplicateManga,
            novel
        ])
        XCTAssertEqual(firstByID.count, 2)
        XCTAssertEqual(firstByID[manga.id]?.status, .completed)

        XCTAssertTrue(ReaderDownloadManager.persistedIndexAuthorityIsCurrent(
            expected: originalIndex,
            observed: ReaderDownloadManager.persistedIndexReadState(at: indexURL)
        ))
        let externalIndexURL = root.appendingPathComponent("external-index.json")
        try originalIndex.write(to: externalIndexURL)
        let symlinkIndexURL = root.appendingPathComponent("linked-index.json")
        try fileManager.createSymbolicLink(
            at: symlinkIndexURL,
            withDestinationURL: externalIndexURL
        )
        XCTAssertEqual(
            ReaderDownloadManager.persistedIndexReadState(at: symlinkIndexURL),
            .unreadable
        )
        XCTAssertFalse(ReaderDownloadManager.persistedIndexAuthorityIsCurrent(
            expected: originalIndex,
            observed: ReaderDownloadManager.persistedIndexReadState(at: symlinkIndexURL)
        ))

        let fifoIndexURL = root.appendingPathComponent("fifo-index.json")
        XCTAssertEqual(mkfifo(fifoIndexURL.path, S_IRUSR | S_IWUSR), 0)
        XCTAssertEqual(
            ReaderDownloadManager.persistedIndexReadState(at: fifoIndexURL),
            .unreadable
        )

        let oversizedIndexURL = root.appendingPathComponent("oversized-index.json")
        XCTAssertTrue(fileManager.createFile(atPath: oversizedIndexURL.path, contents: nil))
        let oversizedHandle = try FileHandle(forWritingTo: oversizedIndexURL)
        try oversizedHandle.truncate(atOffset: UInt64(32 * 1_024 * 1_024 + 1))
        try oversizedHandle.close()
        XCTAssertEqual(
            ReaderDownloadManager.persistedIndexReadState(at: oversizedIndexURL),
            .unreadable
        )

        let novelTextURL = root
            .appendingPathComponent(ReaderDownloadManager.stableHash(novel.routeKey))
            .appendingPathComponent(ReaderDownloadManager.stableHash(novel.chapterKey))
            .appendingPathComponent("0001.txt")
        let externalTextURL = root.appendingPathComponent("external-text.txt")
        try Data("external text must not be followed".utf8).write(to: externalTextURL)
        try fileManager.removeItem(at: novelTextURL)
        try fileManager.createSymbolicLink(at: novelTextURL, withDestinationURL: externalTextURL)
        XCTAssertNil(ReaderDownloadManager.verifiedReadOnlyPages(
            loadedNovel,
            downloadsRoot: root,
            fileManager: fileManager
        ))

        XCTAssertEqual(try Data(contentsOf: indexURL), originalIndex)
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(".reader_downloads.json.tmp").path))
    }

    func testProviderItemKeysCannotPersistOrExportAuthorizationValues() throws {
        XCTAssertNil(ReaderExtensionSecurityPolicy.persistableProviderContentKey(
            "/title/1?access_token=owned-secret"
        ))
        XCTAssertNil(ReaderExtensionSecurityPolicy.persistableProviderContentKey(
            "https://user:password@93.184.216.34/title/1"
        ))
        XCTAssertNil(ReaderExtensionSecurityPolicy.persistableProviderContentKey(
            "/title/1?x-api-key=owned-secret"
        ))
        XCTAssertNil(ReaderExtensionSecurityPolicy.persistableProviderContentKey(
            "/title/1?credential=owned-secret"
        ))
        XCTAssertNil(ReaderExtensionSecurityPolicy.persistableProviderContentKey(
            "/title/1?secret=owned-secret"
        ))
        XCTAssertEqual(
            ReaderExtensionSecurityPolicy.persistableProviderContentKey(
                "/title/1?number=12&volume=2"
            ),
            "/title/1?number=12&volume=2"
        )

        let sourceID = ReaderExtensionSourceID(rawValue: String(repeating: "a", count: 64))
        let unsafe = MangaContentRoute.readerExtension(
            source: sourceID,
            itemKey: "/title/1?access_token=owned-secret",
            legacyStableKey: nil
        )
        XCTAssertThrowsError(try JSONEncoder().encode(unsafe))
        let emptyAlias = MangaContentRoute.readerExtension(
            source: sourceID,
            itemKey: "/title/1?access_token=owned-secret",
            legacyStableKey: ""
        )
        XCTAssertThrowsError(try JSONEncoder().encode(emptyAlias))

        let migratedLegacy = MangaContentRoute.readerExtension(
            source: sourceID,
            itemKey: "/title/1?access_token=legacy-value",
            legacyStableKey: "aidoku:owned:/title/1?access_token=legacy-value"
        )
        XCTAssertThrowsError(try JSONEncoder().encode(migratedLegacy))

        let craftedLegacyAlias = Data("""
        {
          "kind":"readerExtension",
          "source":"\(sourceID.rawValue)",
          "itemKey":"/title/1?access_token=owned-secret",
          "legacyStableKey":"aidoku:owned:/title/1"
        }
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(
            MangaContentRoute.self,
            from: craftedLegacyAlias
        ))

        let safeMigrated = MangaContentRoute.readerExtension(
            source: sourceID,
            itemKey: "/title/1?number=12&volume=2",
            legacyStableKey: "aidoku:owned:/title/1?access_token=historical-identity"
        )
        let encodedSafeMigrated = try JSONEncoder().encode(safeMigrated)
        XCTAssertEqual(
            try JSONDecoder().decode(MangaContentRoute.self, from: encodedSafeMigrated),
            safeMigrated,
            "Only the opaque historical stable identity may retain legacy text; the live provider key must remain credential-free"
        )
    }

    func testCustomNAT64PrefixesRejectEmbeddedPrivateIPv4AtEveryRFC6052Length() throws {
        for length in ReaderExtensionNAT64Prefix.supportedLengths {
            let prefix = syntheticNAT64Prefix(length: length)
            let discovery = [
                rfc6052Address(prefix: prefix, length: length, ipv4: [192, 0, 0, 170]),
                rfc6052Address(prefix: prefix, length: length, ipv4: [192, 0, 0, 171])
            ]
            let detected = ReaderExtensionSecurityPolicy.discoveredNAT64Prefixes(from: discovery)
            XCTAssertEqual(
                detected.filter { $0.length == length && $0.prefixBytes == prefix }.count,
                1,
                "the custom /\(length) discovery pair must identify its exact prefix"
            )

            let privateDestination = rfc6052Address(
                prefix: prefix,
                length: length,
                ipv4: [10, 24, 0, 7]
            )
            XCTAssertFalse(
                ReaderExtensionSecurityPolicy.isPublicIPv6Bytes(
                    privateDestination,
                    nat64DiscoveryAddresses: discovery
                ),
                "a custom /\(length) must not hide a private IPv4 destination"
            )

            let publicDestination = rfc6052Address(
                prefix: prefix,
                length: length,
                ipv4: [8, 8, 8, 8]
            )
            XCTAssertTrue(
                ReaderExtensionSecurityPolicy.isPublicIPv6Bytes(
                    publicDestination,
                    nat64DiscoveryAddresses: discovery
                ),
                "a valid public destination should remain usable through custom /\(length)"
            )
        }
    }

    func testNAT64DiscoveryAcceptsOneUnambiguousWKAAndRejectsMalformedEncodings() throws {
        let length = 56
        let prefix = syntheticNAT64Prefix(length: length)
        let discovery170 = rfc6052Address(prefix: prefix, length: length, ipv4: [192, 0, 0, 170])
        let discovery171 = rfc6052Address(prefix: prefix, length: length, ipv4: [192, 0, 0, 171])

        XCTAssertEqual(
            ReaderExtensionSecurityPolicy.discoveredNAT64Prefixes(from: [discovery170]),
            Set([ReaderExtensionNAT64Prefix(prefixBytes: prefix, length: length)!])
        )
        XCTAssertEqual(
            ReaderExtensionSecurityPolicy.discoveredNAT64Prefixes(from: [discovery170, discovery170]),
            Set([ReaderExtensionNAT64Prefix(prefixBytes: prefix, length: length)!])
        )
        XCTAssertTrue(ReaderExtensionSecurityPolicy.discoveredNAT64Prefixes(from: [
            rfc6052Address(prefix: prefix, length: length, ipv4: [192, 0, 0, 172]),
            rfc6052Address(prefix: prefix, length: length, ipv4: [192, 0, 0, 173])
        ]).isEmpty)
        XCTAssertNil(ReaderExtensionNAT64Prefix(prefixBytes: Array(prefix.prefix(8)), length: 72))

        var malformedU170 = discovery170
        var malformedU171 = discovery171
        malformedU170[8] = 1
        malformedU171[8] = 1
        XCTAssertTrue(ReaderExtensionSecurityPolicy.discoveredNAT64Prefixes(from: [
            malformedU170, malformedU171
        ]).isEmpty, "the mandatory RFC 6052 u octet must be zero")

        let ambiguousPrefix = syntheticNAT64Prefix(length: 32)
        var ambiguous = rfc6052Address(prefix: ambiguousPrefix, length: 32, ipv4: [192, 0, 0, 170])
        ambiguous.replaceSubrange(9..<13, with: [192, 0, 0, 171])
        XCTAssertTrue(ReaderExtensionSecurityPolicy.discoveredNAT64Prefixes(from: [ambiguous]).isEmpty,
                      "a discovery address that decodes at two RFC 6052 lengths is ambiguous")

        let validDiscovery = [discovery170, discovery171]
        var malformedTarget = rfc6052Address(prefix: prefix, length: length, ipv4: [8, 8, 8, 8])
        malformedTarget[8] = 0x80
        XCTAssertFalse(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes(
            malformedTarget,
            nat64DiscoveryAddresses: validDiscovery
        ), "a malformed address inside the active translation prefix must fail closed")

        var privateWithNonzeroReservedSuffix = rfc6052Address(
            prefix: prefix,
            length: length,
            ipv4: [192, 168, 50, 2]
        )
        privateWithNonzeroReservedSuffix[15] = 0x7f
        XCTAssertFalse(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes(
            privateWithNonzeroReservedSuffix,
            nat64DiscoveryAddresses: validDiscovery
        ), "reserved suffix bits must not obscure the embedded private destination")

        // A malformed /96 discovery prefix with a nonzero RFC 6052 u octet
        // must not be learned, even though the IPv4 bytes themselves look
        // like the well-known discovery pair.
        let prefix96 = syntheticNAT64Prefix(length: 96)
        var malformed96170 = rfc6052Address(prefix: prefix96, length: 96, ipv4: [192, 0, 0, 170])
        var malformed96171 = rfc6052Address(prefix: prefix96, length: 96, ipv4: [192, 0, 0, 171])
        malformed96170[8] = 1
        malformed96171[8] = 1
        XCTAssertTrue(ReaderExtensionSecurityPolicy.discoveredNAT64Prefixes(from: [
            malformed96170, malformed96171
        ]).isEmpty)
    }

    func testStaticNAT64PrefixesUseCorrectRFC6052Extraction() throws {
        let localUsePrefix: [UInt8] = [0x00, 0x64, 0xff, 0x9b, 0x00, 0x01]
        XCTAssertFalse(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes(
            rfc6052Address(prefix: localUsePrefix, length: 48, ipv4: [172, 20, 1, 9])
        ))
        XCTAssertTrue(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes(
            rfc6052Address(prefix: localUsePrefix, length: 48, ipv4: [1, 1, 1, 1])
        ))

        let wellKnownPrefix: [UInt8] = [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertFalse(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes(
            rfc6052Address(prefix: wellKnownPrefix, length: 96, ipv4: [127, 0, 0, 1])
        ))
        XCTAssertTrue(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes(
            rfc6052Address(prefix: wellKnownPrefix, length: 96, ipv4: [9, 9, 9, 9])
        ))
    }

    func testLegacyIPv6TransitionTunnelsCannotHideIPv4Destinations() {
        XCTAssertFalse(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes([
            0x20, 0x02, 10, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
        ]), "6to4 with an embedded private IPv4 destination must be rejected")
        XCTAssertFalse(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes([
            0x20, 0x02, 8, 8, 8, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
        ]), "Reader extensions do not need legacy 6to4 compatibility")
        XCTAssertFalse(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes([
            0x20, 0x01, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
        ]), "Teredo is rejected rather than attempting unsafe obfuscated IPv4 decoding")
    }

    func testDeprecatedIPv6SiteLocalSpaceIsNotPublic() {
        XCTAssertFalse(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes([
            0xfe, 0xc0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
        ]))
        XCTAssertFalse(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes([
            0xfe, 0xff, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
        ]))
        XCTAssertTrue(ReaderExtensionSecurityPolicy.isPublicIPv6Bytes([
            0x26, 0x06, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
        ]), "nearby ordinary global IPv6 must remain usable")
    }

    func testCanonicalHostUnifiesTrailingDotIDNAConsentOriginsAndCookieDomains() throws {
        XCTAssertEqual(
            ReaderExtensionSecurityPolicy.canonicalHost("BÜCHER.Example."),
            "xn--bcher-kva.example"
        )
        XCTAssertEqual(
            ReaderExtensionSecurityPolicy.canonicalHost(".xn--bcher-kva.example."),
            "xn--bcher-kva.example"
        )
        XCTAssertEqual(ReaderExtensionSecurityPolicy.canonicalHost("[2606:4700::1111]"), "2606:4700::1111")
        XCTAssertNil(ReaderExtensionSecurityPolicy.canonicalHost("evil.com%00.example"))
        XCTAssertNil(ReaderExtensionSecurityPolicy.canonicalHost("bad..example"))

        let unicodeFQDN = URL(string: "https://BÜCHER.example./chapter")!
        XCTAssertNoThrow(try ReaderExtensionSecurityPolicy.validateApprovedDomain(
            unicodeFQDN,
            approvedDomains: ["xn--bcher-kva.example"]
        ))
        XCTAssertNoThrow(try ReaderExtensionSecurityPolicy.validateApprovedDomain(
            URL(string: "https://xn--bcher-kva.example/chapter")!,
            approvedDomains: ["BÜCHER.example."]
        ))

        let sourceID = ReaderExtensionSourceID(rawValue: "reader:test-host-normalization")
        let unicodeRequest = ReaderExtensionDomainConsentRequest(
            scopeID: "profile",
            sourceID: sourceID,
            host: "BÜCHER.example."
        )
        let asciiRequest = ReaderExtensionDomainConsentRequest(
            scopeID: "profile",
            sourceID: sourceID,
            host: "xn--bcher-kva.example"
        )
        XCTAssertEqual(unicodeRequest, asciiRequest)
        XCTAssertEqual(unicodeRequest.id, asciiRequest.id)
        XCTAssertTrue(ReaderExtensionSecurityPolicy.host(
            "reader.BÜCHER.example.",
            isEqualToOrSubdomainOf: ".xn--bcher-kva.example"
        ))
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
            URL(string: "https://LOCALHOST./")!
        ))
    }

    func testCrossOriginRedirectSanitizationStripsCustomCredentialsAndPreservesSafeHeaders() throws {
        let input = [
            "Authorization": "Bearer primary-secret",
            "X-API-Key": "api-secret",
            "X-Auth-Token": "auth-secret",
            "X-Custom-Secret": "custom-secret",
            "X-CSRF-Token": "csrf-secret",
            "X-Vendor-Header": "Bearer disguised-secret",
            "X-Opaque-Proof": "unlabelled-secret-material",
            "Referer": "https://source.example/series/1",
            "Cookie": "session=cookie-secret",
            "Accept": "application/json",
            "User-Agent": "Owned Fixture/1.0",
            "Cache-Control": "no-cache",
            "Range": "bytes=0-1023"
        ]
        let authored = try ReaderExtensionSecurityPolicy.sanitizedHeaders(
            input,
            crossOrigin: true,
            allowsAuthoredNavigationHeaders: true
        )
        XCTAssertNotNil(
            authored.first(where: { $0.key.caseInsensitiveCompare("Referer") == .orderedSame }),
            "an extension's own first-party request keeps the referer it authored"
        )
        XCTAssertNil(
            authored.first(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }),
            "authoring a referer must never re-open credential headers"
        )
        for leaked in [
            "Authorization", "X-API-Key", "X-Auth-Token", "X-Custom-Secret",
            "X-CSRF-Token", "X-Vendor-Header", "X-Opaque-Proof"
        ] {
            XCTAssertNil(
                authored[leaked],
                "\(leaked) must not survive a cross-origin request just because a referer was authored"
            )
        }
        XCTAssertEqual(authored["Accept"], "application/json")
        XCTAssertEqual(authored["Range"], "bytes=0-1023")

        let redirected = try ReaderExtensionSecurityPolicy.sanitizedHeaders(input, crossOrigin: true)
        XCTAssertNil(
            redirected.first(where: { $0.key.caseInsensitiveCompare("Referer") == .orderedSame }),
            "a redirect replay carries the header set to an origin the extension never named, so referer still goes"
        )
        XCTAssertEqual(redirected["Accept"], "application/json")
        XCTAssertEqual(redirected["User-Agent"], "Owned Fixture/1.0")
        XCTAssertEqual(redirected["Cache-Control"], "no-cache")
        XCTAssertEqual(redirected["Range"], "bytes=0-1023")
        XCTAssertNil(redirected["Authorization"])
        XCTAssertNil(redirected["X-API-Key"])
        XCTAssertNil(redirected["X-Auth-Token"])
        XCTAssertNil(redirected["X-Custom-Secret"])
        XCTAssertNil(redirected["X-CSRF-Token"])
        XCTAssertNil(redirected["X-Vendor-Header"])
        XCTAssertNil(redirected["X-Opaque-Proof"])

        let sameOrigin = try ReaderExtensionSecurityPolicy.sanitizedHeaders(input, crossOrigin: false)
        XCTAssertEqual(sameOrigin["X-API-Key"], "api-secret", "origin-bound credentials must remain usable")
    }

    func testResourceHeaderLayersUseMangayomiOverrideOrderWithoutLeakingAcrossOrigins() throws {
        let merged = try ReaderExtensionResourceHeaderPolicy.merging([
            [
                "Accept": "image/*",
                "Authorization": "Bearer owned-secret",
                "Cookie": "session=must-never-survive"
            ],
            [
                "accept": "image/webp",
                "User-Agent": "Owned Fixture/1.0",
                "X-Source-Proof": "owned-origin-bound"
            ],
            [
                "ACCEPT": "image/avif",
                "Range": "bytes=0-1023"
            ]
        ])

        XCTAssertEqual(merged["ACCEPT"], "image/avif", "page-specific headers must win case-insensitively")
        XCTAssertNil(merged["Accept"])
        XCTAssertNil(merged["accept"])
        XCTAssertNil(merged["Cookie"])
        XCTAssertEqual(merged["Authorization"], "Bearer owned-secret")

        let passiveThirdParty = try ReaderExtensionSecurityPolicy.sanitizedHeaders(
            merged,
            crossOrigin: true
        )
        XCTAssertEqual(passiveThirdParty["ACCEPT"], "image/avif")
        XCTAssertEqual(passiveThirdParty["User-Agent"], "Owned Fixture/1.0")
        XCTAssertEqual(passiveThirdParty["Range"], "bytes=0-1023")
        XCTAssertNil(passiveThirdParty["Authorization"])
        XCTAssertNil(passiveThirdParty["X-Source-Proof"])
    }

    func testOnlyHostGeneratedOriginRefererSurvivesNativeCDNHop() throws {
        let sourceOrigin = try XCTUnwrap(URL(string: "https://93.184.216.34/chapter/owned?access_token=must-strip#private"))
        let sameOriginTarget = publicBaseURL.appendingPathComponent("page.jpg")
        let crossOriginTarget = try XCTUnwrap(URL(string: "https://1.1.1.1/page.jpg"))
        let request = ReaderExtensionNetworkRequest(
            url: crossOriginTarget,
            headers: ["Referer": "https://attacker.example/full/private/path?token=secret"],
            sourceID: ReaderExtensionSourceID(rawValue: String(repeating: "a", count: 64)),
            approvedDomains: ["93.184.216.34", "1.1.1.1"],
            baseDomain: "93.184.216.34",
            hostGeneratedOriginReferer: sourceOrigin
        )

        let providerHeaders = try ReaderExtensionSecurityPolicy.sanitizedHeaders(
            request.headers,
            crossOrigin: true
        )
        XCTAssertNil(providerHeaders["Referer"], "an arbitrary provider Referer must remain origin-bound")
        XCTAssertEqual(
            try ReaderExtensionSecurityPolicy.hostGeneratedOriginReferer(
                for: request,
                targetURL: sameOriginTarget
            ),
            "https://93.184.216.34/"
        )
        XCTAssertEqual(
            try ReaderExtensionSecurityPolicy.hostGeneratedOriginReferer(
                for: request,
                targetURL: crossOriginTarget
            ),
            "https://93.184.216.34/",
            "native page/asset CDNs receive only the validated source origin"
        )
        XCTAssertNil(try ReaderExtensionSecurityPolicy.hostGeneratedOriginReferer(
            for: request,
            targetURL: URL(string: "http://1.1.1.1/page.jpg")!
        ))

        var forged = request
        forged.hostGeneratedOriginReferer = URL(string: "https://1.1.1.1/forged")
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.hostGeneratedOriginReferer(
            for: forged,
            targetURL: crossOriginTarget
        )) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .insecureURL)
        }
    }

    func testPublicResolutionReturnsNumericConnectionPinsAndRejectsPrivatePins() throws {
        XCTAssertEqual(try ReaderExtensionSecurityPolicy.resolvedPublicAddresses(host: "93.184.216.34"), ["93.184.216.34"])
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.resolvedPublicAddresses(host: "127.0.0.1"))
        XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.resolvedPublicAddresses(host: "10.0.0.1"))
    }

    func testCookieDomainMustRemainInsideCurrentApprovedScope() throws {
        let requestURL = try XCTUnwrap(URL(string: "https://reader.example.com/chapter/1"))
        let broad = try XCTUnwrap(HTTPCookie(properties: [
            .name: "owned-session",
            .value: "broad-cookie",
            .domain: ".example.com",
            .path: "/",
            .secure: "TRUE"
        ]))
        let narrow = try XCTUnwrap(HTTPCookie(properties: [
            .name: "owned-session",
            .value: "narrow-cookie",
            .domain: "reader.example.com",
            .path: "/",
            .secure: "TRUE"
        ]))

        XCTAssertFalse(ReaderExtensionSecurityPolicy.cookie(
            broad,
            mayBeSentTo: requestURL,
            approvedDomains: ["reader.example.com"]
        ), "a stale broad cookie must not survive approval shrink or LKG rollback")
        XCTAssertTrue(ReaderExtensionSecurityPolicy.cookie(
            narrow,
            mayBeSentTo: requestURL,
            approvedDomains: ["reader.example.com"]
        ))
        XCTAssertTrue(ReaderExtensionSecurityPolicy.cookie(
            broad,
            mayBeSentTo: requestURL,
            approvedDomains: ["example.com"]
        ))
    }

    func testResponseBoundsKeepOrdinaryRequestsAtEightMiBAndCapPagesAtThirtyTwoMiB() async throws {
        let sourceID = ReaderExtensionSourceID(
            repositoryURL: publicBaseURL.appendingPathComponent("index.json"),
            upstreamID: "response-bound",
            language: "en",
            mediaType: .manga
        )
        let ordinary = ReaderExtensionNetworkRequest(
            url: publicBaseURL.appendingPathComponent("content"),
            sourceID: sourceID,
            approvedDomains: [publicBaseURL.host!]
        )
        XCTAssertEqual(ordinary.maximumResponseBytes, 8 * 1_024 * 1_024)

        let page = ReaderExtensionNetworkRequest(
            url: publicBaseURL.appendingPathComponent("page.jpg"),
            sourceID: sourceID,
            approvedDomains: [publicBaseURL.host!],
            maximumResponseBytes: ReaderExtensionSecurityPolicy.maximumPageResponseBytes
        )
        XCTAssertEqual(page.maximumResponseBytes, 32 * 1_024 * 1_024)

        let oversized = ReaderExtensionNetworkRequest(
            url: publicBaseURL.appendingPathComponent("page.jpg"),
            sourceID: sourceID,
            approvedDomains: [publicBaseURL.host!],
            maximumResponseBytes: ReaderExtensionSecurityPolicy.maximumPageResponseBytes + 1
        )
        do {
            _ = try await ReaderExtensionSecureHTTPClient(keychainNamespace: "reader-bound-test").request(oversized)
            XCTFail("the page-response ceiling must be enforced before DNS or I/O")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .contentTooLarge)
        }
    }

    func testPageMetadataNeverEncodesCredentials() throws {
        let page = ReaderExtensionPage(
            key: "one",
            url: URL(string: "\(publicBaseURL.absoluteString)/page.jpg?token=signed-secret#private")!,
            headers: ["Referer": publicBaseURL.absoluteString, "Cookie": "session=secret", "Authorization": "Bearer secret"]
        )
        let encoded = String(data: try JSONEncoder().encode(page), encoding: .utf8)!
        XCTAssertTrue(encoded.contains("Referer"))
        XCTAssertEqual(page.transientRequestHeaders["Authorization"], "Bearer secret")
        XCTAssertEqual(page.transientRequestHeaders["Cookie"], "session=secret")
        XCTAssertFalse(encoded.lowercased().contains("cookie"))
        XCTAssertFalse(encoded.lowercased().contains("authorization"))
        XCTAssertFalse(encoded.lowercased().contains("token"))
        XCTAssertFalse(encoded.lowercased().contains("signed-secret"))
        XCTAssertFalse(encoded.contains("secret"))
    }

    func testReaderPageDataContainsOnlyAnOpaqueExtensionHandle() {
        let sourceID = ReaderExtensionSourceID(
            repositoryURL: publicBaseURL.appendingPathComponent("index.json"),
            upstreamID: "owned",
            language: "en",
            mediaType: .manga
        )
        let resource = ReaderExtensionPageResource(
            requestID: UUID(),
            sourceID: sourceID,
            key: "page-one"
        )
        let page = resource.pageData

        XCTAssertNil(page.urlString, "signed/provider page URLs must remain in the manager")
        XCTAssertTrue(page.headers.isEmpty, "PageData must never expose generated authentication headers")
        XCTAssertEqual(page.readerExtensionResource, resource)
        XCTAssertTrue(page.isImageLike)
        XCTAssertEqual(
            MangaContentRoute.readerExtension(source: sourceID, itemKey: "item", legacyStableKey: nil).readerExtensionSourceID,
            sourceID
        )
        XCTAssertNil(
            MangaContentRoute.legacyModule(moduleUUID: UUID().uuidString, contentParams: "item", isNovel: false)
                .readerExtensionSourceID
        )
    }

    func testReaderExtensionImageSafetyRejectsDecompressionBombDimensions() throws {
        XCTAssertNoThrow(
            try ReaderExtensionImageSafety.validateDimensions(
                pixelWidth: 1_200,
                pixelHeight: 20_000
            )
        )
        XCTAssertThrowsError(
            try ReaderExtensionImageSafety.validateDimensions(
                pixelWidth: ReaderExtensionImageSafety.maximumPixelDimension + 1,
                pixelHeight: 1
            )
        )
        XCTAssertThrowsError(
            try ReaderExtensionImageSafety.validateDimensions(
                pixelWidth: 10_000,
                pixelHeight: 10_000
            )
        )
        XCTAssertThrowsError(
            try ReaderExtensionImageSafety.validateDimensions(
                pixelWidth: 1,
                pixelHeight: 1,
                frameCount: ReaderExtensionImageSafety.maximumFrameCount + 1
            )
        )
        XCTAssertThrowsError(try ReaderExtensionImageSafety.validate(Data("not-an-image".utf8)))
    }

    func testLegacyReaderPinnedImageCacheIdentityIsHeaderSensitiveAndSecretFree() throws {
        let url = URL(string: "https://reader.example/signed/path/credential-page.jpg?token=url-secret")!
        let first = PageData(content: .url(
            url.absoluteString,
            headers: ["Authorization": "Bearer first-secret", "Referer": "https://reader.example/title"]
        ))
        let same = PageData(content: .url(
            url.absoluteString,
            headers: ["referer": "https://reader.example/title", "authorization": "Bearer first-secret"]
        ))
        let second = PageData(content: .url(
            url.absoluteString,
            headers: ["Authorization": "Bearer second-secret", "Referer": "https://reader.example/title"]
        ))

        XCTAssertEqual(first.cacheKey, same.cacheKey)
        XCTAssertNotEqual(first.cacheKey, second.cacheKey)
        for key in [first.cacheKey, second.cacheKey] {
            XCTAssertFalse(key.contains("first-secret"))
            XCTAssertFalse(key.contains("second-secret"))
            XCTAssertFalse(key.contains("credential-page"))
            XCTAssertFalse(key.contains("url-secret"))
        }

        let firstRequest = try ReaderPinnedImageRequest.make(
            url: url,
            headers: first.headers,
            profileScopeID: "profile-a"
        )
        let otherProfileRequest = try ReaderPinnedImageRequest.make(
            url: url,
            headers: first.headers,
            profileScopeID: "profile-b"
        )
        let otherCredentialRequest = try ReaderPinnedImageRequest.make(
            url: url,
            headers: second.headers,
            profileScopeID: "profile-a"
        )
        XCTAssertNotEqual(firstRequest.clientScopeKey, otherProfileRequest.clientScopeKey)
        XCTAssertNotEqual(firstRequest.clientScopeKey, otherCredentialRequest.clientScopeKey)
        XCTAssertThrowsError(
            try ReaderPinnedImageRequest.make(
                url: url,
                headers: ["Host": "private.internal"],
                profileScopeID: "profile-a"
            )
        )
        XCTAssertThrowsError(
            try ReaderPinnedImageRequest.make(
                url: url,
                headers: ["X-Injected": "ok\r\nHost: private.internal"],
                profileScopeID: "profile-a"
            )
        )
    }

    func testLegacyReaderPinnedImageLocalPathEnforcesByteAndDecodeBounds() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            context.cgContext.setFillColor(UIColor.magenta.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let data = try XCTUnwrap(image.pngData())
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-pinned-image-\(UUID().uuidString).png")
        try data.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let request = try ReaderPinnedImageRequest.make(
            url: fileURL,
            maximumResponseBytes: data.count,
            maximumPixelSize: 64,
            profileScopeID: "local-test"
        )
        let loaded = try await ReaderPinnedImageLoader.shared.data(for: request)
        XCTAssertEqual(loaded, data)

        let tooSmall = try ReaderPinnedImageRequest.make(
            url: fileURL,
            maximumResponseBytes: data.count - 1,
            maximumPixelSize: 64,
            profileScopeID: "local-test"
        )
        do {
            _ = try await ReaderPinnedImageLoader.shared.data(for: tooSmall)
            XCTFail("Expected the local image byte limit to reject the file")
        } catch {
            XCTAssertTrue(true)
        }
    }

    func testLegacyKanzenJavaScriptNetworkAndTimerInputsAreBounded() throws {
        XCTAssertNil(LegacyKanzenNetworkPolicy.boundedTimerDelayMilliseconds(.nan))
        XCTAssertNil(LegacyKanzenNetworkPolicy.boundedTimerDelayMilliseconds(.infinity))
        XCTAssertEqual(LegacyKanzenNetworkPolicy.boundedTimerDelayMilliseconds(-50), 0)
        XCTAssertEqual(
            LegacyKanzenNetworkPolicy.boundedTimerDelayMilliseconds(Double.greatestFiniteMagnitude),
            LegacyKanzenNetworkPolicy.maximumTimerDelayMilliseconds
        )

        XCTAssertEqual(try LegacyKanzenNetworkPolicy.normalizedMethod(" post "), "POST")
        XCTAssertThrowsError(try LegacyKanzenNetworkPolicy.normalizedMethod("TRACE"))
        XCTAssertThrowsError(try LegacyKanzenNetworkPolicy.validatedHTTPURL("file:///etc/passwd"))
        XCTAssertThrowsError(try LegacyKanzenNetworkPolicy.validatedHTTPURL("https://user:secret@reader.example/page"))
        XCTAssertNoThrow(try LegacyKanzenNetworkPolicy.validatedHTTPURL("https://reader.example/page"))

        XCTAssertThrowsError(
            try LegacyKanzenNetworkPolicy.requestBody("not-allowed", method: "GET")
        )
        XCTAssertThrowsError(
            try LegacyKanzenNetworkPolicy.requestBody(
                String(repeating: "x", count: LegacyKanzenNetworkPolicy.maximumRequestBodyBytes + 1),
                method: "POST"
            )
        )
        XCTAssertEqual(
            try LegacyKanzenNetworkPolicy.requestBody("payload", method: "POST"),
            Data("payload".utf8)
        )

        let tooManyHeaders = Dictionary(
            uniqueKeysWithValues: (0...64).map { ("X-Header-\($0)", "value") }
        )
        XCTAssertThrowsError(try LegacyKanzenNetworkPolicy.stringHeaders(from: tooManyHeaders))
        XCTAssertThrowsError(try ServicePinnedRequestHeaders(["Host": "private.internal"], method: "GET"))
        XCTAssertThrowsError(
            try ServicePinnedRequestHeaders(
                ["X-Injected": "ok\r\nHost: private.internal"],
                method: "GET"
            )
        )

        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://reader.example/page")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Set-Cookie": "session=secret", "X-Safe": "yes"]
        ))
        let responseHeaders = LegacyKanzenNetworkPolicy.responseHeaders(response)
        XCTAssertEqual(responseHeaders["X-Safe"], "yes")
        XCTAssertFalse(responseHeaders.keys.contains { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame })

        let signedError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: "https://reader.example/signed?token=secret"]
        )
        let safeMessage = LegacyKanzenNetworkPolicy.userFacingError(signedError)
        XCTAssertEqual(safeMessage, "Network request failed")
        XCTAssertFalse(safeMessage.contains("secret"))
    }

    func testAllFiveNativeFamiliesParseOwnedSyntheticListings() async throws {
        let fixtures: [(ReaderExtensionImplementation, String, String?)] = [
            (.madara, "<div class='page-item-detail'><div class='post-title'><a href='/manga/one'>One</a></div><img src='/cover.jpg'></div>", nil),
            (.mangaReader, "<div class='listupd'><div class='bs'><div class='bsx'><a href='/manga/one' title='One'><img src='/cover.jpg'></a></div></div></div>", nil),
            (.mangaBox, "<div class='genres-item'><h3><a href='/manga/one'>One</a></h3><img src='/cover.jpg'></div>", "{\"urlStyle\":\"pathPages\"}"),
            (.mmrcms, "<div class='chapter-container'><div class='media-heading'><a href='/manga/one'>One</a></div><img src='/cover.jpg'></div>", nil)
        ]
        for (implementation, html, parameters) in fixtures {
            let source = installedSource(implementation: implementation, additionalParameters: parameters)
            let provider = try ReaderExtensionNativeProviderFactory.make(
                source: source,
                network: ReaderExtensionFixtureNetwork(body: Data(html.utf8)),
                approvedDomains: [publicBaseURL.host!],
                consentScopeID: "test"
            )
            let result = try await provider.popular(page: 1)
            XCTAssertEqual(result.items.first?.title, "One", "failed family \(implementation.rawValue)")
        }

        let nepFixture = "vm.Directory = [{\"s\":\"One\",\"i\":\"one\",\"cover\":\"https://93.184.216.34/cover.jpg\",\"vm\":1}]; vm.GetIntValue"
        let nepSource = installedSource(implementation: .nepNep)
        let nep = try ReaderExtensionNativeProviderFactory.make(
            source: nepSource,
            network: ReaderExtensionFixtureNetwork(body: Data(nepFixture.utf8)),
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "test"
        )
        let nepResult = try await nep.popular(page: 1)
        XCTAssertEqual(nepResult.items.first?.title, "One")
        do {
            _ = try await nep.pages(chapterKey: "http://[")
            XCTFail("a malformed NepNep chapter key was accepted")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .resultInvalid("NepNep chapter URL is invalid"))
        }
    }

    func testNepNepExposesCompleteSchemaAndCombinesEveryFilterKind() async throws {
        let rows: [[String: Any]] = [
            [
                "s": "Beta Hero", "i": "beta", "y": "2024", "a": "Ada Lovelace",
                "ss": "Ongoing", "ps": "Complete", "t": "Manga", "o": "Yes",
                "g": "Action, Romance", "lt": 30, "v": 2, "ls": 80
            ],
            [
                "s": "Alpha Hero", "i": "alpha", "y": "2024", "a": "Ada Lovelace",
                "ss": "Ongoing", "ps": "Complete", "t": "Manga", "o": "Yes",
                "g": "Action, Comedy", "lt": 20, "v": 1, "ls": 70
            ],
            [
                "s": "Horror Hero", "i": "horror", "y": "2024", "a": "Ada Lovelace",
                "ss": "Ongoing", "ps": "Complete", "t": "Manga", "o": "Yes",
                "g": "Action, Horror", "lt": 10, "v": 3, "ls": 60
            ],
            [
                "s": "Wrong Year Hero", "i": "old", "y": "2020", "a": "Ada Lovelace",
                "ss": "Ongoing", "ps": "Complete", "t": "Manga", "o": "Yes",
                "g": "Action", "lt": 40, "v": 4, "ls": 90
            ]
        ]
        let json = try JSONSerialization.data(withJSONObject: rows)
        let fixture = "vm.Directory = \(String(decoding: json, as: UTF8.self)); vm.GetIntValue"
        let source = installedSource(implementation: .nepNep, name: "MangaSee")
        let provider = try ReaderExtensionNativeProviderFactory.make(
            source: source,
            network: ReaderExtensionFixtureNetwork(body: Data(fixture.utf8)),
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "nepnep-filters"
        )

        var filters = try await provider.filters()
        XCTAssertEqual(
            filters.map(\.title),
            ["Years", "Author", "Scan Status", "Publish Status", "Type", "Translation", "Sort", "Genres"]
        )
        XCTAssertEqual(filters[7].children.count, 37)
        XCTAssertEqual(filters[7].children.first?.title, "Action")
        XCTAssertEqual(filters[7].children.last?.title, "Yuri")

        filters[0].value = .string("2024")
        filters[1].value = .string("Ada")
        filters[2].value = .string("Ongoing")
        filters[3].value = .string("Complete")
        filters[4].value = .string("Manga")
        filters[5].value = .string("Official Only")
        filters[6].value = .string("Alphabetically")
        filters[6].sortAscending = true
        let actionIndex = try XCTUnwrap(filters[7].children.firstIndex { $0.title == "Action" })
        let horrorIndex = try XCTUnwrap(filters[7].children.firstIndex { $0.title == "Horror" })
        filters[7].children[actionIndex].value = .number(1)
        filters[7].children[horrorIndex].value = .number(2)

        let result = try await provider.search(query: "hero", page: 1, filters: filters)
        XCTAssertEqual(result.items.map(\.title), ["Alpha Hero", "Beta Hero"])
        XCTAssertFalse(result.hasNextPage)

        let pastEnd = try await provider.search(query: "hero", page: 9, filters: filters)
        XCTAssertTrue(pastEnd.items.isEmpty, "client-side directory paging must terminate")
        XCTAssertFalse(pastEnd.hasNextPage)

        let unfiltered = try await provider.search(query: "", page: 1, filters: [])
        XCTAssertFalse(unfiltered.items.isEmpty, "an empty query matches the whole directory, as upstream")
    }

    func testMadaraSchemaAndSearchPreserveRepeatedFamilyParameters() async throws {
        let html = "<div class='c-tabs-item__content'><div class='post-title'><a href='/manga/one'>One</a></div></div>"
        let network = ReaderExtensionRecordingNetwork(body: Data(html.utf8))
        let provider = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .madara),
            network: network,
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "madara-filters"
        )
        var filters = try await provider.filters()
        XCTAssertEqual(
            filters.map(\.title),
            ["Author", "Artist", "Year of Released", "Status", "Order By", "Adult Content"]
        )
        XCTAssertEqual(filters[3].children.map(\.title), ["Completed", "Ongoing", "Canceled", "On Hold"])
        filters[0].value = .string("Ada Lovelace")
        filters[1].value = .string("Jane Doe")
        filters[2].value = .string("2024")
        filters[3].children[0].value = .bool(true)
        filters[3].children[3].value = .bool(true)
        filters[4].value = .string("views")
        filters[5].value = .string("0")
        filters.append(ReaderExtensionFilter(
            key: "GenreListFilter",
            title: "Genres",
            kind: .group,
            options: [],
            value: .string(""),
            abiType: "GenreListFilter",
            children: [
                ReaderExtensionFilter(
                    key: "genre.action", title: "Action", kind: .toggle,
                    options: [], value: .bool(true),
                    abiType: "CheckBoxFilter", abiValue: .string("action")
                ),
                ReaderExtensionFilter(
                    key: "genre.romance", title: "Romance", kind: .toggle,
                    options: [], value: .bool(true),
                    abiType: "CheckBoxFilter", abiValue: .string("romance")
                )
            ]
        ))

        _ = try await provider.search(query: "hero & rival", page: 7, filters: filters)
        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(network.lastRequest?.url),
            resolvingAgainstBaseURL: false
        ))
        let values: (String) -> [String] = { name in
            components.queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
        }
        XCTAssertEqual(components.path, "/page/7/", "WordPress paginates Madara search as /page/N/?s=")
        _ = try await provider.search(query: "hero & rival", page: 1, filters: filters)
        XCTAssertEqual(
            URLComponents(
                url: try XCTUnwrap(network.lastRequest?.url),
                resolvingAgainstBaseURL: false
            )?.path,
            "/"
        )
        XCTAssertEqual(values("s"), ["hero & rival"])
        XCTAssertEqual(values("post_type"), ["wp-manga"])
        XCTAssertEqual(values("author"), ["Ada Lovelace"])
        XCTAssertEqual(values("artist"), ["Jane Doe"])
        XCTAssertEqual(values("release"), ["2024"])
        XCTAssertEqual(values("status[]"), ["end", "on-hold"])
        XCTAssertEqual(values("m_orderby"), ["views"])
        XCTAssertEqual(values("adult"), ["0"])
        XCTAssertEqual(values("genre[]"), ["action,", "romance,"])

        let specialNetwork = ReaderExtensionRecordingNetwork(body: Data(html.utf8))
        let special = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .madara, name: "Olaoe"),
            network: specialNetwork,
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "madara-directory"
        )
        _ = try await special.popular(page: 2)
        XCTAssertEqual(
            URLComponents(
                url: try XCTUnwrap(specialNetwork.lastRequest?.url),
                resolvingAgainstBaseURL: false
            )?.path,
            "/works/page/2/"
        )
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(specialNetwork.lastRequest?.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "m_orderby" })?.value,
            "views"
        )
    }

    func testMangaReaderSchemaAndSearchUseYearxAndTriStateGenrePairs() async throws {
        let html = "<div class='listupd'><div class='bs'><div class='bsx'><a href='/manga/one' title='One'></a></div></div></div>"
        let network = ReaderExtensionRecordingNetwork(body: Data(html.utf8))
        let provider = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .mangaReader),
            network: network,
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "mangareader-filters"
        )
        var filters = try await provider.filters()
        XCTAssertEqual(filters.count, 8)
        XCTAssertEqual(filters.map(\.kind), [.separator, .text, .text, .select, .select, .select, .header, .group])
        XCTAssertEqual(filters[7].children.first?.kind, .triState)
        filters[1].value = .string("Ada")
        filters[2].value = .string("2024")
        filters[3].value = .string("ongoing")
        filters[4].value = .string("Manhwa")
        filters[5].value = .string("popular")
        filters[7].children = [
            ReaderExtensionFilter(
                key: "genre.action", title: "Action", kind: .triState,
                options: [], value: .number(1),
                abiType: "TriStateFilter", abiValue: .string("action")
            ),
            ReaderExtensionFilter(
                key: "genre.romance", title: "Romance", kind: .triState,
                options: [], value: .number(1),
                abiType: "TriStateFilter", abiValue: .string("romance")
            ),
            ReaderExtensionFilter(
                key: "genre.horror", title: "Horror", kind: .triState,
                options: [], value: .number(2),
                abiType: "TriStateFilter", abiValue: .string("horror")
            )
        ]

        _ = try await provider.search(query: "hero", page: 3, filters: filters)
        let components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(network.lastRequest?.url),
            resolvingAgainstBaseURL: false
        ))
        let values: (String) -> [String] = { name in
            components.queryItems?.filter { $0.name == name }.compactMap(\.value) ?? []
        }
        XCTAssertEqual(components.path, "/")
        XCTAssertEqual(values("s"), ["hero"])
        XCTAssertEqual(values("page"), ["3"])
        XCTAssertEqual(values("author"), ["Ada"])
        XCTAssertEqual(values("yearx"), ["2024"])
        XCTAssertEqual(values("status"), ["ongoing"])
        XCTAssertEqual(values("type"), ["Manhwa"])
        XCTAssertEqual(values("order"), ["popular"])
        XCTAssertEqual(values("genres[]"), ["action,romance,", "-horror,"])

        let sushiNetwork = ReaderExtensionRecordingNetwork(body: Data(html.utf8))
        let sushi = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .mangaReader, name: "Sushi-Scan"),
            network: sushiNetwork,
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "sushi-scan"
        )
        let sushiFilters = try await sushi.filters()
        XCTAssertTrue(sushiFilters.isEmpty)
        _ = try await sushi.search(query: "hero", page: 2, filters: [])
        XCTAssertEqual(
            URLComponents(
                url: try XCTUnwrap(sushiNetwork.lastRequest?.url),
                resolvingAgainstBaseURL: false
            )?.path,
            "/page/2/"
        )
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(sushiNetwork.lastRequest?.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "s" })?.value,
            "hero"
        )
    }

    func testMangaBoxFiltersAndCatalogNameSelectMangairoRoutes() async throws {
        let html = "<div class='genres-item'><h3><a href='/manga/one'>One</a></h3></div>"
        let network = ReaderExtensionRecordingNetwork(body: Data(html.utf8))
        let provider = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .mangaBox, name: "Mangabat"),
            network: network,
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "mangabox-filters"
        )
        var filters = try await provider.filters()
        XCTAssertEqual(filters.map(\.kind), [.header, .select, .select, .select])
        XCTAssertEqual(filters[3].options.first?.value, "all")
        XCTAssertEqual(filters[3].options.last?.value, "yuri")
        filters[1].value = .string("topview")
        filters[2].value = .string("completed")
        filters[3].value = .string("action")

        _ = try await provider.search(query: "", page: 3, filters: filters)
        var components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(network.lastRequest?.url),
            resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(components.path, "/genre/action")
        XCTAssertEqual(
            components.queryItems,
            [
                URLQueryItem(name: "type", value: "topview"),
                URLQueryItem(name: "state", value: "completed"),
                URLQueryItem(name: "page", value: "3")
            ]
        )

        _ = try await provider.search(query: "Cà Phê!", page: 4, filters: filters)
        components = try XCTUnwrap(URLComponents(
            url: try XCTUnwrap(network.lastRequest?.url),
            resolvingAgainstBaseURL: false
        ))
        XCTAssertEqual(components.path, "/search/story/ca_phe")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "page", value: "4")])

        let mangairoNetwork = ReaderExtensionRecordingNetwork(body: Data(html.utf8))
        let mangairo = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .mangaBox, name: "Mangairo"),
            network: mangairoNetwork,
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "mangairo-route"
        )
        let mangairoFilters = try await mangairo.filters()
        XCTAssertTrue(mangairoFilters.isEmpty)
        _ = try await mangairo.popular(page: 2)
        XCTAssertEqual(
            mangairoNetwork.lastRequest?.url.path,
            "/manga-list/type-topview/ctg-all/state-all/page-2"
        )
        _ = try await mangairo.search(query: "Hero Name", page: 5, filters: [])
        XCTAssertEqual(mangairoNetwork.lastRequest?.url.path, "/list/search/hero_name")
    }

    func testMMRCMSSearchParsesBoundedJSONSuggestionsAndFamilyPaths() async throws {
        let body = Data(#"{"suggestions":[{"value":"Owned Hero","data":"owned-hero"}]}"#.utf8)
        let cases = [
            ("Scan VF", "/owned-hero"),
            ("Read Comics Online", "/comic/owned-hero"),
            ("مانجا اون لاين", "/manga/owned-hero")
        ]
        for (name, expectedPath) in cases {
            let network = ReaderExtensionRecordingNetwork(body: body)
            let provider = try ReaderExtensionNativeProviderFactory.make(
                source: installedSource(implementation: .mmrcms, name: name),
                network: network,
                approvedDomains: [publicBaseURL.host!],
                consentScopeID: "mmrcms-suggestions"
            )
            let result = try await provider.search(query: "owned & hero", page: 8, filters: [])
            XCTAssertEqual(result.items.map(\.title), ["Owned Hero"])
            XCTAssertEqual(result.items.first?.url?.path, expectedPath)
            XCTAssertEqual(
                result.items.first?.coverURL?.path,
                "/uploads/manga/owned-hero/cover/cover_250x350.jpg"
            )
            XCTAssertFalse(result.hasNextPage)
            let requestComponents = try XCTUnwrap(URLComponents(
                url: try XCTUnwrap(network.lastRequest?.url),
                resolvingAgainstBaseURL: false
            ))
            XCTAssertEqual(requestComponents.path, "/search")
            XCTAssertEqual(
                requestComponents.queryItems,
                [URLQueryItem(name: "query", value: "owned & hero")]
            )
        }

        let emptyNetwork = ReaderExtensionRecordingNetwork(body: body)
        let provider = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .mmrcms, name: "Scan VF"),
            network: emptyNetwork,
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "mmrcms-empty"
        )
        let emptyResult = try await provider.search(query: "", page: 1, filters: [])
        XCTAssertTrue(emptyResult.items.isEmpty)
        XCTAssertNil(emptyNetwork.lastRequest)
    }

    func testNativeHTMLPaginationRequiresConcreteNextLink() async throws {
        let row = "<div class='page-item-detail'><div class='post-title'><a href='/manga/one'>One</a></div></div>"
        let withNext = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .madara),
            network: ReaderExtensionFixtureNetwork(body: Data("\(row)<a rel='next' href='/manga/page/2'>Next</a>".utf8)),
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "native-next"
        )
        let firstPage = try await withNext.popular(page: 1)
        XCTAssertTrue(firstPage.hasNextPage)

        let finalPage = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .madara),
            network: ReaderExtensionFixtureNetwork(body: Data(row.utf8)),
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "native-final"
        )
        let lastPage = try await finalPage.popular(page: 1)
        XCTAssertFalse(lastPage.hasNextPage)
    }

    func testNativeProvidersRejectNestedChapterListingAndTagAmplification() async throws {
        func expectContentTooLarge(
            _ label: String,
            operation: () async throws -> Void
        ) async {
            do {
                try await operation()
                XCTFail("\(label) retained an over-budget native result")
            } catch let error as ReaderExtensionError {
                XCTAssertEqual(error, .contentTooLarge, label)
            } catch {
                XCTFail("\(label) returned an unexpected error: \(error)")
            }
        }

        // Each selected ancestor resolves the same individually valid inner
        // title. The HTML stays small while the naive retained result would
        // exceed two MiB, exercising aggregate accounting rather than only a
        // single-field limit.
        let repeatedTitle = String(repeating: "x", count: 15_000)
        let depth = 150
        let listingFixtures: [(ReaderExtensionImplementation, String, String?)] = [
            (
                .madara,
                String(repeating: "<div class='page-item-detail'>", count: depth)
                    + "<div class='post-title'><a href='/manga/one'>\(repeatedTitle)</a></div>"
                    + String(repeating: "</div>", count: depth),
                nil
            ),
            (
                .mangaReader,
                "<div class='listupd'><div class='bs'>"
                    + String(repeating: "<div class='bsx'>", count: depth)
                    + "<a href='/manga/one'>\(repeatedTitle)</a>"
                    + String(repeating: "</div>", count: depth)
                    + "</div></div>",
                nil
            ),
            (
                .mangaBox,
                String(repeating: "<div class='genres-item'>", count: depth)
                    + "<h3><a href='/manga/one'>\(repeatedTitle)</a></h3>"
                    + String(repeating: "</div>", count: depth),
                "{\"urlStyle\":\"pathPages\"}"
            ),
            (
                .mmrcms,
                String(repeating: "<div class='chapter-container'>", count: depth)
                    + "<div class='media-heading'><a href='/manga/one'>\(repeatedTitle)</a></div>"
                    + String(repeating: "</div>", count: depth),
                nil
            )
        ]
        for (implementation, html, parameters) in listingFixtures {
            let provider = try ReaderExtensionNativeProviderFactory.make(
                source: installedSource(implementation: implementation, additionalParameters: parameters),
                network: ReaderExtensionFixtureNetwork(body: Data(html.utf8)),
                approvedDomains: [publicBaseURL.host!],
                consentScopeID: "native-budget"
            )
            await expectContentTooLarge("nested listing \(implementation.rawValue)") {
                _ = try await provider.popular(page: 1)
            }
        }

        let nepRows = (0..<depth).map { index in
            "{\"s\":\"\(repeatedTitle)\",\"i\":\"item-\(index)\",\"vm\":1}"
        }.joined(separator: ",")
        let nepHTML = "vm.Directory = [\(nepRows)]; vm.GetIntValue"
        let nepProvider = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .nepNep),
            network: ReaderExtensionFixtureNetwork(body: Data(nepHTML.utf8)),
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "native-budget"
        )
        // Directory paging is the aggregate bound here: one page retains at
        // most a page's worth of bounded rows, and the remainder stays
        // reachable instead of amplifying a single result.
        let nepPage = try await nepProvider.popular(page: 1)
        XCTAssertEqual(nepPage.items.count, 60)
        XCTAssertTrue(nepPage.hasNextPage)

        let nestedChapterHTML = "<div class='chapter-list'>"
            + String(repeating: "<div class='row'>", count: depth)
            + "<a href='/chapter/one'>\(repeatedTitle)</a>"
            + String(repeating: "</div>", count: depth)
            + "</div>"
        let chapterProvider = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .mangaBox),
            network: ReaderExtensionFixtureNetwork(body: Data(nestedChapterHTML.utf8)),
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "native-budget"
        )
        await expectContentTooLarge("nested chapter rows") {
            _ = try await chapterProvider.chapters(itemKey: "/manga/one")
        }

        let oversizedTag = String(repeating: "g", count: 4 * 1_024 + 1)
        let tagHTML = "<h1>Owned</h1><div class='genres-content'><a><span>\(oversizedTag)</span></a></div>"
        let tagProvider = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .madara),
            network: ReaderExtensionFixtureNetwork(body: Data(tagHTML.utf8)),
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "native-budget"
        )
        await expectContentTooLarge("nested genre text") {
            _ = try await tagProvider.detail(itemKey: "/manga/one")
        }
    }

    @MainActor
    func testPopularOnlySourceKeepsItsHomeSectionWithoutCallingLatest() async throws {
        var source = installedSource(implementation: .javascript)
        source.runtimeCapabilities = [.popular, .search, .detail, .pages]
        let provider = ReaderExtensionPopularOnlyFixtureProvider(source: source)
        let outcome = await MangaHomeViewModel.readerExtensionHomeSections(
            provider: provider,
            sourceID: source.id
        )
        XCTAssertEqual(outcome.sections.map(\.title), ["Popular"])
        XCTAssertEqual(outcome.sections.first?.items.first?.title, "Owned Popular")
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(provider.latestCallCount, 0)
    }

    func testNestedFilterDiscriminatorsValuesAndSortStateRoundTrip() throws {
        let rows: [[String: Any]] = [[
            "type_name": "HeaderFilter",
            "type": "catalog-heading",
            "name": "Catalog filters"
        ], [
            "type_name": "SeparatorFilter",
            "type": "catalog-separator"
        ], [
            "type_name": "GroupFilter",
            "type": "GenreFilter",
            "name": "Genres",
            "state": [[
                "type_name": "TriState",
                "name": "Action",
                "value": "action"
            ], [
                "type_name": "CheckBox",
                "name": "Licensed",
                "value": "licensed"
            ]]
        ], [
            "type_name": "SortFilter",
            "type": "SortFilter",
            "name": "Sort",
            "state": ["type_name": "SortState", "index": 1, "ascending": false],
            "values": [
                ["type_name": "SelectOption", "name": "Updated", "value": "updated"],
                ["type_name": "SelectOption", "name": "Relevance", "value": "relevance"],
                ["type_name": "SelectOption", "name": "Title", "value": "title"]
            ]
        ], [
            "type_name": "SelectFilter",
            "type": "StatusFilter",
            "name": "Status",
            "state": 1,
            "values": [
                ["type_name": "SelectOption", "name": "All", "value": ""],
                ["type_name": "SelectOption", "name": "Ongoing", "value": "ongoing"]
            ]
        ]]
        var filters = JavaScriptReaderProvider.parseFilters(rows)
        XCTAssertEqual(filters[0].kind, .header)
        XCTAssertEqual(filters[1].kind, .separator)
        XCTAssertEqual(filters[2].kind, .group)
        XCTAssertEqual(filters[2].abiType, "GenreFilter")
        XCTAssertEqual(filters[2].abiTypeName, "GroupFilter")
        XCTAssertEqual(filters[2].children.first?.kind, .triState)
        XCTAssertEqual(filters[2].children.first?.abiValue, .string("action"))
        XCTAssertEqual(filters[2].children.dropFirst().first?.abiValue, .string("licensed"))
        XCTAssertEqual(filters[3].kind, .sort)
        XCTAssertEqual(filters[3].value, .string("relevance"))
        XCTAssertEqual(filters[3].sortAscending, false)
        XCTAssertEqual(filters[4].kind, .select)
        XCTAssertEqual(filters[4].value, .string("ongoing"))

        filters[2].children[0].value = .number(2)
        filters[2].children[1].value = .bool(true)
        // Select and sort selections are positional: option values are not
        // unique across a source's option list, so the index is authoritative
        // and `value` is carried for display. Mutating one without the other
        // is not a selection.
        filters[3].value = .string("title")
        filters[3].selectedOptionIndex = 2
        filters[3].sortAscending = true
        filters[4].value = .string("")
        filters[4].selectedOptionIndex = 0
        let literal = ReaderExtensionJavaScriptOperation.filterLiteral(filters)
        let decoded = try JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [[String: Any]]
        let header = try XCTUnwrap(decoded?[0])
        XCTAssertEqual(header["type_name"] as? String, "HeaderFilter")
        XCTAssertEqual(header["name"] as? String, "Catalog filters")
        XCTAssertNil(header["state"])
        XCTAssertNil(header["values"])
        let separator = try XCTUnwrap(decoded?[1])
        XCTAssertEqual(separator["type_name"] as? String, "SeparatorFilter")
        XCTAssertNil(separator["name"])
        XCTAssertNil(separator["state"])
        XCTAssertNil(separator["values"])

        let group = try XCTUnwrap(decoded?[2])
        XCTAssertEqual(group["type"] as? String, "GenreFilter")
        XCTAssertEqual(group["type_name"] as? String, "GroupFilter")
        let children = try XCTUnwrap(group["state"] as? [[String: Any]])
        XCTAssertEqual(children[0]["type_name"] as? String, "TriState")
        XCTAssertEqual(children[0]["value"] as? String, "action")
        XCTAssertEqual((children[0]["state"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(children[1]["type_name"] as? String, "CheckBox")
        XCTAssertEqual(children[1]["value"] as? String, "licensed")
        XCTAssertEqual(children[1]["state"] as? Bool, true)

        let sort = try XCTUnwrap(decoded?[3])
        XCTAssertEqual(sort["type"] as? String, "SortFilter")
        XCTAssertEqual(sort["type_name"] as? String, "SortFilter")
        XCTAssertEqual((sort["values"] as? [[String: Any]])?.first?["type_name"] as? String, "SelectOption")
        let sortState = try XCTUnwrap(sort["state"] as? [String: Any])
        XCTAssertEqual(sortState["type_name"] as? String, "SortState")
        XCTAssertEqual((sortState["index"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(sortState["ascending"] as? Bool, true)
        let select = try XCTUnwrap(decoded?[4])
        XCTAssertEqual(select["type"] as? String, "StatusFilter")
        XCTAssertEqual(select["type_name"] as? String, "SelectFilter")
        XCTAssertEqual((select["state"] as? NSNumber)?.intValue, 0)
    }

    func testSelectIdentityIsPositionalSoOptionsSharingAValueStayDistinct() {
        let duplicated = ReaderExtensionFilter(
            key: "sort",
            title: "Sort",
            kind: .sort,
            options: (0..<9).map {
                ReaderExtensionFilterOption(label: "Option \($0)", value: $0 < 7 ? "desc" : "asc")
            },
            value: .string("desc"),
            abiState: .object(["index": .number(0), "ascending": .bool(false)]),
            sortAscending: false,
            selectedOptionIndex: 0
        )

        var selected = duplicated
        selected.selectedOptionIndex = 5
        XCTAssertEqual(
            selected.resolvedOptionIndex,
            5,
            "Comix declares nine sort options over two value strings; matching by value collapses seven of them"
        )

        var valueOnly = duplicated
        valueOnly.value = .string("asc")
        XCTAssertEqual(
            valueOnly.resolvedOptionIndex,
            0,
            "value is display state; a selection that does not move the index is not a selection"
        )

        var legacy = duplicated
        legacy.selectedOptionIndex = nil
        legacy.value = .string("asc")
        XCTAssertEqual(
            legacy.resolvedOptionIndex,
            7,
            "trees persisted before an index was recorded must still resolve through their value"
        )

        var outOfRange = duplicated
        outOfRange.selectedOptionIndex = 99
        outOfRange.value = .string("asc")
        XCTAssertEqual(outOfRange.resolvedOptionIndex, 7)

        var unrepresentable = duplicated
        unrepresentable.selectedOptionIndex = nil
        unrepresentable.value = .number(Double.greatestFiniteMagnitude)
        XCTAssertNil(
            unrepresentable.resolvedOptionIndex,
            "provider-supplied finite numbers outside Int must be rejected without trapping"
        )
    }

    func testMangayomiAdvancedFiltersReachSearchWithCanonicalStates() async throws {
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) {
            const headerIsPassive = filters[0].type_name === 'HeaderFilter' && !('state' in filters[0]);
            const separatorIsPassive = filters[1].type_name === 'SeparatorFilter' && !('state' in filters[1]);
            const group = filters[4].state;
            const proof = [
              filters.length,
              headerIsPassive,
              separatorIsPassive,
              filters[2].state,
              filters[3].state.type_name,
              filters[3].state.index,
              filters[3].state.ascending,
              group[0].state,
              group[1].state,
              group[2].state,
              group[3].state,
              filters[5].state
            ].join('|');
            return {list: [{name: proof, url: '/manga/proof'}], hasNextPage: false};
          }
          async getDetail(url) { return {name: 'Owned', chapters: []}; }
          async getPageList(url) { return []; }
          getFilterList() {
            return [
              {type_name: 'HeaderFilter', type: 'heading', name: 'Browse'},
              {type_name: 'SeparatorFilter', type: 'separator'},
              {type_name: 'SelectFilter', type: 'status', name: 'Status', values: [
                {type_name: 'SelectOption', name: 'All', value: ''},
                {type_name: 'SelectOption', name: 'Ongoing', value: 'ongoing'}
              ]},
              {type_name: 'SortFilter', type: 'sort', name: 'Sort', values: [
                {type_name: 'SelectOption', name: 'Relevance', value: 'relevance'},
                {type_name: 'SelectOption', name: 'Updated', value: 'updated'}
              ]},
              {type_name: 'GroupFilter', type: 'tags', name: 'Tags', state: [
                {type_name: 'SelectFilter', type: 'include-mode', name: 'Include mode', state: 0, values: [
                  {type_name: 'SelectOption', name: 'AND', value: 'include=AND'},
                  {type_name: 'SelectOption', name: 'OR', value: 'include=OR'}
                ]},
                {type_name: 'SelectFilter', type: 'exclude-mode', name: 'Exclude mode', state: 1, values: [
                  {type_name: 'SelectOption', name: 'AND', value: 'exclude=AND'},
                  {type_name: 'SelectOption', name: 'OR', value: 'exclude=OR'}
                ]},
                {type_name: 'CheckBox', name: 'Licensed', value: 'licensed'},
                {type_name: 'TriState', name: 'Action', value: 'action'}
              ]},
              {type_name: 'TextFilter', type: 'author', name: 'Author'}
            ];
          }
        }
        """.utf8)
        let provider = try JavaScriptReaderProvider(
            source: installedSource(implementation: .javascript),
            scriptData: script,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            consentScopeID: "advanced-filter-round-trip",
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )

        var filters = try await provider.filters()
        XCTAssertEqual(filters.map(\.kind), [.header, .separator, .select, .sort, .group, .text])
        XCTAssertEqual(filters[2].value, .string(""))
        XCTAssertEqual(filters[3].value, .string("relevance"))
        XCTAssertEqual(filters[3].sortAscending, false)
        XCTAssertEqual(filters[4].children[0].abiState, .number(0))
        XCTAssertEqual(filters[4].children[1].abiState, .number(1))
        XCTAssertEqual(filters[4].children[0].value, .string("include=AND"))
        XCTAssertEqual(filters[4].children[1].value, .string("exclude=OR"))
        filters[2].value = .string("ongoing")
        filters[2].selectedOptionIndex = 1
        filters[3].value = .string("updated")
        filters[3].selectedOptionIndex = 1
        filters[3].sortAscending = true
        filters[4].children[2].value = .bool(true)
        filters[4].children[3].value = .number(2)
        filters[5].value = .string("owned author")

        let result = try await provider.search(query: "", page: 1, filters: filters)
        XCTAssertEqual(
            result.items.first?.title,
            "6|true|true|1|SortState|1|true|0|1|true|2|owned author"
        )
    }

    func testMangaDexMangayomiAdvancedFilterSchemaAndSearchRoundTrip() async throws {
        let rows = mangaDexAdvancedFilterRows()
        let schemaData = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        let schemaJSON = try XCTUnwrap(String(data: schemaData, encoding: .utf8))
        let script = Data("""
        class DefaultExtension extends MProvider {
          constructor() { super(); this.client = new Client(); }
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) {
            let url = `${this.source.baseUrl}/manga?includes[]=cover_art&offset=${20 * (page - 1)}&limit=20&title=${query}`;
            filters.forEach(filter => {
              if (filter.type === "HasAvailableChaptersFilter") {
                if (filter.state) {
                  url += `&hasAvailableChapters=true&availableTranslatedLanguage[]=${this.source.lang}`;
                }
              } else if (filter.type === "OriginalLanguageList"
                      || filter.type === "ContentRatingList"
                      || filter.type === "DemographicList"
                      || filter.type === "StatusList") {
                filter.state.filter(value => value.state).forEach(value => { url += `&${value.value}`; });
              } else if (filter.type === "SortFilter") {
                const value = filter.state.ascending ? "asc" : "desc";
                url += `&order[${filter.values[filter.state.index].value}]=${value}`;
              } else if (filter.type === "TagsFilter") {
                filter.state.forEach(tag => { url += `&${tag.values[tag.state].value}`; });
              } else if (filter.type === "FormatFilter"
                      || filter.type === "GenreFilter"
                      || filter.type === "ThemeFilter") {
                filter.state.filter(value => value.state === 1).forEach(value => {
                  url += `&includedTags[]=${value.value}`;
                });
                filter.state.filter(value => value.state === 2).forEach(value => {
                  url += `&excludedTags[]=${value.value}`;
                });
              }
            });
            const response = await this.client.get(url, {});
            const data = JSON.parse(response.body).data;
            return {list: data.map(item => ({name: item.name, link: item.link})), hasNextPage: false};
          }
          async getDetail(url) { return {name: "Owned", chapters: []}; }
          async getPageList(url) { return []; }
          getFilterList() { return \(schemaJSON); }
        }
        """.utf8)
        let network = ReaderExtensionRecordingNetwork(
            body: Data(#"{"data":[{"name":"Naruto","link":"/manga/naruto"}]}"#.utf8)
        )
        let provider = try JavaScriptReaderProvider(
            source: installedSource(implementation: .javascript),
            scriptData: script,
            network: network,
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "mangadex-advanced-filter-round-trip",
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )

        var filters = try await provider.filters()
        XCTAssertEqual(filters.count, 11)
        XCTAssertEqual(
            filters.map(\.title),
            [
                "Has available chapters", "Original language", "Content rating",
                "Publication demographic", "Status", "Sort", "Tags mode", "Content",
                "Format", "Genre", "Theme"
            ]
        )
        XCTAssertEqual(
            filters.map(\.abiType),
            [
                "HasAvailableChaptersFilter", "OriginalLanguageList", "ContentRatingList",
                "DemographicList", "StatusList", "SortFilter", "TagsFilter", "ContentsFilter",
                "FormatFilter", "GenreFilter", "ThemeFilter"
            ]
        )
        XCTAssertEqual(
            filters.map(\.kind),
            [.toggle, .group, .group, .group, .group, .sort, .group, .group, .group, .group, .group]
        )
        XCTAssertEqual(filters.map { $0.children.count }, [0, 3, 2, 5, 4, 0, 2, 2, 12, 25, 36])
        XCTAssertEqual(filters.reduce(0) { $0 + 1 + $1.children.count }, 102)
        XCTAssertEqual(filters[0].value, .bool(false))
        XCTAssertEqual(filters[1].children.map(\.value), Array(repeating: .bool(false), count: 3))
        XCTAssertEqual(filters[2].children.map(\.value), [.bool(true), .bool(true)])
        XCTAssertEqual(filters[3].children.map(\.value), Array(repeating: .bool(false), count: 5))
        XCTAssertEqual(filters[4].children.map(\.value), Array(repeating: .bool(false), count: 4))
        XCTAssertEqual(filters[5].value, .string("relevance"))
        XCTAssertEqual(filters[5].sortAscending, false)
        XCTAssertEqual(filters[6].children.map(\.value), [
            .string("includedTagsMode=AND"),
            .string("excludedTagsMode=OR")
        ])
        XCTAssertEqual(
            filters[7...10].flatMap(\.children).map(\.value),
            Array(repeating: .number(0), count: 75)
        )

        filters[0].value = .bool(true)
        filters[1].children[0].value = .bool(true)
        filters[2].children[0].value = .bool(false)
        filters[3].children[1].value = .bool(true)
        filters[4].children[1].value = .bool(true)
        filters[5].value = .string("rating")
        filters[5].selectedOptionIndex = 7
        filters[5].sortAscending = true
        filters[6].children[0].value = .string("includedTagsMode=OR")
        filters[6].children[0].selectedOptionIndex = 1
        filters[6].children[1].value = .string("excludedTagsMode=AND")
        filters[6].children[1].selectedOptionIndex = 0
        filters[7].children[0].value = .number(1)
        filters[8].children[0].value = .number(2)
        filters[9].children[0].value = .number(1)
        filters[10].children[0].value = .number(2)

        let literal = ReaderExtensionJavaScriptOperation.filterLiteral(filters)
        let decoded = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [[String: Any]]
        )
        XCTAssertEqual(decoded.count, 11)
        XCTAssertEqual(decoded.map { $0["type"] as? String }, filters.map(\.abiType))
        let sortState = try XCTUnwrap(decoded[5]["state"] as? [String: Any])
        XCTAssertEqual((sortState["index"] as? NSNumber)?.intValue, 7)
        XCTAssertEqual(sortState["ascending"] as? Bool, true)
        let tagModes = try XCTUnwrap(decoded[6]["state"] as? [[String: Any]])
        XCTAssertEqual((tagModes[0]["state"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((tagModes[1]["state"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(((decoded[7]["state"] as? [[String: Any]])?[0]["state"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(((decoded[8]["state"] as? [[String: Any]])?[0]["state"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(((decoded[9]["state"] as? [[String: Any]])?[0]["state"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(((decoded[10]["state"] as? [[String: Any]])?[0]["state"] as? NSNumber)?.intValue, 2)

        let result = try await provider.search(query: "Naruto", page: 1, filters: filters)
        XCTAssertEqual(result.items.map(\.title), ["Naruto"])
        let request = try XCTUnwrap(network.lastRequest)
        let queryItems = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
        let queryPairs = queryItems.map { "\($0.name)=\($0.value ?? "")" }
        XCTAssertTrue(queryPairs.contains("title=Naruto"))
        XCTAssertTrue(queryPairs.contains("hasAvailableChapters=true"))
        XCTAssertTrue(queryPairs.contains("availableTranslatedLanguage[]=en"))
        XCTAssertTrue(queryPairs.contains("originalLanguage[]=ja"))
        XCTAssertFalse(queryPairs.contains("contentRating[]=safe"))
        XCTAssertTrue(queryPairs.contains("contentRating[]=suggestive"))
        XCTAssertTrue(queryPairs.contains("publicationDemographic[]=shounen"))
        XCTAssertTrue(queryPairs.contains("status[]=completed"))
        XCTAssertTrue(queryPairs.contains("order[rating]=asc"))
        XCTAssertTrue(queryPairs.contains("includedTagsMode=OR"))
        XCTAssertTrue(queryPairs.contains("excludedTagsMode=AND"))
        XCTAssertTrue(queryPairs.contains("excludedTags[]=b11fda93-8f1d-4bef-b2ed-8803d3733170"))
        XCTAssertTrue(queryPairs.contains("includedTags[]=391b0423-d847-456f-aff0-8b0cfc03066b"))
        XCTAssertTrue(queryPairs.contains("excludedTags[]=e64f6742-c834-471d-8d72-dd51fc02b835"))
    }

    func testPreferenceBootstrapToleratesOnlyExplicitNotImplementedContract() async throws {
        let unavailablePreferences = Data(requiredMangaScript(
            preferenceBody: "throw new Error('getSourcePreferences not implemented');"
        ).utf8)
        let source = installedSource(implementation: .javascript)
        let validation = try await ReaderExtensionJavaScriptRuntime.bootstrapValidate(
            scriptData: unavailablePreferences,
            source: source
        )
        XCTAssertFalse(validation.capabilities.contains(.preferences))
        XCTAssertNil(validation.preferenceSchemaFingerprint)
        XCTAssertTrue(validation.secretPreferenceKeys.isEmpty)

        let preferenceData = try await ReaderExtensionJavaScriptRuntime.execute(
            scriptData: unavailablePreferences,
            source: source,
            operation: .preferences,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )
        XCTAssertEqual((try JSONSerialization.jsonObject(with: preferenceData) as? [Any])?.count, 0)

        let genuineFailure = Data(requiredMangaScript(
            preferenceBody: "throw new Error('preference initialization failed');"
        ).utf8)
        let genuineFailureDigest = SHA256.hash(data: genuineFailure).map { String(format: "%02x", $0) }.joined()
        defer {
            ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
                false,
                sourceID: source.id,
                digest: genuineFailureDigest
            )
        }
        do {
            _ = try await ReaderExtensionJavaScriptRuntime.bootstrapValidate(
                scriptData: genuineFailure,
                source: source
            )
            XCTFail("a genuine preference initialization failure was hidden")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .runtimeIntegrityFailed("preference schema initialization"))
        }
    }

    func testMangayomiGetHeadersABIIsBoundedAndKeepsCredentialsOriginBound() async throws {
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getHeaders() {
            const preferences = new SharedPreferences();
            return {
              'User-Agent': 'Owned Fixture/' + preferences.getString('variant', 'fallback'),
              'Authorization': 'Bearer owned-secret',
              'Cookie': 'session=must-never-survive',
              'X-Source-Proof': 'owned-origin-bound'
            };
          }
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: 'Owned Fixture', chapters: []}; }
          async getPageList(url) { return []; }
        }
        """.utf8)
        let provider = try JavaScriptReaderProvider(
            source: installedSource(implementation: .javascript),
            scriptData: script,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            consentScopeID: "owned-resource-headers",
            preferenceStore: ReaderExtensionInMemoryPreferenceStore(
                values: ["variant": .string("2.0")]
            )
        )

        let headers = try await provider.resourceHeaders()
        XCTAssertEqual(headers["User-Agent"], "Owned Fixture/2.0")
        XCTAssertEqual(headers["Authorization"], "Bearer owned-secret")
        XCTAssertEqual(headers["X-Source-Proof"], "owned-origin-bound")
        XCTAssertNil(headers["Cookie"], "Cookie must remain owned by the scoped Keychain transport")

        let malformedScript = Data("""
        class DefaultExtension extends MProvider {
          getHeaders() { return {'User-Agent': {nested: 'invalid'}}; }
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: 'Owned Fixture', chapters: []}; }
          async getPageList(url) { return []; }
        }
        """.utf8)
        let malformedProvider = try JavaScriptReaderProvider(
            source: installedSource(implementation: .javascript),
            scriptData: malformedScript,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            consentScopeID: "owned-malformed-resource-headers",
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )
        do {
            _ = try await malformedProvider.resourceHeaders()
            XCTFail("non-string resource headers were accepted")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .resultInvalid("resource header values must be strings"))
        }
    }

    func testRuntimePromiseDrainAllowsMangayomiOperationLongerThanTwoSeconds() async throws {
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) {
            const response = await new Client().get(this.source.baseUrl + '/slow');
            await Promise.resolve();
            return {list: [], hasNextPage: false, status: response.statusCode};
          }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: 'Owned Fixture', chapters: []}; }
          async getPageList(url) { return []; }
        }
        """.utf8)
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await ReaderExtensionJavaScriptRuntime.execute(
            scriptData: script,
            source: installedSource(implementation: .javascript),
            operation: .popular(1),
            network: ReaderExtensionDelayedFixtureNetwork(
                delayNanoseconds: 2_200_000_000,
                body: Data("{}".utf8)
            ),
            approvedDomains: [publicBaseURL.host!],
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 2.0)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual((object["status"] as? NSNumber)?.intValue, 200)
    }

    func testProviderRollsBackOnlyTypedRuntimeIntegrityFailures() async throws {
        var integrityCallbacks: [
            (ReaderExtensionSourceID, String?, ReaderExtensionRuntimeFailureAttribution)
        ] = []
        let source = installedSource(implementation: .javascript)
        let preferenceFailure = Data(requiredMangaScript(
            preferenceBody: "throw new Error('owned invalid preference schema');"
        ).utf8)
        let preferenceFailureDigest = SHA256.hash(data: preferenceFailure).map { String(format: "%02x", $0) }.joined()
        let sourceInitializationFailure = Data("""
        class DefaultExtension extends MProvider {}
        throw new Error('owned source initialization failure');
        """.utf8)
        let sourceInitializationFailureDigest = SHA256.hash(data: sourceInitializationFailure)
            .map { String(format: "%02x", $0) }.joined()
        defer {
            ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
                false,
                sourceID: source.id,
                digest: preferenceFailureDigest
            )
            ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
                false,
                sourceID: source.id,
                digest: sourceInitializationFailureDigest
            )
        }
        let preferenceProvider = try JavaScriptReaderProvider(
            source: source,
            scriptData: preferenceFailure,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            consentScopeID: "owned-integrity-callback",
            preferenceStore: ReaderExtensionInMemoryPreferenceStore(),
            onRuntimeIntegrityFailure: { integrityCallbacks.append(($0, $1, $2)) }
        )
        do {
            _ = try await preferenceProvider.popular(page: 1)
            XCTFail("preference-schema initialization failure was not surfaced")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .runtimeIntegrityFailed("preference schema initialization"))
        }
        XCTAssertEqual(integrityCallbacks.count, 1)
        XCTAssertEqual(integrityCallbacks.first?.0, source.id)
        XCTAssertEqual(
            integrityCallbacks.first?.2,
            .sourceAuthored,
            "a preference schema the source itself wrote must not be reported as an Eclipse integrity failure"
        )

        let providerFailure = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { throw new Error('owned provider outage'); }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: 'Owned Fixture', chapters: []}; }
          async getPageList(url) { return []; }
        }
        """.utf8)
        let ordinaryProvider = try JavaScriptReaderProvider(
            source: source,
            scriptData: providerFailure,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            consentScopeID: "owned-provider-error",
            preferenceStore: ReaderExtensionInMemoryPreferenceStore(),
            onRuntimeIntegrityFailure: { integrityCallbacks.append(($0, $1, $2)) }
        )
        do {
            _ = try await ordinaryProvider.popular(page: 1)
            XCTFail("provider rejection was hidden")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .runtimeFailed("source operation rejected"))
        }
        XCTAssertEqual(
            integrityCallbacks.count,
            1,
            "ordinary provider/HTTP Promise rejection must not roll back verified code"
        )

        let initializationProvider = try JavaScriptReaderProvider(
            source: source,
            scriptData: sourceInitializationFailure,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            consentScopeID: "owned-source-initialization",
            preferenceStore: ReaderExtensionInMemoryPreferenceStore(),
            onRuntimeIntegrityFailure: { integrityCallbacks.append(($0, $1, $2)) }
        )
        do {
            _ = try await initializationProvider.popular(page: 1)
            XCTFail("source initialization integrity failure was hidden")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .runtimeIntegrityFailed("source initialization"))
        }
        XCTAssertEqual(integrityCallbacks.count, 2)
        XCTAssertEqual(
            integrityCallbacks.last?.2,
            .sourceAuthored,
            "a top-level throw in the extension's own code is the source's defect, not tampering"
        )
    }

    func testRuntimeIntegrityFailureSynchronouslyQuarantinesExactDigest() async throws {
        let script = Data("""
        class DefaultExtension extends MProvider {}
        throw new Error('owned source initialization failure');
        """.utf8)
        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        var source = installedSource(implementation: .javascript)
        source.activeContentDigest = digest
        defer {
            ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
                false,
                sourceID: source.id,
                digest: digest
            )
        }

        do {
            _ = try await ReaderExtensionJavaScriptRuntime.execute(
                scriptData: script,
                source: source,
                operation: .popular(1),
                network: ReaderExtensionDenyNetworkClient(),
                approvedDomains: [],
                preferenceStore: ReaderExtensionInMemoryPreferenceStore()
            )
            XCTFail("source initialization integrity failure was not surfaced")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .runtimeIntegrityFailed("source initialization"))
        }

        do {
            _ = try await ReaderExtensionJavaScriptRuntime.execute(
                scriptData: script,
                source: source,
                operation: .popular(1),
                network: ReaderExtensionDenyNetworkClient(),
                approvedDomains: [],
                preferenceStore: ReaderExtensionInMemoryPreferenceStore()
            )
            XCTFail("a failed digest was re-admitted before rollback completed")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .sourceQuarantined)
        }
    }

    func testARefererTheHostReSuppliesIsStillRemovedFromTheOutgoingSet() throws {
        let sanitized = try ReaderExtensionSecurityPolicy.sanitizedHeaders(
            ["Referer": "https://source.example/series/1", "X-Custom": "1"],
            crossOrigin: true,
            allowsAuthoredNavigationHeaders: false,
            hostSuppliesOriginReferer: true
        )
        XCTAssertNil(
            sanitized["Referer"],
            "the host re-supplies its own origin referer after this call, so the authored one is still dropped here"
        )
        XCTAssertNil(sanitized["X-Custom"], "an ordinary cross-origin header is still refused")
        let withoutFlag = try ReaderExtensionSecurityPolicy.sanitizedHeaders(
            ["Referer": "https://source.example/series/1", "X-Custom": "1"],
            crossOrigin: true,
            allowsAuthoredNavigationHeaders: false,
            hostSuppliesOriginReferer: false
        )
        XCTAssertEqual(
            sanitized.count,
            withoutFlag.count,
            "hostSuppliesOriginReferer is a reporting classification, never an admission decision"
        )
    }

    func testUserRetryClearsOnlyTheSessionQuarantineASourceEarnedByItsOwnThrow() async throws {
        let script = Data("""
        class DefaultExtension extends MProvider {}
        throw new Error('owned source initialization failure');
        """.utf8)
        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        var source = installedSource(implementation: .javascript)
        source.activeContentDigest = digest
        defer {
            ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
                false,
                sourceID: source.id,
                digest: digest
            )
        }

        do {
            _ = try await ReaderExtensionJavaScriptRuntime.execute(
                scriptData: script,
                source: source,
                operation: .popular(1),
                network: ReaderExtensionDenyNetworkClient(),
                approvedDomains: [],
                preferenceStore: ReaderExtensionInMemoryPreferenceStore()
            )
            XCTFail("source initialization integrity failure was not surfaced")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .runtimeIntegrityFailed("source initialization"))
        }

        XCTAssertTrue(
            ReaderExtensionJavaScriptRuntime.clearSessionQuarantineForUserRetry(
                sourceID: source.id,
                digest: digest
            ),
            "a source-authored throw must be releasable by an explicit user retry"
        )

        do {
            _ = try await ReaderExtensionJavaScriptRuntime.execute(
                scriptData: script,
                source: source,
                operation: .popular(1),
                network: ReaderExtensionDenyNetworkClient(),
                approvedDomains: [],
                preferenceStore: ReaderExtensionInMemoryPreferenceStore()
            )
            XCTFail("the retry did not actually run the source")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(
                error,
                .runtimeIntegrityFailed("source initialization"),
                "the retry must reach the source's code again rather than short-circuiting on the stale marker"
            )
        }

        XCTAssertFalse(
            ReaderExtensionJavaScriptRuntime.clearSessionQuarantineForUserRetry(
                sourceID: source.id,
                digest: digest.uppercased() + "ff"
            ),
            "a digest that was never session-quarantined is not clearable"
        )
    }

    func testRelaxedRepositoryAndScriptURLPolicyAcceptsRealRepositoriesAndStillFailsClosed() throws {
        for accepted in [
            "https://repo.example/repo.json",
            "https://repo.example/index.json",
            "https://repo.example/novel_index.json",
            "https://repo.example/repo.json?ref=main"
        ] {
            XCTAssertNoThrow(
                try ReaderExtensionSecurityPolicy.validateRepositoryURLSyntax(
                    XCTUnwrap(URL(string: accepted))
                ),
                "a self-hosted repository at \(accepted) must install"
            )
        }
        for accepted in [
            "https://repo.example/source.js",
            "https://repo.example/source.mjs",
            "https://repo.example/source.js?rev=3"
        ] {
            XCTAssertNoThrow(
                try ReaderExtensionSecurityPolicy.validateScriptURLSyntax(
                    XCTUnwrap(URL(string: accepted))
                ),
                "a versioned script URL at \(accepted) must load"
            )
        }
        XCTAssertThrowsError(
            try ReaderExtensionSecurityPolicy.validateRepositoryURLSyntax(
                XCTUnwrap(URL(string: "https://repo.example/repo.json?token=secret"))
            ),
            "a credential-bearing repository query is still refused"
        )
        XCTAssertThrowsError(
            try ReaderExtensionSecurityPolicy.validateScriptURLSyntax(
                XCTUnwrap(URL(string: "https://repo.example/source.js?signature=secret"))
            ),
            "a credential-bearing script query is still refused"
        )
        for accepted in [
            "https://repo.example:8443/index.json",
            "https://repo.example:8080/index.json",
            "https://repo.example:8000/index.json",
            "https://repo.example:3000/index.json"
        ] {
            XCTAssertNoThrow(
                try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
                    XCTUnwrap(URL(string: accepted)),
                    requireHTTPS: true
                ),
                "the widened web-alternate port set must admit \(accepted)"
            )
        }
        for refused in [
            "https://repo.example:25/index.json",
            "https://repo.example:6379/index.json",
            "https://repo.example:6667/index.json",
            "https://192.168.1.10/index.json",
            "https://repo.local/index.json"
        ] {
            XCTAssertThrowsError(
                try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
                    XCTUnwrap(URL(string: refused)),
                    requireHTTPS: true
                ),
                "widening the port set must not open \(refused)"
            )
        }
    }

    func testUserRetryNeitherClearsNorErasesADurableQuarantine() throws {
        let source = installedSource(implementation: .javascript)
        let digest = String(repeating: "a", count: 64)
        defer {
            ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
                false,
                sourceID: source.id,
                digest: digest
            )
            try? ReaderExtensionPersistence.clearRuntimeQuarantine(
                sourceID: source.id,
                digest: digest
            )
        }
        try ReaderExtensionPersistence.markRuntimeQuarantined(
            sourceID: source.id,
            digest: digest
        )
        ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
            true,
            sourceID: source.id,
            digest: digest
        )
        XCTAssertTrue(
            try ReaderExtensionPersistence.runtimeQuarantineContains(
                sourceID: source.id,
                digest: digest
            ),
            "fixture precondition: the durable marker is recorded"
        )

        XCTAssertFalse(
            ReaderExtensionJavaScriptRuntime.clearSessionQuarantineForUserRetry(
                sourceID: source.id,
                digest: digest
            ),
            "a marker without session-only standing is an Eclipse-side integrity verdict and stays fail-closed"
        )
        XCTAssertTrue(
            try ReaderExtensionPersistence.runtimeQuarantineContains(
                sourceID: source.id,
                digest: digest
            ),
            "a user retry must never erase the durable marker; the tampered bytes would execute after relaunch"
        )
    }

    func testASourceAuthoredThrowIsBlockedForTheSessionButNotDurablyMarked() async throws {
        let script = Data("""
        class DefaultExtension extends MProvider {}
        throw new Error('owned source initialization failure');
        """.utf8)
        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        var source = installedSource(implementation: .javascript)
        source.activeContentDigest = digest
        defer {
            ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
                false,
                sourceID: source.id,
                digest: digest
            )
        }

        do {
            _ = try await ReaderExtensionJavaScriptRuntime.execute(
                scriptData: script,
                source: source,
                operation: .popular(1),
                network: ReaderExtensionDenyNetworkClient(),
                approvedDomains: [],
                preferenceStore: ReaderExtensionInMemoryPreferenceStore()
            )
            XCTFail("source initialization integrity failure was not surfaced")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .runtimeIntegrityFailed("source initialization"))
        }

        XCTAssertEqual(
            ReaderExtensionJavaScriptRuntime.sessionOnlyQuarantineAttribution(
                sourceID: source.id,
                digest: digest
            ),
            .sourceAuthored,
            "the source's own throw blocks the digest for this session, recorded as the source's defect"
        )
        XCTAssertFalse(
            try ReaderExtensionPersistence.runtimeQuarantineContains(
                sourceID: source.id,
                digest: digest
            ),
            "a community extension with a top-level throw must not be bricked until reinstall"
        )
    }

    func testPreactivationQuarantineUsesExactCandidateDigest() async throws {
        let brokenScript = Data("""
        class DefaultExtension extends MProvider {}
        throw new Error('owned candidate initialization failure');
        """.utf8)
        let brokenDigest = SHA256.hash(data: brokenScript).map { String(format: "%02x", $0) }.joined()
        let source = installedSource(implementation: .javascript)
        defer {
            ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
                false,
                sourceID: source.id,
                digest: brokenDigest
            )
        }

        do {
            _ = try await ReaderExtensionJavaScriptRuntime.execute(
                scriptData: brokenScript,
                source: source,
                operation: .popular(1),
                network: ReaderExtensionDenyNetworkClient(),
                approvedDomains: [],
                preferenceStore: ReaderExtensionInMemoryPreferenceStore()
            )
            XCTFail("broken pre-activation candidate was accepted")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .runtimeIntegrityFailed("source initialization"))
        }

        let validScript = Data(requiredMangaScript(preferenceBody: "return [];").utf8)
        let result = try await ReaderExtensionJavaScriptRuntime.execute(
            scriptData: validScript,
            source: source,
            operation: .popular(1),
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual((object["list"] as? [Any])?.count, 0)
    }

    func testQuarantineIsScopedBySourceWhenScriptsHaveIdenticalBytes() async throws {
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: 'Owned Fixture', chapters: []}; }
          async getPageList(url) { return []; }
          getSourcePreferences() {
            if (new SharedPreferences().get('fail_integrity', false)) {
              throw new Error('owned source-specific initialization failure');
            }
            return [];
          }
        }
        """.utf8)
        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        var sourceA = installedSource(implementation: .javascript)
        sourceA.activeContentDigest = digest
        var sourceB = sourceA
        sourceB.upstreamID = "javascript-b"
        sourceB.id = ReaderExtensionSourceID(
            repositoryURL: sourceB.repositoryURL,
            upstreamID: sourceB.upstreamID,
            language: sourceB.language,
            mediaType: sourceB.mediaType
        )
        defer {
            ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
                false,
                sourceID: sourceA.id,
                digest: digest
            )
            ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
                false,
                sourceID: sourceB.id,
                digest: digest
            )
        }

        do {
            _ = try await ReaderExtensionJavaScriptRuntime.execute(
                scriptData: script,
                source: sourceA,
                operation: .popular(1),
                network: ReaderExtensionDenyNetworkClient(),
                approvedDomains: [],
                preferenceStore: ReaderExtensionInMemoryPreferenceStore(
                    values: ["fail_integrity": .bool(true)]
                )
            )
            XCTFail("source-specific integrity failure was not surfaced")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .runtimeIntegrityFailed("preference schema initialization"))
        }

        let result = try await ReaderExtensionJavaScriptRuntime.execute(
            scriptData: script,
            source: sourceB,
            operation: .popular(1),
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            preferenceStore: ReaderExtensionInMemoryPreferenceStore(
                values: ["fail_integrity": .bool(false)]
            )
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual((object["list"] as? [Any])?.count, 0)
    }

    func testRuntimeRejectsScriptBytesThatDoNotMatchSuppliedDigest() async throws {
        let script = Data(requiredMangaScript(preferenceBody: "return [];").utf8)
        var source = installedSource(implementation: .javascript)
        source.activeContentDigest = String(repeating: "a", count: 64)
        defer {
            ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
                false,
                sourceID: source.id,
                digest: String(repeating: "a", count: 64)
            )
        }

        do {
            _ = try await ReaderExtensionJavaScriptRuntime.execute(
                scriptData: script,
                source: source,
                operation: .popular(1),
                network: ReaderExtensionDenyNetworkClient(),
                approvedDomains: [],
                preferenceStore: ReaderExtensionInMemoryPreferenceStore()
            )
            XCTFail("mismatched executable bytes were accepted")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .runtimeIntegrityFailed("source content digest validation"))
        }

        do {
            _ = try await ReaderExtensionJavaScriptRuntime.execute(
                scriptData: script,
                source: source,
                operation: .popular(1),
                network: ReaderExtensionDenyNetworkClient(),
                approvedDomains: [],
                preferenceStore: ReaderExtensionInMemoryPreferenceStore()
            )
            XCTFail("mismatched metadata digest was not quarantined")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .sourceQuarantined)
        }
    }

    func testAuditedOptionalThrowStubsBecomeUnsupportedWithoutHidingFailures() async throws {
        let mangaStub = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: "Owned Fixture", chapters: []}; }
          async getPageList(url) { return []; }
          getFilterList() { throw new Error('getFilterList not implemented'); }
        }
        """.utf8)
        let mangaSource = installedSource(implementation: .javascript)
        let mangaValidation = try await ReaderExtensionJavaScriptRuntime.bootstrapValidate(
            scriptData: mangaStub,
            source: mangaSource
        )
        XCTAssertFalse(mangaValidation.capabilities.contains(.filters))
        let mangaFilters = try await ReaderExtensionJavaScriptRuntime.execute(
            scriptData: mangaStub,
            source: mangaSource,
            operation: .filters,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )
        XCTAssertEqual((try JSONSerialization.jsonObject(with: mangaFilters) as? [Any])?.count, 0)

        let novelStub = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async getLatestUpdates(page) { throw new Error("getLatestUpdates not implemented"); }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: "Owned Fixture", chapters: []}; }
          async getHtmlContent(name, url) { return "<p>Owned</p>"; }
          getFilterList() { throw new Error("getFilterList not implemented"); }
        }
        """.utf8)
        let novelSource = installedSource(implementation: .javascript, mediaType: .novel)
        let novelValidation = try await ReaderExtensionJavaScriptRuntime.bootstrapValidate(
            scriptData: novelStub,
            source: novelSource
        )
        XCTAssertFalse(novelValidation.capabilities.contains(.latest))
        XCTAssertFalse(novelValidation.capabilities.contains(.filters))
        let latestData = try await ReaderExtensionJavaScriptRuntime.execute(
            scriptData: novelStub,
            source: novelSource,
            operation: .latest(1),
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )
        let latest = try XCTUnwrap(try JSONSerialization.jsonObject(with: latestData) as? [String: Any])
        XCTAssertEqual((latest["list"] as? [Any])?.count, 0)
        XCTAssertEqual(latest["hasNextPage"] as? Bool, false)

        let genuineFailure = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async getLatestUpdates(page) { throw new Error("provider outage"); }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: "Owned Fixture", chapters: []}; }
          async getPageList(url) { return []; }
          getFilterList() { throw new Error("filter request failed"); }
        }
        """.utf8)
        let genuineValidation = try await ReaderExtensionJavaScriptRuntime.bootstrapValidate(
            scriptData: genuineFailure,
            source: mangaSource
        )
        XCTAssertTrue(genuineValidation.capabilities.contains(.latest))
        XCTAssertTrue(genuineValidation.capabilities.contains(.filters))
        for operation in [ReaderExtensionJavaScriptOperation.latest(1), .filters] {
            do {
                _ = try await ReaderExtensionJavaScriptRuntime.execute(
                    scriptData: genuineFailure,
                    source: mangaSource,
                    operation: operation,
                    network: ReaderExtensionDenyNetworkClient(),
                    approvedDomains: [],
                    preferenceStore: ReaderExtensionInMemoryPreferenceStore()
                )
                XCTFail("a genuine optional-method failure was hidden")
            } catch let error as ReaderExtensionError {
                XCTAssertEqual(error, .runtimeFailed("source operation rejected"))
            }
        }
    }

    func testJavaScriptABIValidationAndDynamicExecutionDenial() async throws {
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: "Owned Fixture", chapters: []}; }
          async getPageList(url) { return []; }
          getFilterList() { return [{type: "GroupFilter", name: "Group", state: [{type: "SelectFilter", name: "Status", state: 0, values: []}]}]; }
          getSourcePreferences() { return [{key: "api_token", editTextPreference: {title: "Token", inputType: "password", value: ""}}]; }
        }
        """.utf8)
        let validation = try await ReaderExtensionJavaScriptRuntime.bootstrapValidate(
            scriptData: script,
            source: installedSource(implementation: .javascript)
        )
        XCTAssertTrue([ReaderExtensionCapability.popular, .search, .detail, .pages].allSatisfy { validation.capabilities.contains($0) })
        XCTAssertEqual(validation.secretPreferenceKeys, Set(["api_token"]))

        for construct in [
            "class DefaultExtension extends MProvider {}\neval('1')",
            "class DefaultExtension extends MProvider {}\nReflect [ 'construct' ](Function, [])",
            "class DefaultExtension extends MProvider {}\nObject.getPrototypeOf(function*(){}).constructor('yield 1')"
        ] {
            XCTAssertThrowsError(try ReaderExtensionSecurityPolicy.validateScript(Data(construct.utf8)))
        }
    }

    func testRuntimeDOMAndFetchBudgetsAreAggregatePerOperation() throws {
        let documentBudget = ReaderExtensionDOMBridge(baseURL: publicBaseURL)
        for index in 0..<ReaderExtensionSecurityPolicy.maximumDOMDocumentsPerOperation {
            XCTAssertNotEqual(documentBudget.parse("<html><body>\(index)</body></html>"), 0)
        }
        XCTAssertEqual(
            documentBudget.parse("<html><body>one document too many</body></html>"),
            0
        )

        let parseBudget = ReaderExtensionDOMBridge(baseURL: publicBaseURL)
        let chunk = "<p>" + String(
            repeating: "x",
            count: ReaderExtensionSecurityPolicy.maximumDOMBytes / 4
        ) + "</p>"
        XCTAssertNotEqual(parseBudget.parse(chunk), 0)
        XCTAssertNotEqual(parseBudget.parse(chunk), 0)
        XCTAssertNotEqual(parseBudget.parse(chunk), 0)
        XCTAssertEqual(
            parseBudget.parse(chunk),
            0,
            "repeated inputs below the individual DOM limit must still hit the aggregate limit"
        )

        let outputBudget = ReaderExtensionDOMBridge(baseURL: publicBaseURL)
        let outputHandle = outputBudget.parse(
            "<p>" + String(repeating: "y", count: 600 * 1_024) + "</p>"
        )
        XCTAssertNotEqual(outputHandle, 0)
        let outputCallCeiling =
            ReaderExtensionSecurityPolicy.maximumDOMReturnedBytesPerOperation / (600 * 1_024) + 4
        var outputCalls = 0
        while outputCalls < outputCallCeiling,
              !outputBudget.string(outputHandle, property: "text").isEmpty {
            outputCalls += 1
        }
        XCTAssertGreaterThan(outputCalls, 0)
        XCTAssertLessThan(
            outputCalls,
            outputCallCeiling,
            "the aggregate output budget must exhaust deterministically"
        )
        let exhaustedOutputState = outputBudget.budgetStateForTesting
        XCTAssertTrue(outputBudget.string(outputHandle, property: "text").isEmpty)
        XCTAssertEqual(
            outputBudget.budgetStateForTesting.bridgeCalls,
            exhaustedOutputState.bridgeCalls,
            "an exhausted output budget must be rejected before SwiftSoup serializes again"
        )
        XCTAssertLessThanOrEqual(
            outputBudget.budgetStateForTesting.returnedBytes,
            ReaderExtensionSecurityPolicy.maximumDOMReturnedBytesPerOperation
        )

        let traversalBudget = ReaderExtensionDOMBridge(baseURL: publicBaseURL)
        let traversalHandle = traversalBudget.parse(
            "<main>" + String(repeating: "<div><span>x</span></div>", count: 1_500) + "</main>"
        )
        XCTAssertNotEqual(traversalHandle, 0)
        var successfulTraversals = 0
        for _ in 0..<256 {
            if traversalBudget.select(traversalHandle, selector: "body").isEmpty { break }
            successfulTraversals += 1
        }
        XCTAssertGreaterThan(successfulTraversals, 0)
        XCTAssertLessThan(successfulTraversals, 256, "finite host traversals must exhaust a deterministic work budget")

        let selectorBudget = ReaderExtensionDOMBridge(baseURL: publicBaseURL)
        let selectorHandle = selectorBudget.parse(
            "<div data-owned='yes'><span>" + String(repeating: "a", count: 128 * 1_024)
                + "!</span><ul><li>A</li><li>B</li><li>C</li></ul></div>"
        )
        XCTAssertNotEqual(selectorHandle, 0)
        XCTAssertFalse(selectorBudget.select(selectorHandle, selector: "div:has(span) > span").isEmpty)
        for ordinaryPosition in ["li:eq(1)", "li:lt(2)", "li:gt(0)", "li:nth-child(2)"] {
            XCTAssertFalse(
                selectorBudget.select(selectorHandle, selector: ordinaryPosition).isEmpty,
                "ordinary audited positional selector was rejected: \(ordinaryPosition)"
            )
        }
        XCTAssertTrue(selectorBudget.select(selectorHandle, selector: ":matches((a+)+$)").isEmpty)
        XCTAssertTrue(selectorBudget.select(selectorHandle, selector: "[data-owned~=(a+)+$]").isEmpty)
        let deeplyNested = String(repeating: ":has(", count: 9) + "span" + String(repeating: ")", count: 9)
        XCTAssertTrue(selectorBudget.select(selectorHandle, selector: deeplyNested).isEmpty)
        let overflowingIndex = String(repeating: "9", count: 900)
        for hostilePosition in [
            "li:eq(\(overflowingIndex))",
            "li:lt(\(overflowingIndex))",
            "li:gt(\(overflowingIndex))",
            "li:nth-child(\(overflowingIndex))"
        ] {
            XCTAssertTrue(
                selectorBudget.select(selectorHandle, selector: hostilePosition).isEmpty,
                "an overflowing positional selector reached SwiftSoup: \(hostilePosition.prefix(32))"
            )
        }

        let fetchBudget = ReaderExtensionFetchBudget()
        for _ in 0..<16 {
            XCTAssertTrue(fetchBudget.admit())
            XCTAssertTrue(fetchBudget.consumeResponseBytes(2 * 1_024 * 1_024))
        }
        XCTAssertTrue(fetchBudget.admit())
        XCTAssertFalse(
            fetchBudget.consumeResponseBytes(1),
            "many individually valid responses must not exceed the aggregate response budget"
        )
        XCTAssertEqual(
            fetchBudget.stateForTesting.responseBytes,
            ReaderExtensionSecurityPolicy.maximumFetchResponseBytesPerOperation
        )
    }

    func testChallengeDetectorSeparatesVerificationPagesFromOrdinaryResponses() {
        XCTAssertTrue(ReaderExtensionChallengeDetector.isChallenge(
            status: 403,
            headers: ["cf-mitigated": "challenge"],
            body: Data("<html><body>blocked</body></html>".utf8)
        ))
        XCTAssertTrue(ReaderExtensionChallengeDetector.isChallenge(
            status: 200,
            headers: [:],
            body: Data("<html><head><title>Just a moment...</title></head><body>cloudflare</body></html>".utf8)
        ))
        XCTAssertTrue(ReaderExtensionChallengeDetector.isChallenge(
            status: 503,
            headers: [:],
            body: Data("<div id='cf-spinner'>challenge-platform</div>".utf8)
        ))
        XCTAssertFalse(
            ReaderExtensionChallengeDetector.isChallenge(
                status: 200,
                headers: [:],
                body: Data("<article><section><a href='/series/1'>Owned</a></section></article>".utf8)
            ),
            "an ordinary catalog page must never be reported as a challenge"
        )
        XCTAssertFalse(
            ReaderExtensionChallengeDetector.isChallenge(
                status: 404,
                headers: [:],
                body: Data("<html><body>Not found</body></html>".utf8)
            ),
            "an ordinary error page is not a verification prompt"
        )
        XCTAssertFalse(
            ReaderExtensionChallengeDetector.isChallenge(
                status: 200,
                headers: [:],
                body: Data("<p>This chapter mentions cloudflare and challenge-platform in prose.</p>".utf8)
            ),
            "provider markers only count on a blocked status"
        )
    }

    func testMangayomiURLParserPreservesExistingEscapesWhileRepairingRawCharacters() throws {
        let mixed = "https://reader.example/search/data?text=&sort=Latest Updates&display_mode=Full%20Display"
        XCTAssertEqual(
            ReaderExtensionMangayomiURLParser.url(mixed, relativeTo: nil)?.absoluteString,
            "https://reader.example/search/data?text=&sort=Latest%20Updates&display_mode=Full%20Display",
            "raw spaces must be repaired without double-encoding neighboring escapes"
        )
        let base = try XCTUnwrap(URL(string: "https://reader.example"))
        XCTAssertEqual(
            ReaderExtensionMangayomiURLParser.url("/series/X/full-chapter-list", relativeTo: base)?.absoluteString,
            "https://reader.example/series/X/full-chapter-list"
        )
        XCTAssertNil(ReaderExtensionMangayomiURLParser.url("", relativeTo: nil))
    }

    func testDOMBridgeSurvivesRealisticCatalogAndChapterListShapes() throws {
        let catalog = ReaderExtensionDOMBridge(baseURL: publicBaseURL)
        let searchRow = """
        <article class="bg-base-300"><section class="w-full"><a href="https://example.invalid/series/1">\
        <article class="hidden"><picture><source srcset="x.webp"><source srcset="y.webp">\
        <img src="https://example.invalid/cover.jpg"></picture></article></a></section>\
        <div class="truncate"><div><div class="link">Title</div></div></div>\
        <div class="row"><span>Author</span><span>Year</span><span>Status</span></div></article>
        """
        let searchDocument = catalog.parse(
            "<html><body>" + String(repeating: searchRow, count: 32)
                + "<button>View More Results...</button></body></html>"
        )
        XCTAssertNotEqual(searchDocument, 0)
        let rows = catalog.select(searchDocument, selector: "article:has(section)")
        XCTAssertEqual(rows.count, 32)
        for row in rows {
            let image = catalog.select(row, selector: "img")
            XCTAssertEqual(image.count, 1, "every catalog row must stay selectable through a full page loop")
            XCTAssertFalse(catalog.attribute(image[0], name: "src").isEmpty)
            let link = catalog.select(row, selector: "section > a")
            XCTAssertEqual(link.count, 1)
            XCTAssertFalse(catalog.attribute(link[0], name: "href").isEmpty)
            let name = catalog.select(row, selector: "article > div > div > div")
            XCTAssertFalse(name.isEmpty)
            XCTAssertFalse(catalog.string(name[0], property: "text").isEmpty)
        }
        XCTAssertFalse(
            catalog.select(searchDocument, selector: "button").isEmpty,
            "pagination probing must still be admitted after a full row loop"
        )

        let chapters = ReaderExtensionDOMBridge(baseURL: publicBaseURL)
        let chapterRow = """
        <div class="flex items-center"><a href="https://example.invalid/chapters/c">\
        <span class="grow flex items-center gap-2"><span>Chapter</span><i></i></span>\
        <time class="text-datetime" datetime="2026-01-01">Jan 1</time></a>\
        <input type="checkbox" value="https://example.invalid/chapters/c">\
        <div class="extra"><span>a</span><span>b</span><span>c</span><span>d</span><span>e</span></div></div>
        """
        let chapterDocument = chapters.parse(
            "<html><body><section><ul>" + String(repeating: chapterRow, count: 1_200) + "</ul></section></body></html>"
        )
        XCTAssertNotEqual(chapterDocument, 0, "a 1,200-chapter catalog page must parse")
        let chapterRows = chapters.select(chapterDocument, selector: "div.flex.items-center")
        XCTAssertEqual(chapterRows.count, 1_200, "long chapter lists must not be truncated by the select row cap")
        for row in chapterRows {
            XCTAssertFalse(chapters.select(row, selector: "span.grow").isEmpty)
            XCTAssertFalse(chapters.select(row, selector: "input").isEmpty)
        }
    }

    func testDOMBridgeSelectMatchesDescendantsOnlyAndNeverTheReceiver() throws {
        let bridge = ReaderExtensionDOMBridge(baseURL: publicBaseURL)
        let document = bridge.parse("""
        <html><body><div class="flex items-center"><a href="/chapters/01J76XZ3XJ408S14GZXZGEGW1S">\
        <span class="grow flex items-center gap-2"><span class="">Chapter 85</span>\
        <span class="flex gap-1 items-center link-info"><svg viewBox="0 0 384 512"></svg>\
        <span class="hidden md:inline">Last Read</span></span>\
        <span><img src="/static/images/new-chapter.svg"></span></span>\
        <time class="text-datetime" datetime="2024-09-07T17:04:15.717Z">2024-09-07T17:04:15.717343Z</time></a>\
        <input type="checkbox" value="01J76XZ3XJ408S14GZXZGEGW1S"></div></body></html>
        """)
        XCTAssertNotEqual(document, 0)
        let rows = bridge.select(document, selector: "div.flex.items-center")
        XCTAssertEqual(rows.count, 1)
        let titleContainer = bridge.select(rows[0], selector: "span.grow.flex.items-center.gap-2")
        XCTAssertEqual(titleContainer.count, 1)
        XCTAssertTrue(
            bridge.select(titleContainer[0], selector: "span.grow.flex.items-center.gap-2").isEmpty,
            "select on an element must search descendants only, never return the receiver itself"
        )
        let spans = bridge.select(titleContainer[0], selector: "span")
        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(
            bridge.string(spans[0], property: "text"),
            "Chapter 85",
            "the first descendant span is the chapter title; the receiver's own concatenated text would leak the Last Read badge"
        )
    }

    func testItemSeedCacheBoundsMetadataAndUsesByteAwareGlobalLRU() throws {
        ReaderExtensionItemSeedCache.clearAll()
        defer { ReaderExtensionItemSeedCache.clearAll() }
        let scopeID = UUID().uuidString
        let sourceID = installedSource(implementation: .javascript).id
        let oversized = ReaderExtensionItem(
            key: "owned-oversized",
            title: String(repeating: "t", count: 10 * 1_024),
            description: String(repeating: "d", count: 512 * 1_024),
            author: String(repeating: "a", count: 16 * 1_024),
            artist: String(repeating: "r", count: 16 * 1_024),
            tags: Array(repeating: String(repeating: "g", count: 2 * 1_024), count: 200),
            maturity: .safe
        )
        ReaderExtensionItemSeedCache.record(oversized, scopeID: scopeID, sourceID: sourceID)
        let bounded = try XCTUnwrap(ReaderExtensionItemSeedCache.item(
            scopeID: scopeID,
            sourceID: sourceID,
            key: oversized.key
        ))
        XCTAssertLessThanOrEqual(bounded.title.utf8.count, 4 * 1_024)
        XCTAssertLessThanOrEqual(bounded.description?.utf8.count ?? 0, 64 * 1_024)
        XCTAssertLessThanOrEqual(bounded.author?.utf8.count ?? 0, 4 * 1_024)
        XCTAssertLessThanOrEqual(bounded.tags.reduce(0) { $0 + $1.utf8.count }, 16 * 1_024)

        ReaderExtensionItemSeedCache.clearAll()
        for index in 0..<40 {
            ReaderExtensionItemSeedCache.record(
                ReaderExtensionItem(
                    key: "source-item-\(index)",
                    title: "Owned \(index)",
                    description: String(repeating: "s", count: 96 * 1_024),
                    maturity: .safe
                ),
                scopeID: scopeID,
                sourceID: sourceID
            )
        }
        XCTAssertNil(ReaderExtensionItemSeedCache.item(
            scopeID: scopeID,
            sourceID: sourceID,
            key: "source-item-0"
        ))
        XCTAssertNotNil(ReaderExtensionItemSeedCache.item(
            scopeID: scopeID,
            sourceID: sourceID,
            key: "source-item-39"
        ))
        XCTAssertLessThanOrEqual(
            ReaderExtensionItemSeedCache.stateForTesting.bytes,
            2 * 1_024 * 1_024
        )

        ReaderExtensionItemSeedCache.clearAll()
        var firstGlobalSourceID: ReaderExtensionSourceID?
        var lastGlobalSourceID: ReaderExtensionSourceID?
        for sourceIndex in 0..<7 {
            let cacheSourceID = ReaderExtensionSourceID(
                repositoryURL: publicBaseURL.appendingPathComponent("cache-\(sourceIndex)/index.json"),
                upstreamID: "cache-\(sourceIndex)",
                language: "en",
                mediaType: .manga
            )
            if sourceIndex == 0 { firstGlobalSourceID = cacheSourceID }
            lastGlobalSourceID = cacheSourceID
            for itemIndex in 0..<20 {
                ReaderExtensionItemSeedCache.record(
                    ReaderExtensionItem(
                        key: "global-item-\(itemIndex)",
                        title: "Owned \(sourceIndex)-\(itemIndex)",
                        description: String(repeating: "z", count: 96 * 1_024),
                        maturity: .safe
                    ),
                    scopeID: scopeID,
                    sourceID: cacheSourceID
                )
            }
        }
        XCTAssertNil(ReaderExtensionItemSeedCache.item(
            scopeID: scopeID,
            sourceID: try XCTUnwrap(firstGlobalSourceID),
            key: "global-item-0"
        ))
        XCTAssertNotNil(ReaderExtensionItemSeedCache.item(
            scopeID: scopeID,
            sourceID: try XCTUnwrap(lastGlobalSourceID),
            key: "global-item-19"
        ))
        XCTAssertLessThanOrEqual(
            ReaderExtensionItemSeedCache.stateForTesting.bytes,
            8 * 1_024 * 1_024
        )
    }

    func testJavaScriptDocumentHTMLPreservesExactAuditedRawContract() async throws {
        let rawHTML = "<!doctype html>\n<HTML><Body><P data-owned='yes'>Exact &amp; Raw</P></Body></HTML>"
        let literal = try XCTUnwrap(String(data: JSONEncoder().encode(rawHTML), encoding: .utf8))
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) {
            const raw = \(literal);
            const document = new Document(raw);
            return {list: [], hasNextPage: false, documentHTML: document.html};
          }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: "Owned Fixture", chapters: []}; }
          async getPageList(url) { return []; }
        }
        """.utf8)
        let data = try await ReaderExtensionJavaScriptRuntime.execute(
            scriptData: script,
            source: installedSource(implementation: .javascript),
            operation: .popular(1),
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["documentHTML"] as? String, rawHTML)
    }

    func testJavaScriptDocumentSelectorsIncludeHeadAndMetadata() async throws {
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) {
            const document = new Document('<!doctype html><html><head><title>Owned Head</title><meta name="description" content="Owned Metadata"></head><body><p>Body</p></body></html>');
            return {
              list: [],
              hasNextPage: false,
              title: document.selectFirst('head > title').text,
              description: document.selectFirst('meta[name="description"]').attr('content')
            };
          }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: "Owned Fixture", chapters: []}; }
          async getPageList(url) { return []; }
        }
        """.utf8)
        let data = try await ReaderExtensionJavaScriptRuntime.execute(
            scriptData: script,
            source: installedSource(implementation: .javascript),
            operation: .popular(1),
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Owned Head")
        XCTAssertEqual(object["description"] as? String, "Owned Metadata")
    }

    func testDeclaredPreferenceDefaultsExistBeforeAnyUserSave() async throws {
        let rawSchema = """
        [
          {"key":"domain_url","editTextPreference":{"title":"Domain","value":"https://owned.invalid"}},
          {"key":"quality","listPreference":{"title":"Quality","valueIndex":1,"entries":["Low","High"],"entryValues":["low","high"]}},
          {"key":"enabled","switchPreferenceCompat":{"title":"Enabled","value":true}},
          {"key":"languages","multiSelectListPreference":{"title":"Languages","entries":["English"],"entryValues":["en"],"values":["en"]}}
        ]
        """
        let parsedDefaults = try XCTUnwrap(
            ReaderExtensionJavaScriptRuntime.declaredPreferenceDefaultsForTesting(rawJSON: rawSchema)
        )
        XCTAssertEqual(parsedDefaults["domain_url"], .string("https://owned.invalid"))
        XCTAssertEqual(parsedDefaults["quality"], .string("high"))
        XCTAssertEqual(parsedDefaults["enabled"], .bool(true))
        XCTAssertEqual(parsedDefaults["languages"], .stringList(["en"]))

        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) {
            const preferences = new SharedPreferences();
            const domain = preferences.get('domain_url');
            return {
              list: [],
              hasNextPage: false,
              domainLength: domain === null ? -1 : domain.length,
              quality: preferences.get('quality'),
              qualityWithCallerFallback: preferences.get('quality', 'caller-fallback'),
              enabled: preferences.get('enabled'),
              languages: preferences.get('languages')
            };
          }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: "Owned Fixture", chapters: []}; }
          async getPageList(url) { return []; }
          getSourcePreferences() {
            return [
              {key: 'domain_url', editTextPreference: {title: 'Domain', value: 'https://owned.invalid'}},
              {key: 'quality', listPreference: {title: 'Quality', valueIndex: 1, entries: ['Low', 'High'], entryValues: ['low', 'high']}},
              {key: 'enabled', switchPreferenceCompat: {title: 'Enabled', value: true}},
              {key: 'languages', multiSelectListPreference: {title: 'Languages', entries: ['English'], entryValues: ['en'], values: ['en']}}
            ];
          }
        }
        """.utf8)
        let data = try await ReaderExtensionJavaScriptRuntime.execute(
            scriptData: script,
            source: installedSource(implementation: .javascript),
            operation: .popular(1),
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["domainLength"] as? NSNumber)?.intValue, "https://owned.invalid".count)
        XCTAssertEqual(object["quality"] as? String, "high")
        XCTAssertEqual(object["qualityWithCallerFallback"] as? String, "high")
        XCTAssertEqual(object["enabled"] as? Bool, true)
        XCTAssertEqual(object["languages"] as? [String], ["en"])

        let provider = try JavaScriptReaderProvider(
            source: installedSource(implementation: .javascript),
            scriptData: script,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            consentScopeID: "owned-preference-defaults",
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )
        let declared = try await provider.preferences()
        XCTAssertEqual(declared.first(where: { $0.key == "quality" })?.defaultValue, .string("high"))
        XCTAssertEqual(declared.first(where: { $0.key == "enabled" })?.defaultValue, .bool(true))
        XCTAssertEqual(declared.first(where: { $0.key == "languages" })?.defaultValue, .stringList(["en"]))
    }

    func testSharedPreferencesRoutesDeclaredAndHeuristicSecretsAwayFromOrdinaryPersistence() async throws {
        let store = ReaderExtensionRecordingPreferenceStore(secretKeys: ["declared_login"])
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) {
            const preferences = new SharedPreferences();
            preferences.setString("reader_theme", "dark");
            preferences.setString("declared_login", "owned-declared-secret");
            preferences.setString("session_cookie", "owned-heuristic-secret");
            return {list: [], hasNextPage: false};
          }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: "Owned Fixture", chapters: []}; }
          async getPageList(url) { return []; }
        }
        """.utf8)
        _ = try await ReaderExtensionJavaScriptRuntime.execute(
            scriptData: script,
            source: installedSource(implementation: .javascript),
            operation: .popular(1),
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            preferenceStore: store
        )
        XCTAssertEqual(store.value(for: "reader_theme"), .string("dark"))
        XCTAssertNil(store.value(for: "declared_login"))
        XCTAssertNil(store.value(for: "session_cookie"))
        XCTAssertEqual(try store.secret(for: "declared_login"), "owned-declared-secret")
        XCTAssertEqual(try store.secret(for: "session_cookie"), "owned-heuristic-secret")
    }

    func testSharedPreferencesRoundTripHeuristicSecretsAndGateDeclaredOnlyKeysBySchema() async throws {
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) {
            const preferences = new SharedPreferences();
            return {
              list: [],
              hasNextPage: false,
              privateValue: preferences.get("privateModeKey", "blocked-private"),
              tokenValue: preferences.get("access_token", "blocked-token"),
              cookieValue: preferences.get("session_cookie", "blocked-cookie")
            };
          }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: "Owned Fixture", chapters: []}; }
          async getPageList(url) { return []; }
        }
        """.utf8)

        let rolledBackStore = ReaderExtensionRecordingPreferenceStore(secretKeys: [])
        try rolledBackStore.setSecret("new-schema-secret", for: "privateModeKey")
        try rolledBackStore.setSecret("old-access-token", for: "access_token")
        try rolledBackStore.setSecret("old-session-cookie", for: "session_cookie")
        XCTAssertTrue(rolledBackStore.shouldStoreAsSecret("access_token"))
        XCTAssertTrue(rolledBackStore.shouldStoreAsSecret("session_cookie"))
        XCTAssertTrue(
            rolledBackStore.mayReadSecret("access_token"),
            "a key the store routes to the Keychain must read back, or login sources sign out every operation"
        )
        XCTAssertTrue(rolledBackStore.mayReadSecret("session_cookie"))
        XCTAssertFalse(
            rolledBackStore.mayReadSecret("privateModeKey"),
            "a declared-only secret stays gated by the current schema after rollback"
        )
        let blockedData = try await ReaderExtensionJavaScriptRuntime.execute(
            scriptData: script,
            source: installedSource(implementation: .javascript),
            operation: .popular(1),
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            preferenceStore: rolledBackStore
        )
        let blocked = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: blockedData) as? [String: Any]
        )
        XCTAssertEqual(blocked["privateValue"] as? String, "blocked-private")
        XCTAssertEqual(blocked["tokenValue"] as? String, "old-access-token")
        XCTAssertEqual(blocked["cookieValue"] as? String, "old-session-cookie")

        let declaredStore = ReaderExtensionRecordingPreferenceStore(
            secretKeys: ["privateModeKey", "access_token", "session_cookie"]
        )
        try declaredStore.setSecret("current-schema-secret", for: "privateModeKey")
        try declaredStore.setSecret("current-access-token", for: "access_token")
        try declaredStore.setSecret("current-session-cookie", for: "session_cookie")
        let allowedData = try await ReaderExtensionJavaScriptRuntime.execute(
            scriptData: script,
            source: installedSource(implementation: .javascript),
            operation: .popular(1),
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            preferenceStore: declaredStore
        )
        let allowed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: allowedData) as? [String: Any]
        )
        XCTAssertEqual(allowed["privateValue"] as? String, "current-schema-secret")
        XCTAssertEqual(allowed["tokenValue"] as? String, "current-access-token")
        XCTAssertEqual(allowed["cookieValue"] as? String, "current-session-cookie")
    }

    func testPreferencePersistenceIsBoundedAndClearAuthenticationFindsUnreferencedSecrets() throws {
        let sourceID = installedSource(implementation: .javascript).id
        let namespace = "reader-preference-test-\(UUID().uuidString)"
        var durableWrites: [String: ReaderExtensionPreferenceValue] = [:]
        let keychain = ReaderExtensionInjectedKeychainAccess(accounts: [:])
        let store = ReaderExtensionKeychainStore(
            sourceID: sourceID,
            namespace: namespace,
            schemaSecretKeys: ["schema_pin"],
            ordinaryValueWriter: { durableWrites[$0] = $1 },
            keychain: keychain
        )
        defer { try? store.removeAllDeviceState() }

        try store.setValue(.string("sepia"), for: "reader_theme")
        XCTAssertEqual(durableWrites["reader_theme"], .string("sepia"))
        XCTAssertThrowsError(try store.setValue(
            .string(String(repeating: "x", count: ReaderExtensionSecurityPolicy.maximumPreferenceValueBytes + 1)),
            for: "too_large"
        ))

        try store.setSecret("owned-schema-secret", for: "schema_pin")
        try store.setSecret("owned-script-secret", for: "dynamic_token")
        XCTAssertNotNil(try store.secret(for: "schema_pin"))
        XCTAssertNotNil(try store.secret(for: "dynamic_token"))
        try store.removeAllSecrets()
        XCTAssertNil(try store.secret(for: "schema_pin"))
        XCTAssertNil(try store.secret(for: "dynamic_token"))
    }

    func testClearAuthenticationMetadataRemovesAllSecretMarkersAndCredentialKeys() {
        var source = installedSource(implementation: .javascript)
        source.secretPreferenceKeys = ["login_field"]
        source.preferences = [
            "login_field": .secretReference("login_field"),
            "dynamic_token": .string("stale-plaintext"),
            "unlisted_marker": .secretReference("unlisted_marker"),
            "reader_theme": .string("sepia")
        ]
        XCTAssertTrue(source.removeAuthenticationPreferenceMetadata())
        XCTAssertEqual(source.preferences, ["reader_theme": .string("sepia")])
        XCTAssertFalse(source.removeAuthenticationPreferenceMetadata())
    }

    func testKeychainCleanupFailuresRemainDurableAndSuccessfulRetryClearsJournal() throws {
        let sourceID = installedSource(implementation: .javascript).id
        let namespace = UUID().uuidString
        let entry = ReaderExtensionPendingAuthenticationCleanup(
            sourceID: sourceID,
            namespace: namespace,
            kind: .deviceState
        )
        let suiteName = "ReaderExtensionCleanupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try ReaderExtensionPersistence.persistPendingAuthenticationCleanup([entry], to: defaults)

        let account = "\(namespace).\(sourceID.rawValue).secret.dynamic_token"
        let enumerationFailure = ReaderExtensionInjectedKeychainAccess(
            accounts: [account: Data("owned-secret".utf8)],
            enumerationFailure: errSecInteractionNotAllowed
        )
        var outcome = ReaderExtensionAuthenticationCleanupPolicy.retry([entry]) { pending in
            try ReaderExtensionKeychainStore(
                sourceID: pending.sourceID,
                namespace: pending.namespace,
                keychain: enumerationFailure
            ).removeAllDeviceState()
        }
        XCTAssertNotNil(outcome.firstError)
        XCTAssertEqual(outcome.remaining, [entry])
        try ReaderExtensionPersistence.persistPendingAuthenticationCleanup(outcome.remaining, to: defaults)
        XCTAssertEqual(try ReaderExtensionPersistence.loadPendingAuthenticationCleanup(from: defaults), [entry])

        let deletionFailure = ReaderExtensionInjectedKeychainAccess(
            accounts: [account: Data("owned-secret".utf8)],
            deletionFailure: errSecInteractionNotAllowed
        )
        outcome = ReaderExtensionAuthenticationCleanupPolicy.retry([entry]) { pending in
            try ReaderExtensionKeychainStore(
                sourceID: pending.sourceID,
                namespace: pending.namespace,
                keychain: deletionFailure
            ).removeAllDeviceState()
        }
        XCTAssertNotNil(outcome.firstError)
        XCTAssertEqual(outcome.remaining, [entry])
        XCTAssertEqual(deletionFailure.accounts[account], Data("owned-secret".utf8))

        let falseSuccess = ReaderExtensionInjectedKeychainAccess(
            accounts: [account: Data("owned-secret".utf8)],
            retainDeletedAccounts: true
        )
        outcome = ReaderExtensionAuthenticationCleanupPolicy.retry([entry]) { pending in
            try ReaderExtensionKeychainStore(
                sourceID: pending.sourceID,
                namespace: pending.namespace,
                keychain: falseSuccess
            ).removeAllDeviceState()
        }
        XCTAssertNotNil(outcome.firstError, "a successful delete status must still verify absence")
        XCTAssertEqual(outcome.remaining, [entry])

        let successfulRetry = ReaderExtensionInjectedKeychainAccess(
            accounts: deletionFailure.accounts
        )
        outcome = ReaderExtensionAuthenticationCleanupPolicy.retry([entry]) { pending in
            try ReaderExtensionKeychainStore(
                sourceID: pending.sourceID,
                namespace: pending.namespace,
                keychain: successfulRetry
            ).removeAllDeviceState()
        }
        XCTAssertNil(outcome.firstError)
        XCTAssertTrue(outcome.remaining.isEmpty)
        XCTAssertTrue(successfulRetry.accounts.isEmpty)
        try ReaderExtensionPersistence.persistPendingAuthenticationCleanup(outcome.remaining, to: defaults)
        XCTAssertTrue(try ReaderExtensionPersistence.loadPendingAuthenticationCleanup(from: defaults).isEmpty)
        XCTAssertNil(defaults.object(forKey: ReaderExtensionPersistence.pendingAuthenticationCleanupKey))
    }

    func testAuthenticationCleanupJournalCoalescesAndRejectsInvalidMetadata() throws {
        let sourceID = installedSource(implementation: .javascript).id
        let namespace = UUID().uuidString
        let authentication = try ReaderExtensionAuthenticationCleanupPolicy.adding(
            sourceIDs: [sourceID],
            namespaces: [namespace],
            kind: .authentication,
            to: []
        )
        XCTAssertEqual(authentication.count, 1)
        let deviceState = try ReaderExtensionAuthenticationCleanupPolicy.adding(
            sourceIDs: [sourceID],
            namespaces: [namespace],
            kind: .deviceState,
            to: authentication
        )
        XCTAssertEqual(deviceState.count, 1)
        XCTAssertEqual(deviceState.first?.kind, .deviceState)

        let otherNamespace = UUID().uuidString
        let profileEntries = try ReaderExtensionAuthenticationCleanupPolicy.adding(
            sourceIDs: [sourceID],
            namespaces: [namespace, otherNamespace],
            kind: .authentication,
            to: []
        )
        var retriedNamespaces = Set<String>()
        let oneProfile = ReaderExtensionAuthenticationCleanupPolicy.retry(
            profileEntries,
            sourceIDs: [sourceID],
            namespaces: [otherNamespace]
        ) {
            retriedNamespaces.insert($0.namespace)
        }
        XCTAssertEqual(retriedNamespaces, [otherNamespace])
        XCTAssertEqual(oneProfile.remaining.map(\.namespace), [namespace])

        let suiteName = "ReaderExtensionCleanupMetadataTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("[{\"namespace\":\"not-a-profile\"}]".utf8),
                     forKey: ReaderExtensionPersistence.pendingAuthenticationCleanupKey)
        XCTAssertThrowsError(try ReaderExtensionPersistence.loadPendingAuthenticationCleanup(from: defaults))
    }

    func testAuthenticationCleanupJournalIsCheckpointedAndIndependentOfServicesSharing() throws {
        let sourceID = installedSource(implementation: .javascript).id
        let entry = ReaderExtensionPendingAuthenticationCleanup(
            sourceID: sourceID,
            namespace: UUID().uuidString,
            kind: .deviceState
        )
        let deviceSuite = "ReaderExtensionDeviceCleanupTests.\(UUID().uuidString)"
        let sharedSuite = "ReaderExtensionSharedServicesTests.\(UUID().uuidString)"
        let scopedSuite = "ReaderExtensionScopedServicesTests.\(UUID().uuidString)"
        let deviceStore = try XCTUnwrap(UserDefaults(suiteName: deviceSuite))
        let sharedServices = try XCTUnwrap(UserDefaults(suiteName: sharedSuite))
        let scopedServices = try XCTUnwrap(UserDefaults(suiteName: scopedSuite))
        defer {
            deviceStore.removePersistentDomain(forName: deviceSuite)
            sharedServices.removePersistentDomain(forName: sharedSuite)
            scopedServices.removePersistentDomain(forName: scopedSuite)
        }

        try ReaderExtensionPersistence.persistPendingAuthenticationCleanup([entry], to: deviceStore)
        sharedServices.set(Data("shared".utf8), forKey: ReaderExtensionPersistence.installedSourcesKey)
        XCTAssertEqual(try ReaderExtensionPersistence.loadPendingAuthenticationCleanup(from: deviceStore), [entry])
        scopedServices.set(Data("scoped".utf8), forKey: ReaderExtensionPersistence.installedSourcesKey)
        XCTAssertEqual(
            try ReaderExtensionPersistence.loadPendingAuthenticationCleanup(from: deviceStore),
            [entry],
            "shared-to-scoped and scoped-to-shared service selection must not move or hide device cleanup intent"
        )

        let failedSuite = "ReaderExtensionCleanupCheckpointTests.\(UUID().uuidString)"
        let failedStore = try XCTUnwrap(UserDefaults(suiteName: failedSuite))
        defer { failedStore.removePersistentDomain(forName: failedSuite) }
        XCTAssertThrowsError(try ReaderExtensionPersistence.persistPendingAuthenticationCleanup(
            [entry],
            to: failedStore,
            checkpoint: { _ in false }
        ))
        XCTAssertNil(failedStore.object(forKey: ReaderExtensionPersistence.pendingAuthenticationCleanupKey))
    }

    func testProfileNamespaceCleanupIsolatedFromOtherProfileWithUnsharedServices() throws {
        let profileA = UUID()
        let profileB = UUID()
        let sourceID = installedSource(implementation: .javascript).id
        let prefixA = "\(profileA.uuidString).\(sourceID.rawValue)"
        let prefixB = "\(profileB.uuidString).\(sourceID.rawValue)"
        let keychain = ReaderExtensionInjectedKeychainAccess(accounts: [
            "\(prefixA).secret.access_token": Data("profile-a-secret".utf8),
            "\(prefixA).cookies": Data("profile-a-cookie".utf8),
            "\(prefixB).secret.access_token": Data("profile-b-secret".utf8),
            "\(prefixB).domains": Data("profile-b-domains".utf8)
        ])
        let suiteName = "ReaderExtensionProfileCleanup.\(UUID().uuidString)"
        let journal = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { journal.removePersistentDomain(forName: suiteName) }

        let result = try ReaderExtensionProfileAuthenticationLifecycle
            .prepareForProfileStoreDeletion(
                profileIDs: [profileA],
                journalStore: journal,
                keychain: keychain
            )

        XCTAssertTrue(result.isFullyClean)
        XCTAssertFalse(keychain.accounts.keys.contains { $0.hasPrefix(profileA.uuidString + ".") })
        XCTAssertEqual(
            Set(keychain.accounts.keys),
            Set(["\(prefixB).secret.access_token", "\(prefixB).domains"]),
            "deleting an unshared profile must not clear another profile's device-only Reader state"
        )
        XCTAssertTrue(try ReaderExtensionPersistence.loadPendingAuthenticationCleanup(from: journal).isEmpty)
    }

    func testAccountBoundaryNamespaceCleanupCoversEveryOutgoingProfile() throws {
        let profileA = UUID()
        let profileB = UUID()
        let sourceA = installedSource(implementation: .javascript).id
        var second = installedSource(implementation: .javascript)
        second.upstreamID = "owned-account-boundary-second"
        second.id = ReaderExtensionSourceID(
            repositoryURL: second.repositoryURL,
            upstreamID: second.upstreamID,
            language: second.language,
            mediaType: second.mediaType
        )
        let keychain = ReaderExtensionInjectedKeychainAccess(accounts: [
            "\(profileA.uuidString).\(sourceA.rawValue).secret.access_token": Data("a".utf8),
            "\(profileA.uuidString).\(second.id.rawValue).cookies": Data("b".utf8),
            "\(profileB.uuidString).\(sourceA.rawValue).domains": Data("c".utf8),
            "\(profileB.uuidString).\(second.id.rawValue).secret.session_cookie": Data("d".utf8)
        ])
        let suiteName = "ReaderExtensionBoundaryCleanup.\(UUID().uuidString)"
        let journal = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { journal.removePersistentDomain(forName: suiteName) }

        let result = try ReaderExtensionProfileAuthenticationLifecycle
            .prepareForProfileStoreDeletion(
                profileIDs: [profileA, profileB],
                journalStore: journal,
                keychain: keychain
            )

        XCTAssertTrue(result.isFullyClean)
        XCTAssertTrue(keychain.accounts.isEmpty)
        XCTAssertTrue(try ReaderExtensionPersistence.loadPendingAuthenticationCleanup(from: journal).isEmpty)
    }

    func testFailedProfileNamespaceCleanupStaysDurableAndBlocksSameUUIDUntilRetry() throws {
        let profileID = UUID()
        let sourceID = installedSource(implementation: .javascript).id
        let account = "\(profileID.uuidString).\(sourceID.rawValue).secret.access_token"
        let failingKeychain = ReaderExtensionInjectedKeychainAccess(
            accounts: [account: Data("must-not-resurrect".utf8)],
            deletionFailure: errSecInteractionNotAllowed
        )
        let suiteName = "ReaderExtensionProfileCleanupRetry.\(UUID().uuidString)"
        let journal = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { journal.removePersistentDomain(forName: suiteName) }
        let staleStore = ReaderExtensionKeychainStore(
            sourceID: sourceID,
            namespace: profileID.uuidString,
            keychain: failingKeychain
        )

        let result = try ReaderExtensionProfileAuthenticationLifecycle
            .prepareForProfileStoreDeletion(
                profileIDs: [profileID],
                journalStore: journal,
                keychain: failingKeychain
            )
        XCTAssertNotNil(result.firstError)
        let pending = try ReaderExtensionPersistence.loadPendingAuthenticationCleanup(from: journal)
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(try XCTUnwrap(pending.first).isNamespaceWide)
        XCTAssertTrue(try XCTUnwrap(pending.first).applies(
            to: sourceID,
            namespace: profileID.uuidString
        ))
        XCTAssertThrowsError(try staleStore.setSecret("late-write", for: "access_token"))
        XCTAssertEqual(failingKeychain.accounts[account], Data("must-not-resurrect".utf8))

        let retryKeychain = ReaderExtensionInjectedKeychainAccess(
            accounts: failingKeychain.accounts
        )
        let retryError = try ReaderExtensionAuthenticationCleanupJournal.retry(
            store: journal,
            sourceIDs: [sourceID],
            namespaces: [profileID.uuidString]
        ) { entry in
            XCTAssertTrue(entry.isNamespaceWide)
            try ReaderExtensionKeychainStore.removeAllDeviceState(
                inNamespace: entry.namespace,
                keychain: retryKeychain
            )
        }
        XCTAssertNil(retryError)
        XCTAssertTrue(retryKeychain.accounts.isEmpty)
        XCTAssertTrue(try ReaderExtensionPersistence.loadPendingAuthenticationCleanup(from: journal).isEmpty)
    }

    func testProfileNamespaceCleanupRefusesDeletionWhenJournalCheckpointFails() throws {
        let profileID = UUID()
        let sourceID = installedSource(implementation: .javascript).id
        let account = "\(profileID.uuidString).\(sourceID.rawValue).secret.access_token"
        let keychain = ReaderExtensionInjectedKeychainAccess(
            accounts: [account: Data("retained".utf8)]
        )
        let suiteName = "ReaderExtensionProfileCleanupCheckpoint.\(UUID().uuidString)"
        let journal = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { journal.removePersistentDomain(forName: suiteName) }

        XCTAssertThrowsError(try ReaderExtensionProfileAuthenticationLifecycle
            .prepareForProfileStoreDeletion(
                profileIDs: [profileID],
                journalStore: journal,
                keychain: keychain,
                checkpoint: { _ in false }
            ))
        XCTAssertEqual(keychain.accounts[account], Data("retained".utf8))
        XCTAssertNil(journal.object(forKey: ReaderExtensionPersistence.pendingAuthenticationCleanupKey))
    }

    func testOutgoingProfileRevocationRejectsHeldAuthenticatedClientSecondUse() throws {
        let sourceID = installedSource(implementation: .javascript).id
        let profileA = UUID().uuidString
        let profileB = UUID().uuidString
        let heldProfileAClient = ReaderExtensionSecureHTTPClient(
            keychainNamespace: profileA,
            authenticationSourceID: sourceID
        )
        let profileBClient = ReaderExtensionSecureHTTPClient(
            keychainNamespace: profileB,
            authenticationSourceID: sourceID
        )
        XCTAssertNoThrow(try heldProfileAClient.validateAuthenticationAdmission(for: sourceID))
        XCTAssertNoThrow(try profileBClient.validateAuthenticationAdmission(for: sourceID))

        ReaderExtensionAuthenticationGenerationRegistry.revokeNamespace(profileA)

        XCTAssertThrowsError(try heldProfileAClient.validateAuthenticationAdmission(for: sourceID))
        XCTAssertNoThrow(
            try profileBClient.validateAuthenticationAdmission(for: sourceID),
            "revoking the outgoing namespace must not invalidate the newly active profile"
        )
    }

    func testHeldAsyncMutationCannotPublishAfterProfileScopeChanges() async throws {
        let profileA = UUID().uuidString
        let profileB = UUID().uuidString
        let captured = ReaderExtensionManagerMutationScope(
            scopeID: "profile:\(profileA)",
            authenticationNamespace: profileA,
            authenticationNamespaceGeneration: 7
        )
        let switched = ReaderExtensionManagerMutationScope(
            scopeID: "profile:\(profileB)",
            authenticationNamespace: profileB,
            authenticationNamespaceGeneration: 0
        )
        let network = ReaderExtensionBlockingAdmissionNetwork()
        let request = ReaderExtensionNetworkRequest(
            url: URL(string: "https://93.184.216.34/held-profile-mutation")!,
            sourceID: installedSource(implementation: .javascript).id,
            approvedDomains: ["93.184.216.34"],
            baseDomain: "93.184.216.34",
            allowsCookies: false
        )
        let operation = Task {
            _ = try await network.request(request)
            try ReaderExtensionManagerMutationScopePolicy.validate(
                captured,
                current: switched
            )
        }

        XCTAssertEqual(network.entered.wait(timeout: .now() + 1), .success)
        network.release.signal()
        do {
            try await operation.value
            XCTFail("a mutation resumed under another Reader profile")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .runtimeUnavailable)
        }

        let returnedToSameUUID = ReaderExtensionManagerMutationScope(
            scopeID: captured.scopeID,
            authenticationNamespace: captured.authenticationNamespace,
            authenticationNamespaceGeneration: captured.authenticationNamespaceGeneration + 1
        )
        XCTAssertThrowsError(try ReaderExtensionManagerMutationScopePolicy.validate(
            captured,
            current: returnedToSameUUID
        ), "an A -> B -> A transition must not revive a suspended mutation")
    }

    func testRevokedKeychainStoreCannotRecreateAuthenticationAfterVerifiedCleanup() throws {
        let sourceID = installedSource(implementation: .javascript).id
        let namespace = UUID().uuidString
        let keychain = ReaderExtensionInjectedKeychainAccess(accounts: [:])
        let staleStore = ReaderExtensionKeychainStore(
            sourceID: sourceID,
            namespace: namespace,
            keychain: keychain
        )
        try staleStore.setSecret("owned-secret", for: "api_token")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "owned-session",
            .value: "owned-cookie",
            .domain: "example.com",
            .path: "/",
            .secure: "TRUE"
        ]))
        try staleStore.setCookies([cookie])

        ReaderExtensionAuthenticationGenerationRegistry.revoke(
            sourceID: sourceID,
            namespace: namespace
        )
        let cleanupStore = ReaderExtensionKeychainStore(
            sourceID: sourceID,
            namespace: namespace,
            keychain: keychain
        )
        try cleanupStore.removeAuthenticationState()
        XCTAssertTrue(keychain.accounts.isEmpty)
        XCTAssertThrowsError(try staleStore.setSecret("recreated", for: "api_token"))
        XCTAssertThrowsError(try staleStore.setCookies([cookie]))
        XCTAssertThrowsError(try staleStore.secret(for: "api_token"))
        XCTAssertTrue(staleStore.cookies().isEmpty)
        XCTAssertTrue(keychain.accounts.isEmpty)
    }

    func testRevocationSerializesConcurrentWriterBeforeCleanupDeletesItsResult() throws {
        let sourceID = installedSource(implementation: .javascript).id
        let namespace = UUID().uuidString
        let addEntered = DispatchSemaphore(value: 0)
        let releaseAdd = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)
        let revokeDone = DispatchSemaphore(value: 0)
        let keychain = ReaderExtensionInjectedKeychainAccess(
            accounts: [:],
            beforeAdd: {
                addEntered.signal()
                _ = releaseAdd.wait(timeout: .now() + 2)
            }
        )
        let staleStore = ReaderExtensionKeychainStore(
            sourceID: sourceID,
            namespace: namespace,
            keychain: keychain
        )

        DispatchQueue.global().async {
            try? staleStore.setSecret("in-flight-secret", for: "api_token")
            writerDone.signal()
        }
        XCTAssertEqual(addEntered.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            ReaderExtensionAuthenticationGenerationRegistry.revoke(
                sourceID: sourceID,
                namespace: namespace
            )
            revokeDone.signal()
        }
        XCTAssertEqual(
            revokeDone.wait(timeout: .now() + 0.1),
            .timedOut,
            "revocation must wait for the generation-checked Keychain mutation to finish"
        )
        releaseAdd.signal()
        XCTAssertEqual(writerDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(revokeDone.wait(timeout: .now() + 1), .success)

        let cleanupStore = ReaderExtensionKeychainStore(
            sourceID: sourceID,
            namespace: namespace,
            keychain: keychain
        )
        try cleanupStore.removeAuthenticationState()
        XCTAssertTrue(keychain.accounts.isEmpty)
        XCTAssertThrowsError(try staleStore.setSecret("late-secret", for: "api_token"))
        XCTAssertTrue(keychain.accounts.isEmpty)
    }

    func testRevokedAuthenticatedHTTPClientRejectsBeforeDispatch() throws {
        let sourceID = installedSource(implementation: .javascript).id
        let namespace = UUID().uuidString
        let client = ReaderExtensionSecureHTTPClient(
            keychainNamespace: namespace,
            authenticationSourceID: sourceID
        )
        XCTAssertNoThrow(try client.validateAuthenticationAdmission(for: sourceID))

        ReaderExtensionAuthenticationGenerationRegistry.revoke(
            sourceID: sourceID,
            namespace: namespace
        )
        XCTAssertThrowsError(try client.validateAuthenticationAdmission(for: sourceID)) { error in
            guard case ReaderExtensionError.persistenceFailed = error else {
                XCTFail("expected revoked authentication admission, got \(error)")
                return
            }
        }
        let otherSourceID = ReaderExtensionSourceID(
            repositoryURL: publicBaseURL.appendingPathComponent("other-index.json"),
            upstreamID: "other-source",
            language: "en",
            mediaType: .manga
        )
        XCTAssertThrowsError(try client.validateAuthenticationAdmission(for: otherSourceID))
    }

    func testPermissiveNativeBackupRemainsInertUntilCatalogRevalidation() throws {
        try preservingGlobalReaderExtensionSettings {
            let source = installedSource(implementation: .madara)
            XCTAssertTrue(source.isRunnable)
            let envelope = try BackupReaderExtensionState(snapshot: ReaderExtensionBackupSnapshot(
                repositories: [],
                installedSources: [source],
                showMatureSources: false,
                autoUpdateSources: true,
                lastAutoUpdate: nil
            ))
            let portable = try envelope.runtimeSnapshot()
            let restored = try XCTUnwrap(portable.installedSources.first)
            XCTAssertEqual(restored.license.kind, .mit)
            XCTAssertTrue(restored.requiresReinstall)
            XCTAssertFalse(restored.isRunnable)
            XCTAssertThrowsError(try ReaderExtensionProviderAdmissionPolicy.validate(restored))

            let suiteName = "ReaderExtensionPermissiveRestoreTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            try envelope.restore(to: defaults, preferenceStore: defaults)
            let persisted = try XCTUnwrap(
                ReaderExtensionPersistence.loadInstalledSources(from: defaults).first
            )
            XCTAssertTrue(persisted.requiresReinstall)
            XCTAssertFalse(persisted.isRunnable)
        }
    }

    func testPortableRestoreRetainsOnlyExactVerifiedLocalRuntime() throws {
        try preservingGlobalReaderExtensionSettings {
            let suiteName = "ReaderExtensionTrustedLocalRestoreTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            var local = installedSource(implementation: .madara)
            local.preferences = ["reader_theme": .string("local")]
            var portable = local.metadataForBackup()
            portable.preferences = ["reader_theme": .string("cloud")]
            let exactSnapshot = ReaderExtensionBackupSnapshot(
                repositories: [],
                installedSources: [portable],
                showMatureSources: false,
                autoUpdateSources: true,
                lastAutoUpdate: nil
            )
            try ReaderExtensionPersistence.restorePortableMetadata(
                exactSnapshot,
                retainingVerifiedRuntimeFrom: [local],
                to: defaults,
                preferenceStore: defaults
            )
            let exactMetadata = try ReaderExtensionPersistence.loadInstalledSources(from: defaults)
            let exact = try XCTUnwrap(ReaderExtensionPersistence.applyingPreferenceOverlay(
                to: exactMetadata,
                from: defaults
            ).first)
            XCTAssertFalse(exact.requiresReinstall)
            XCTAssertTrue(exact.isRunnable)
            XCTAssertEqual(exact.preferences["reader_theme"], .string("cloud"))

            var changed = portable
            changed.version = "2.0.0"
            try ReaderExtensionPersistence.restorePortableMetadata(
                ReaderExtensionBackupSnapshot(
                    repositories: [],
                    installedSources: [changed],
                    showMatureSources: false,
                    autoUpdateSources: true,
                    lastAutoUpdate: nil
                ),
                retainingVerifiedRuntimeFrom: [local],
                to: defaults,
                preferenceStore: defaults
            )
            let changedMetadata = try ReaderExtensionPersistence.loadInstalledSources(from: defaults)
            let changedRestored = try XCTUnwrap(ReaderExtensionPersistence.applyingPreferenceOverlay(
                to: changedMetadata,
                from: defaults
            ).first)
            XCTAssertTrue(changedRestored.requiresReinstall)
            XCTAssertFalse(changedRestored.isRunnable)

            var craftedScript = installedSource(implementation: .javascript)
            craftedScript.activeContentDigest = String(repeating: "d", count: 64)
            craftedScript.requiresReinstall = false
            try ReaderExtensionPersistence.restorePortableMetadata(
                ReaderExtensionBackupSnapshot(
                    repositories: [],
                    installedSources: [craftedScript],
                    showMatureSources: false,
                    autoUpdateSources: true,
                    lastAutoUpdate: nil
                ),
                retainingVerifiedRuntimeFrom: [],
                to: defaults,
                preferenceStore: defaults
            )
            let craftedMetadata = try ReaderExtensionPersistence.loadInstalledSources(from: defaults)
            let crafted = try XCTUnwrap(ReaderExtensionPersistence.applyingPreferenceOverlay(
                to: craftedMetadata,
                from: defaults
            ).first)
            XCTAssertNil(crafted.activeContentDigest)
            XCTAssertTrue(crafted.requiresReinstall)
            XCTAssertFalse(crafted.isRunnable)
        }
    }

    func testPortableRestoreRejectsLocalRuntimeWhenLanguageSelectionProvenanceDiffers() throws {
        try preservingGlobalReaderExtensionSettings {
            let suiteName = "ReaderExtensionLanguageProvenanceRestoreTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            var local = installedSource(implementation: .javascript)
            local.languageSelectionVersion = ReaderExtensionLanguageCompatibilityPolicy
                .explicitSelectionVersion
            local.activeContentDigest = String(repeating: "a", count: 64)
            var previous = local
            previous.activeContentDigest = String(repeating: "b", count: 64)
            local.rollbackSourceSnapshot = ReaderExtensionInstalledSourceRollbackSnapshot(
                source: previous
            )
            local.rollbackContentDigest = previous.activeContentDigest
            local.declaredDomains = ["provider.example"]

            var portable = local.metadataForBackup()
            portable.languageSelectionVersion = nil
            try ReaderExtensionPersistence.restorePortableMetadata(
                ReaderExtensionBackupSnapshot(
                    repositories: [],
                    installedSources: [portable],
                    showMatureSources: false,
                    autoUpdateSources: true,
                    lastAutoUpdate: nil
                ),
                retainingVerifiedRuntimeFrom: [local],
                to: defaults,
                preferenceStore: defaults
            )

            let restored = try XCTUnwrap(
                ReaderExtensionPersistence.loadInstalledSources(from: defaults).first
            )
            XCTAssertNil(restored.languageSelectionVersion)
            XCTAssertNil(restored.activeContentDigest)
            XCTAssertNil(restored.rollbackContentDigest)
            XCTAssertNil(restored.rollbackSourceSnapshot)
            XCTAssertTrue(restored.declaredDomains.isEmpty)
            XCTAssertTrue(restored.requiresReinstall)
            XCTAssertFalse(restored.isRunnable)
        }
    }

    func testBackupRuntimeMergeRejectsLocalRuntimeWhenLanguageSelectionProvenanceDiffers() throws {
        var local = installedSource(implementation: .javascript)
        local.languageSelectionVersion = ReaderExtensionLanguageCompatibilityPolicy
            .explicitSelectionVersion
        local.activeContentDigest = String(repeating: "c", count: 64)
        var previous = local
        previous.activeContentDigest = String(repeating: "d", count: 64)
        local.rollbackSourceSnapshot = ReaderExtensionInstalledSourceRollbackSnapshot(
            source: previous
        )
        local.rollbackContentDigest = previous.activeContentDigest
        local.declaredDomains = ["provider.example"]

        var portable = local.metadataForBackup()
        portable.languageSelectionVersion = nil
        let merged = BackupReaderExtensionState.mergingVerifiedLocalRuntime(
            into: ReaderExtensionBackupSnapshot(
                repositories: [],
                installedSources: [portable],
                showMatureSources: false,
                autoUpdateSources: true,
                lastAutoUpdate: nil
            ),
            localSources: [local]
        )

        let restored = try XCTUnwrap(merged.installedSources.first)
        XCTAssertNil(restored.languageSelectionVersion)
        XCTAssertNil(restored.activeContentDigest)
        XCTAssertNil(restored.rollbackContentDigest)
        XCTAssertNil(restored.rollbackSourceSnapshot)
        XCTAssertTrue(restored.declaredDomains.isEmpty)
        XCTAssertTrue(restored.requiresReinstall)
        XCTAssertFalse(restored.isRunnable)
    }

    func testDisabledVerifiedSourceCanConfigureWithoutBecomingRuntimeRunnable() throws {
        var native = installedSource(implementation: .madara)
        native.enabled = false
        XCTAssertFalse(native.isRunnable)
        XCTAssertNoThrow(try ReaderExtensionProviderAdmissionPolicy.validate(
            native,
            requiresEnabled: false
        ))
        XCTAssertThrowsError(try ReaderExtensionProviderAdmissionPolicy.validate(native))

        native.requiresReinstall = true
        XCTAssertThrowsError(try ReaderExtensionProviderAdmissionPolicy.validate(
            native,
            requiresEnabled: false
        ))

        var script = installedSource(implementation: .javascript)
        script.enabled = false
        script.activeContentDigest = nil
        XCTAssertThrowsError(try ReaderExtensionProviderAdmissionPolicy.validate(
            script,
            requiresEnabled: false
        ))
        script.activeContentDigest = String(repeating: "c", count: 64)
        XCTAssertNoThrow(try ReaderExtensionProviderAdmissionPolicy.validate(
            script,
            requiresEnabled: false
        ))
        script.license.kind = .restrictive
        XCTAssertThrowsError(try ReaderExtensionProviderAdmissionPolicy.validate(
            script,
            requiresEnabled: false
        ))
    }

    func testRestrictiveNativeBackupRestoreFailsBeforeChangingExistingMetadata() throws {
        try preservingGlobalReaderExtensionSettings {
            let suiteName = "ReaderExtensionRestrictiveRestoreTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let baseline = installedSource(implementation: .madara)
            try ReaderExtensionPersistence.persist(
                repositories: [],
                installedSources: [baseline],
                showMature: false,
                autoUpdate: true,
                lastAutoUpdate: nil,
                to: defaults,
                preferenceStore: defaults
            )
            let priorSources = defaults.data(forKey: ReaderExtensionPersistence.installedSourcesKey)
            let priorOverlay = defaults.data(forKey: ReaderExtensionPersistence.preferenceOverlayKey)

            var prohibited = baseline
            prohibited.enabled = true
            prohibited.license = ReaderExtensionLicense(
                kind: .restrictive,
                name: "Non-commercial/no-derivatives only",
                url: nil,
                textSHA256: nil,
                detectedAt: Date()
            )
            XCTAssertFalse(prohibited.isRunnable)
            XCTAssertThrowsError(try ReaderExtensionProviderAdmissionPolicy.validate(prohibited))
            let envelope = try BackupReaderExtensionState(snapshot: ReaderExtensionBackupSnapshot(
                repositories: [],
                installedSources: [prohibited],
                showMatureSources: true,
                autoUpdateSources: false,
                lastAutoUpdate: Date()
            ))

            XCTAssertThrowsError(try envelope.restore(to: defaults, preferenceStore: defaults)) { error in
                guard case ReaderExtensionError.restrictiveLicense = error else {
                    return XCTFail("unexpected restore error: \(error)")
                }
            }
            XCTAssertEqual(defaults.data(forKey: ReaderExtensionPersistence.installedSourcesKey), priorSources)
            XCTAssertEqual(defaults.data(forKey: ReaderExtensionPersistence.preferenceOverlayKey), priorOverlay)
            XCTAssertEqual(try ReaderExtensionPersistence.loadInstalledSources(from: defaults).first?.license.kind, .mit)

            var restrictiveRepository = ReaderExtensionRepositoryRecord(
                indexURL: publicBaseURL.appendingPathComponent("restrictive/index.json"),
                name: "Restricted repository"
            )
            restrictiveRepository.license = prohibited.license
            let repositoryEnvelope = try BackupReaderExtensionState(snapshot: ReaderExtensionBackupSnapshot(
                repositories: [restrictiveRepository],
                installedSources: [baseline],
                showMatureSources: true,
                autoUpdateSources: false,
                lastAutoUpdate: Date()
            ))
            XCTAssertThrowsError(
                try repositoryEnvelope.restore(to: defaults, preferenceStore: defaults)
            ) { error in
                guard case ReaderExtensionError.restrictiveLicense = error else {
                    return XCTFail("unexpected repository restore error: \(error)")
                }
            }
            XCTAssertEqual(defaults.data(forKey: ReaderExtensionPersistence.installedSourcesKey), priorSources)
            XCTAssertEqual(defaults.data(forKey: ReaderExtensionPersistence.preferenceOverlayKey), priorOverlay)
        }
    }

    func testPortableRestoreScrubsUnsafeOptionalMetadataURLs() throws {
        let suiteName = "ReaderExtensionMetadataURLRestoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let safeWebsite = try XCTUnwrap(URL(string: "https://example.com/reader-extensions"))
        let safeLicenseURL = try XCTUnwrap(URL(string: "https://example.com/licenses/MIT"))
        let safeLicense = ReaderExtensionLicense(
            kind: .mit,
            name: "MIT",
            url: safeLicenseURL,
            textSHA256: String(repeating: "a", count: 64),
            detectedAt: .distantPast
        )
        var safeRepository = ReaderExtensionRepositoryRecord(
            indexURL: publicBaseURL.appendingPathComponent("safe/index.json"),
            name: "Safe repository",
            websiteURL: safeWebsite,
            license: safeLicense
        )
        safeRepository.errorMessage = "not retained"

        let fileURL = URL(fileURLWithPath: "/tmp/owned-reader-license")
        let credentialURL = try XCTUnwrap(
            URL(string: "https://example.com/licenses/MIT?access_token=owned-secret")
        )
        var unsafeRepository = ReaderExtensionRepositoryRecord(
            indexURL: publicBaseURL.appendingPathComponent("unsafe/index.json"),
            name: "Unsafe repository",
            websiteURL: fileURL,
            license: ReaderExtensionLicense(
                kind: .mit,
                name: "MIT",
                url: credentialURL,
                textSHA256: String(repeating: "b", count: 64),
                detectedAt: .distantPast
            )
        )
        unsafeRepository.errorMessage = nil

        var source = installedSource(implementation: .madara)
        source.license.url = credentialURL
        let snapshot = ReaderExtensionBackupSnapshot(
            repositories: [safeRepository, unsafeRepository],
            installedSources: [source],
            showMatureSources: false,
            autoUpdateSources: true,
            lastAutoUpdate: nil
        )
        try ReaderExtensionPersistence.restorePortableMetadata(
            snapshot,
            retainingVerifiedRuntimeFrom: [],
            to: defaults,
            preferenceStore: defaults
        )

        let repositories = try ReaderExtensionPersistence.loadRepositories(from: defaults)
        let restoredSafe = try XCTUnwrap(repositories.first(where: { $0.id == safeRepository.id }))
        let restoredUnsafe = try XCTUnwrap(repositories.first(where: { $0.id == unsafeRepository.id }))
        XCTAssertEqual(restoredSafe.websiteURL, safeWebsite)
        XCTAssertEqual(restoredSafe.license.url, safeLicenseURL)
        XCTAssertNil(restoredUnsafe.websiteURL)
        XCTAssertNil(restoredUnsafe.license.url)
        XCTAssertNil(try XCTUnwrap(
            ReaderExtensionPersistence.loadInstalledSources(from: defaults).first
        ).license.url)

        XCTAssertNil(ReaderExtensionSecurityPolicy.sanitizedMetadataDisplayURL(fileURL))
        XCTAssertNil(ReaderExtensionSecurityPolicy.sanitizedMetadataDisplayURL(credentialURL))
        XCTAssertEqual(
            ReaderExtensionSecurityPolicy.sanitizedMetadataDisplayURL(safeWebsite),
            safeWebsite
        )
        let encoded = String(
            data: try JSONEncoder().encode(ReaderExtensionBackupSnapshot(
                repositories: repositories,
                installedSources: try ReaderExtensionPersistence.loadInstalledSources(from: defaults),
                showMatureSources: false,
                autoUpdateSources: true,
                lastAutoUpdate: nil
            )),
            encoding: .utf8
        ) ?? ""
        XCTAssertFalse(encoded.contains("access_token"))
        XCTAssertFalse(encoded.contains("file:"))
    }

    func testBackupAndRestoreRedactSchemaHeuristicAndMalformedPreferenceMetadata() throws {
        var source = installedSource(implementation: .javascript)
        source.secretPreferenceKeys = ["login_name"]
        source.preferences = [
            "login_name": .string("owned-schema-secret"),
            "api_token": .string("owned-heuristic-secret"),
            "reader_theme": .string("sepia"),
            "marker": .secretReference("owned-marker-secret"),
            "oversized": .string(String(repeating: "x", count: ReaderExtensionSecurityPolicy.maximumPreferenceValueBytes + 1))
        ]

        let suiteName = "ReaderExtensionCoreTests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }
        let global = UserDefaults.standard
        let globalKeys = [
            ReaderExtensionPersistence.showMatureSourcesKey,
            ReaderExtensionPersistence.autoUpdateSourcesKey,
            ReaderExtensionPersistence.lastAutoUpdateKey
        ]
        let priorGlobals = Dictionary(uniqueKeysWithValues: globalKeys.map { ($0, global.object(forKey: $0)) })
        defer {
            for key in globalKeys {
                if let value = priorGlobals[key] ?? nil { global.set(value, forKey: key) }
                else { global.removeObject(forKey: key) }
            }
        }

        let malicious = ReaderExtensionBackupSnapshot(
            repositories: [],
            installedSources: [source],
            showMatureSources: false,
            autoUpdateSources: true,
            lastAutoUpdate: nil
        )
        try ReaderExtensionPersistence.restoreMetadata(malicious, to: store)
        let restored = try XCTUnwrap(ReaderExtensionPersistence.loadInstalledSources(from: store).first)
        XCTAssertEqual(restored.preferences, ["reader_theme": .string("sepia")])
        XCTAssertEqual(restored.secretPreferenceKeys, Set(["login_name"]))

        // Re-seed stale on-disk metadata so this independently exercises the
        // static snapshot path used directly by BackupManager, rather than
        // merely backing up the already-sanitized restore result.
        let staleEncoder = JSONEncoder()
        staleEncoder.dateEncodingStrategy = .millisecondsSince1970
        staleEncoder.outputFormatting = [.sortedKeys]
        store.set(try staleEncoder.encode([source]), forKey: ReaderExtensionPersistence.installedSourcesKey)
        let snapshot = try ReaderExtensionPersistence.backupSnapshot(from: store)
        XCTAssertEqual(snapshot.installedSources.first?.preferences, ["reader_theme": .string("sepia")])
        let encoded = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("owned-schema-secret"))
        XCTAssertFalse(encoded.contains("owned-heuristic-secret"))
        XCTAssertFalse(encoded.contains("owned-marker-secret"))
        XCTAssertTrue(encoded.contains("login_name"), "safe schema key names must survive metadata-only backup")
    }

    func testQuarantineAndGlobalNonDrainingBreakerRejectBeforeExecution() async throws {
        var source = installedSource(implementation: .javascript)
        let script = Data("class DefaultExtension extends MProvider {}".utf8)
        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        source.activeContentDigest = digest
        ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
            true,
            sourceID: source.id,
            digest: digest
        )
        defer {
            ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
                false,
                sourceID: source.id,
                digest: digest
            )
            ReaderExtensionJavaScriptRuntime.setNonDrainingOperationCountForTesting(0)
        }
        do {
            _ = try await ReaderExtensionJavaScriptRuntime.execute(
                scriptData: script,
                source: source,
                operation: .popular(1),
                network: ReaderExtensionDenyNetworkClient(),
                approvedDomains: [],
                preferenceStore: ReaderExtensionInMemoryPreferenceStore()
            )
            XCTFail("quarantined content executed")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .sourceQuarantined)
        }

        ReaderExtensionJavaScriptRuntime.setQuarantinedForTesting(
            false,
            sourceID: source.id,
            digest: digest
        )
        ReaderExtensionJavaScriptRuntime.setNonDrainingOperationCountForTesting(2)
        do {
            _ = try await ReaderExtensionJavaScriptRuntime.execute(
                scriptData: script,
                source: source,
                operation: .popular(1),
                network: ReaderExtensionDenyNetworkClient(),
                approvedDomains: [],
                preferenceStore: ReaderExtensionInMemoryPreferenceStore()
            )
            XCTFail("global non-draining breaker admitted work")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .runtimeUnavailable)
        }
    }

    func testConcurrentRuntimeAdmissionRunsToItsCeilingThenQueues() async throws {
        let script = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) {
            await new Client().get('https://93.184.216.34/owned-admission-hold');
            return {list: [], hasNextPage: false};
          }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: 'Owned Fixture', chapters: []}; }
          async getPageList(url) { return []; }
        }
        """.utf8)
        let ceiling = ReaderExtensionSecurityPolicy.maximumConcurrentRuntimeOperations
        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        let sources = (0...ceiling).map { index -> ReaderExtensionInstalledSource in
            var source = installedSource(implementation: .javascript)
            source.upstreamID = "admission-fixture-\(index)"
            source.id = ReaderExtensionSourceID(
                repositoryURL: source.repositoryURL,
                upstreamID: source.upstreamID,
                language: source.language,
                mediaType: source.mediaType
            )
            source.activeContentDigest = digest
            return source
        }
        let network = ReaderExtensionBlockingAdmissionNetwork()
        let tasks = sources.map { source in
            Task {
                try await ReaderExtensionJavaScriptRuntime.execute(
                    scriptData: script,
                    source: source,
                    operation: .popular(1),
                    network: network,
                    approvedDomains: ["93.184.216.34"],
                    preferenceStore: ReaderExtensionInMemoryPreferenceStore()
                )
            }
        }

        // Independent sources browse in parallel up to the runtime ceiling.
        // The stuck-worker budget is a separate, smaller degradation
        // threshold and must not double as the concurrency limit.
        for _ in 0..<ceiling {
            XCTAssertEqual(network.entered.wait(timeout: .now() + 4), .success)
        }
        XCTAssertEqual(
            network.entered.wait(timeout: .now() + 0.25),
            .timedOut,
            "admission exceeded the concurrent runtime ceiling"
        )

        network.release.signal()
        XCTAssertEqual(
            network.entered.wait(timeout: .now() + 4),
            .success,
            "a drained worker should admit the queued source"
        )
        for _ in 0...ceiling { network.release.signal() }
        for task in tasks { _ = try await task.value }
    }

    func testSameSourceWaiterDoesNotConsumeIndependentRuntimePermit() throws {
        let gate = ReaderExtensionRuntimeAdmissionGate(maximumConcurrentOperations: 2)
        let sourceA = installedSource(implementation: .javascript).id
        var sourceBFixture = installedSource(implementation: .javascript)
        sourceBFixture.upstreamID = "independent-runtime-source"
        sourceBFixture.id = ReaderExtensionSourceID(
            repositoryURL: sourceBFixture.repositoryURL,
            upstreamID: sourceBFixture.upstreamID,
            language: sourceBFixture.language,
            mediaType: sourceBFixture.mediaType
        )
        let sourceB = sourceBFixture.id
        let firstA = try XCTUnwrap(gate.acquire(sourceID: sourceA, timeout: 1))
        let secondACompleted = DispatchSemaphore(value: 0)
        let secondALease = ReaderExtensionAdmissionLeaseBox()
        DispatchQueue.global().async {
            let lease = gate.acquire(sourceID: sourceA, timeout: 2)
            secondALease.set(lease)
            secondACompleted.signal()
        }

        let waiterDeadline = Date().addingTimeInterval(1)
        while gate.waiterCountForTesting(sourceID: sourceA) == 0,
              Date() < waiterDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertEqual(gate.waiterCountForTesting(sourceID: sourceA), 1)

        let independent = gate.acquire(sourceID: sourceB, timeout: 0.25)
        XCTAssertNotNil(
            independent,
            "a queued call for source A must not hold the last global permit needed by source B"
        )
        independent?.release()
        XCTAssertEqual(secondACompleted.wait(timeout: .now() + 0.05), .timedOut)

        firstA.release()
        XCTAssertEqual(secondACompleted.wait(timeout: .now() + 1), .success)
        let acquiredSecondA = secondALease.value
        XCTAssertNotNil(acquiredSecondA)
        acquiredSecondA?.release()
    }

    func testContentAddressedActivationAndLastKnownGoodRetention() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ReaderExtensionContentStore(rootURL: root)
        let first = Data("class DefaultExtension extends MProvider { getPopular() {} }".utf8)
        let second = Data("class DefaultExtension extends MProvider { getPopular() {}; search() {} }".utf8)
        let firstDigest = try store.activate(store.stageExactScript(first))
        let secondDigest = try store.activate(store.stageExactScript(second))
        XCTAssertNotEqual(firstDigest, secondDigest)
        XCTAssertEqual(try store.scriptData(digest: firstDigest), first)
        XCTAssertEqual(try store.scriptData(digest: secondDigest), second)
        store.removeUnreferencedContent(keeping: [firstDigest, secondDigest])
        XCTAssertEqual(try store.scriptData(digest: firstDigest), first, "last-known-good bytes must remain exact")

        let corruptURL = store.contentURL.appendingPathComponent("\(secondDigest).js")
        try Data("corrupt".utf8).write(to: corruptURL, options: .atomic)
        XCTAssertEqual(
            try store.activate(store.stageExactScript(second)),
            secondDigest,
            "an exact equal-version reinstall must replace a corrupt content-addressed blob"
        )
        XCTAssertEqual(try store.scriptData(digest: secondDigest), second)
    }

    func testReaderDownloadAuthenticationScopeIsExplicitAndLegacyRowsFailClosed() throws {
        let profileA = UUID()
        let profileB = UUID()
        let provider = ReaderDownloadProvider(
            kind: .readerExtension,
            sourceId: String(repeating: "a", count: 64),
            mangaKey: "/owned/title",
            moduleUUID: nil,
            contentParams: nil,
            isNovel: false,
            chapterParams: "/owned/chapter/1",
            authenticationProfileID: profileA
        )
        XCTAssertTrue(ReaderDownloadManager.authenticationScopeAllowsExecution(
            provider,
            activeProfileID: profileA
        ))
        XCTAssertFalse(ReaderDownloadManager.authenticationScopeAllowsExecution(
            provider,
            activeProfileID: profileB
        ))

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(provider)) as? [String: Any]
        )
        object.removeValue(forKey: "authenticationProfileID")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(ReaderDownloadProvider.self, from: legacyData)
        XCTAssertNil(legacy.authenticationProfileID)
        XCTAssertFalse(ReaderDownloadManager.authenticationScopeAllowsExecution(
            legacy,
            activeProfileID: profileA
        ))
    }

    func testReaderLogsRedactCollapsedCredentialNamesAndDownloadMetadata() {
        let input = "access_token=owned-a session_cookie:owned-b client-secret=owned-c x-api-key=owned-d credential=owned-e"
        let redacted = ReaderLogger.redact(input)
        for secret in ["owned-a", "owned-b", "owned-c", "owned-d", "owned-e"] {
            XCTAssertFalse(redacted.contains(secret))
        }
        XCTAssertGreaterThanOrEqual(
            redacted.components(separatedBy: "<redacted>").count - 1,
            5
        )
    }

    func testReaderLogsRemoveURLCredentialsPathsQueriesAndFragments() {
        let input = "request=https://reader-user:owned-password@example.com/private/owned-path?token=owned-query#owned-fragment"
        let redacted = ReaderLogger.redact(input)

        XCTAssertTrue(redacted.contains("example.com"))
        for secret in ["reader-user", "owned-password", "owned-path", "owned-query", "owned-fragment"] {
            XCTAssertFalse(redacted.contains(secret))
        }
    }

    func testReaderExtensionDiagnosticsOmitProviderControlledValues() {
        let label = ReaderExtensionDiagnostics.safeLabel(
            "Owned Source https://reader-user:owned-password@example.com/private access_token=owned-token\nnext"
        )
        XCTAssertTrue(label.contains("Owned Source"))
        XCTAssertTrue(label.contains("<url>"))
        XCTAssertFalse(label.contains("owned-password"))
        XCTAssertFalse(label.contains("owned-token"))
        XCTAssertFalse(label.contains("\n"))

        XCTAssertEqual(
            ReaderExtensionDiagnostics.errorCode(
                ReaderExtensionError.persistenceFailed("https://example.com/private?token=owned")
            ),
            "persistence-failed"
        )
        XCTAssertEqual(
            ReaderExtensionDiagnostics.errorCode(
                ReaderExtensionError.resultInvalid("provider response owned-body")
            ),
            "invalid-result"
        )
        XCTAssertEqual(
            ReaderExtensionDiagnostics.errorCode(
                ReaderExtensionError.persistenceFailed("Reader Extension metadata failed validation")
            ),
            "metadata-validation-failed"
        )
    }

    func testReaderDownloadIndexSchemaRejectsOneMalformedSiblingWithoutTreatingItAsEmpty() throws {
        let sourceID = ReaderExtensionSourceID(rawValue: String(repeating: "b", count: 64))
        let route = MangaContentRoute.readerExtension(
            source: sourceID,
            itemKey: "/owned/title?number=1",
            legacyStableKey: nil
        )
        let chapter = "Chapter 1"
        let item = ReaderDownloadItem(
            id: ReaderDownloadManager.downloadId(route: route, chapterNumber: chapter),
            route: route,
            routeKey: route.stableKey,
            mangaId: route.stableNegativeId,
            mangaTitle: "Owned Fixture",
            coverURL: nil,
            sourceName: "Owned Source",
            format: "Manga",
            chapterNumber: chapter,
            chapterTitle: "One",
            chapterKey: ChapterIdentityNormalizer.key(for: chapter),
            contentRating: ReaderContentRating.safe.rawValue,
            provider: ReaderDownloadProvider(
                kind: .readerExtension,
                sourceId: sourceID.rawValue,
                mangaKey: "/owned/title?number=1",
                moduleUUID: nil,
                contentParams: nil,
                isNovel: false,
                chapterParams: "/owned/chapter?number=1",
                authenticationProfileID: UUID()
            ),
            status: .queued,
            progress: 0,
            completedPages: 0,
            totalPages: 0,
            downloadedBytes: 0,
            error: nil,
            dateAdded: Date(timeIntervalSince1970: 1),
            dateCompleted: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validData = try encoder.encode([item])
        XCTAssertTrue(ReaderDownloadManager.persistedIndexSchemaIsValid(validData))

        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [Any])
        rows.append(["status": "definitely-not-a-download"])
        XCTAssertFalse(ReaderDownloadManager.persistedIndexSchemaIsValid(
            try JSONSerialization.data(withJSONObject: rows)
        ))
    }

    func testReaderDownloadJSONPreflightRejectsDenseIndexBeforeFoundationDecode() throws {
        let denseRows = "[" + Array(repeating: "0", count: 10_001).joined(separator: ",") + "]"
        let data = Data(denseRows.utf8)
        XCTAssertLessThan(data.count, 32 * 1_024 * 1_024)
        XCTAssertThrowsError(try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: 32 * 1_024 * 1_024,
            maximumDepth: 32,
            maximumContainerEntries: 10_000,
            maximumTopLevelEntries: 10_000,
            maximumTotalTokens: 1_000_000,
            maximumStringBytes: 64 * 1_024
        ))) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }
        XCTAssertFalse(ReaderDownloadManager.persistedIndexSchemaIsValid(data))
    }

    func testReaderDownloadMutationAndChapterBudgetsMatchDurableSchema() {
        XCTAssertTrue(ReaderDownloadManager.downloadIndexCanAcceptNewItem(currentItemCount: 9_999))
        XCTAssertFalse(ReaderDownloadManager.downloadIndexCanAcceptNewItem(currentItemCount: 10_000))
        XCTAssertFalse(ReaderDownloadManager.downloadIndexCanAcceptNewItem(currentItemCount: -1))

        let twoGiB = Int64(2) * 1_024 * 1_024 * 1_024
        XCTAssertTrue(ReaderDownloadManager.downloadPageBudgetAllows(
            pageCount: 5_000,
            accumulatedBytes: twoGiB - 1,
            nextPageBytes: 1
        ))
        XCTAssertFalse(ReaderDownloadManager.downloadPageBudgetAllows(
            pageCount: 5_001,
            accumulatedBytes: 0,
            nextPageBytes: 1
        ))
        XCTAssertFalse(ReaderDownloadManager.downloadPageBudgetAllows(
            pageCount: 1,
            accumulatedBytes: twoGiB,
            nextPageBytes: 1
        ))
        XCTAssertFalse(ReaderDownloadManager.downloadPageBudgetAllows(
            pageCount: 1,
            accumulatedBytes: Int64.max,
            nextPageBytes: 1
        ))
    }

    func testBoundedLocalStoreReaderAcceptsExactCapAndRejectsCapPlusOneAndSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let limit = 4_096
        let exactURL = root.appendingPathComponent("exact.json")
        let oversizedURL = root.appendingPathComponent("oversized.json")
        let symlinkURL = root.appendingPathComponent("linked.json")
        let fifoURL = root.appendingPathComponent("pipe.json")
        let exact = Data(repeating: 0x61, count: limit)
        try exact.write(to: exactURL)
        try Data(repeating: 0x62, count: limit + 1).write(to: oversizedURL)
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: exactURL
        )
        XCTAssertEqual(mkfifo(fifoURL.path, S_IRUSR | S_IWUSR), 0)

        XCTAssertEqual(
            try BoundedLocalStoreReader.read(from: exactURL, maximumBytes: limit),
            exact
        )
        XCTAssertThrowsError(
            try BoundedLocalStoreReader.read(from: oversizedURL, maximumBytes: limit)
        ) { error in
            XCTAssertEqual(
                error as? BoundedLocalStoreReader.ReadError,
                .tooLarge(maximumBytes: limit)
            )
        }
        XCTAssertThrowsError(
            try BoundedLocalStoreReader.read(from: symlinkURL, maximumBytes: limit)
        ) { error in
            XCTAssertEqual(
                error as? BoundedLocalStoreReader.ReadError,
                .nonRegularFile
            )
        }
        XCTAssertThrowsError(
            try BoundedLocalStoreReader.read(from: fifoURL, maximumBytes: limit)
        ) { error in
            XCTAssertEqual(
                error as? BoundedLocalStoreReader.ReadError,
                .nonRegularFile
            )
        }
    }

    func testModuleMetadataLoadFailureBlocksOverwriteOfPreservedSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let replacement = Data("[]".utf8)
        let limit = 32

        let oversizedURL = root.appendingPathComponent("oversized-modules.json")
        let oversized = Data(repeating: 0x61, count: limit + 1)
        try oversized.write(to: oversizedURL)
        XCTAssertThrowsError(
            try BoundedLocalStoreReader.read(from: oversizedURL, maximumBytes: limit)
        )
        XCTAssertFalse(ModuleManager.persistMetadataData(
            replacement,
            to: oversizedURL,
            maximumBytes: limit,
            storeLoadFailed: true
        ))
        XCTAssertEqual(try Data(contentsOf: oversizedURL), oversized)

        let targetURL = root.appendingPathComponent("target-modules.json")
        let target = Data("preserved-target".utf8)
        try target.write(to: targetURL)
        let symlinkURL = root.appendingPathComponent("linked-modules.json")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: targetURL
        )
        XCTAssertThrowsError(
            try BoundedLocalStoreReader.read(from: symlinkURL, maximumBytes: limit)
        )
        XCTAssertFalse(ModuleManager.persistMetadataData(
            replacement,
            to: symlinkURL,
            maximumBytes: limit,
            storeLoadFailed: true
        ))
        XCTAssertEqual(try Data(contentsOf: targetURL), target)

        let invalidURL = root.appendingPathComponent("invalid-modules.json")
        let invalid = Data("not-json".utf8)
        try invalid.write(to: invalidURL)
        XCTAssertFalse(ModuleManager.persistMetadataData(
            replacement,
            to: invalidURL,
            maximumBytes: limit,
            storeLoadFailed: true
        ))
        XCTAssertEqual(try Data(contentsOf: invalidURL), invalid)
    }

    func testUserRatingWriteAuthorityRejectsSameProfileRestoreAndABACompletion() throws {
        let profileA = UUID()
        let profileB = UUID()
        let destinationA = URL(fileURLWithPath: "/tmp/UserRatings-A.json")
        let captured = UserRatingManager.StoreWriteAuthority(
            profileID: profileA,
            generation: 41,
            destination: destinationA,
            sequence: 7
        )

        XCTAssertFalse(UserRatingManager.storeWriteAuthorityIsCurrent(
            captured,
            currentProfileID: profileA,
            currentGeneration: UserRatingManager.generationAfterAuthoritativeChange(41),
            currentDestination: destinationA,
            currentSequence: 8
        ), "A same-profile authoritative restore must revoke the older write")
        XCTAssertFalse(UserRatingManager.storeWriteAuthorityIsCurrent(
            captured,
            currentProfileID: profileB,
            currentGeneration: 42,
            currentDestination: URL(fileURLWithPath: "/tmp/UserRatings-B.json"),
            currentSequence: 8
        ))
        XCTAssertFalse(UserRatingManager.storeWriteAuthorityIsCurrent(
            captured,
            currentProfileID: profileA,
            currentGeneration: 43,
            currentDestination: destinationA,
            currentSequence: 9
        ), "Returning A after A→B→A must not revive work captured from the first A activation")
        XCTAssertEqual(UserRatingManager.generationAfterAuthoritativeChange(.max), 0)

        let active = ProfileManager.shared.activeProfileID
        XCTAssertTrue(UserRatingManager.notificationBelongsToActiveProfile(Notification(
            name: .userRatingDataDidChange,
            userInfo: [UserRatingManager.notificationProfileIDKey: active]
        )))
        XCTAssertFalse(UserRatingManager.notificationBelongsToActiveProfile(Notification(
            name: .userRatingDataDidChange,
            userInfo: [UserRatingManager.notificationProfileIDKey: UUID()]
        )), "A completed A write must not schedule B's sync after an A→B switch")
    }

    func testAccountIsolationPreservationFailureLeavesOldBytesAndAuthorityPending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldProgress = Data("old-progress-bytes".utf8)
        let progressURL = directory.appendingPathComponent("ProgressData.json")
        try oldProgress.write(to: progressURL)
        XCTAssertThrowsError(try ProgressManager.persistAuthoritativeRestoreData(
            Data("new-progress-bytes".utf8),
            to: progressURL
        ) {
            throw CocoaError(.fileWriteNoPermission)
        })
        XCTAssertEqual(try Data(contentsOf: progressURL), oldProgress)

        let rawProgress = Data(repeating: 0x7a, count: 64 * 1_024)
        let unreadableProgressURL = directory.appendingPathComponent("ProgressData-unreadable.json")
        let quarantinedProgressURL = directory.appendingPathComponent("ProgressData-quarantined.json")
        try rawProgress.write(to: unreadableProgressURL)
        XCTAssertThrowsError(try BoundedLocalStoreReader.read(
            from: unreadableProgressURL,
            maximumBytes: 32
        ))
        XCTAssertThrowsError(try ProgressManager.persistAuthoritativeRestoreData(
            Data("replacement".utf8),
            to: unreadableProgressURL,
            write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        ) {
            try FileManager.default.moveItem(
                at: unreadableProgressURL,
                to: quarantinedProgressURL
            )
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreadableProgressURL.path))
        XCTAssertEqual(
            try BoundedLocalStoreReader.read(
                from: quarantinedProgressURL,
                maximumBytes: rawProgress.count
            ),
            rawProgress,
            "A failed replacement must leave the exact unreadable source quarantined without copying it back into authority"
        )

        let oldRatings = Data("old-rating-bytes".utf8)
        let ratingsURL = directory.appendingPathComponent("UserRatings.json")
        try oldRatings.write(to: ratingsURL)
        XCTAssertThrowsError(try UserRatingManager.persistAuthoritativeStoreData(
            Data("new-rating-bytes".utf8),
            to: ratingsURL,
            storeRequiresQuarantine: true,
            quarantine: { _ in false }
        ))
        XCTAssertEqual(try Data(contentsOf: ratingsURL), oldRatings)

        XCTAssertFalse(MediaStateAccountNeutralIsolationPersistencePolicy.isDurablyComplete(
            progressCleared: false,
            ratingsCleared: true,
            sourcesCleared: true,
            trackerCleanupProtected: true
        ))
        XCTAssertFalse(MediaStateAccountNeutralIsolationPersistencePolicy.isDurablyComplete(
            progressCleared: true,
            ratingsCleared: false,
            sourcesCleared: true,
            trackerCleanupProtected: true
        ))
        XCTAssertTrue(MediaStateAccountNeutralIsolationPersistencePolicy.isDurablyComplete(
            progressCleared: true,
            ratingsCleared: true,
            sourcesCleared: true,
            trackerCleanupProtected: true
        ))
    }

    func testLocalJSONStoreCapsStayFiniteAndNonzero() {
        XCTAssertGreaterThan(ProgressPersistencePolicy.maximumPersistedStoreBytes, 0)
        XCTAssertGreaterThan(UserRatingManager.maximumPersistedStoreBytes, 0)
        XCTAssertGreaterThan(TrackerManager.maximumPersistedTrackerStateBytes, 0)
        XCTAssertGreaterThan(RecommendationEngine.maximumPersistedCacheBytes, 0)
        XCTAssertGreaterThan(UpNextResolutionCache.maximumPersistedStoreBytes, 0)
        XCTAssertTrue(BackupData.sanitizedUserRatings([String(Int.max): 8]).isEmpty)
        XCTAssertTrue(BackupData.sanitizedUserRatingNotes([String(Int.min): "hostile"]).isEmpty)
    }

    func testLegacyCleanupSchemaChecksRejectSyntacticallyValidWrongStoreShapes() throws {
        let wrongShape = try JSONSerialization.data(withJSONObject: ["validJSON": true])
        XCTAssertFalse(MangaLibraryManager.persistedCollectionsSchemaIsValid(wrongShape))
        XCTAssertFalse(MangaReadingProgressManager.persistedProgressSchemaIsValid(wrongShape))
        XCTAssertFalse(UserRatingManager.persistedStoreSchemaIsValid(wrongShape))
        XCTAssertFalse(ReaderDownloadManager.persistedIndexSchemaIsValid(wrongShape))
        XCTAssertFalse(ReaderDownloadManager.persistedChapterManifestSchemaIsValid(wrongShape))

        XCTAssertTrue(MangaLibraryManager.persistedCollectionsSchemaIsValid(
            try JSONEncoder().encode([MangaLibraryCollection]())
        ))
        XCTAssertTrue(MangaReadingProgressManager.persistedProgressSchemaIsValid(
            try JSONEncoder().encode([Int: MangaProgress]())
        ))
        XCTAssertTrue(UserRatingManager.persistedStoreSchemaIsValid(
            try JSONSerialization.data(withJSONObject: ["ratings": [:], "notes": [:]])
        ))
    }

    func testExecutableReconciliationRestoresCompleteLKGAndPreservesUserChoices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contentStore = try ReaderExtensionContentStore(rootURL: root)
        let oldScript = Data("class DefaultExtension extends MProvider { getPopular() {} }".utf8)
        let newScript = Data("class DefaultExtension extends MProvider { getPopular() {}; search() {} }".utf8)
        let oldDigest = try contentStore.activate(contentStore.stageExactScript(oldScript))
        let newDigest = try contentStore.activate(contentStore.stageExactScript(newScript))

        var old = installedSource(implementation: .javascript)
        old.version = "1.0.0"
        old.activeContentDigest = oldDigest
        old.declaredDomains = ["93.184.216.34"]
        old.runtimeCapabilities = [.popular]
        old.preferenceSchemaFingerprint = "old-schema"
        old.secretPreferenceKeys = ["login_field"]
        old.preferences = [
            "theme": .string("light"),
            "login_field": .secretReference("login_field")
        ]

        var updated = old
        updated.version = "2.0.0"
        updated.activeContentDigest = newDigest
        updated.runtimeCapabilities = [.popular, .search]
        updated.preferenceSchemaFingerprint = "new-schema"
        updated.secretPreferenceKeys = ["login_field", "privateModeKey"]
        updated.rollbackSourceSnapshot = ReaderExtensionInstalledSourceRollbackSnapshot(source: old)
        updated.rollbackContentDigest = oldDigest
        XCTAssertTrue(updated.rollbackSourceSnapshot?.preferences.isEmpty == true)
        updated.enabled = false
        updated.sortIndex = 7
        updated.preferences = [
            "theme": .string("sepia"),
            "login_field": .secretReference("login_field"),
            "privateModeKey": .secretReference("privateModeKey"),
            "page_margin": .number(12)
        ]

        let corruptURL = contentStore.contentURL.appendingPathComponent("\(newDigest).js")
        try Data("corrupt-update".utf8).write(to: corruptURL, options: .atomic)
        let repaired = ReaderExtensionPersistence.reconcileExecutableContent(
            [updated],
            contentStore: contentStore
        )
        let restored = try XCTUnwrap(repaired.sources.first)
        XCTAssertTrue(repaired.changed)
        XCTAssertEqual(restored.version, old.version)
        XCTAssertEqual(restored.activeContentDigest, oldDigest)
        XCTAssertEqual(restored.runtimeCapabilities, old.runtimeCapabilities)
        XCTAssertEqual(restored.preferenceSchemaFingerprint, old.preferenceSchemaFingerprint)
        XCTAssertEqual(restored.secretPreferenceKeys, old.secretPreferenceKeys)
        XCTAssertFalse(restored.enabled)
        XCTAssertEqual(restored.sortIndex, 7)
        XCTAssertEqual(restored.preferences["theme"], .string("sepia"))
        XCTAssertEqual(restored.preferences["login_field"], .secretReference("login_field"))
        XCTAssertEqual(restored.preferences["page_margin"], .number(12))
        XCTAssertNil(restored.preferences["privateModeKey"], "a failed schema's secret marker must not leak into the old schema")
        XCTAssertNil(restored.rollbackSourceSnapshot)

        try FileManager.default.removeItem(
            at: contentStore.contentURL.appendingPathComponent("\(oldDigest).js")
        )
        let unavailable = ReaderExtensionPersistence.reconcileExecutableContent(
            [updated],
            contentStore: contentStore
        )
        let requiresReinstall = try XCTUnwrap(unavailable.sources.first)
        XCTAssertNil(requiresReinstall.activeContentDigest)
        XCTAssertTrue(requiresReinstall.requiresReinstall)
        XCTAssertNil(requiresReinstall.rollbackSourceSnapshot)
    }

    func testExecutableReconciliationLeavesValidNoOpStateUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contentStore = try ReaderExtensionContentStore(rootURL: root)
        let script = Data("class DefaultExtension extends MProvider { getPopular() {} }".utf8)
        let digest = try contentStore.activate(contentStore.stageExactScript(script))
        var source = installedSource(implementation: .javascript)
        source.activeContentDigest = digest
        let result = ReaderExtensionPersistence.reconcileExecutableContent([source], contentStore: contentStore)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.sources, [source])
    }

    func testNilContentStoreNeverRewritesExecutableMetadata() {
        var source = installedSource(implementation: .javascript)
        source.activeContentDigest = String(repeating: "a", count: 64)
        source.rollbackContentDigest = String(repeating: "b", count: 64)
        var rollback = source
        rollback.activeContentDigest = source.rollbackContentDigest
        source.rollbackSourceSnapshot = ReaderExtensionInstalledSourceRollbackSnapshot(source: rollback)

        let result = ReaderExtensionPersistence.reconcileExecutableContent([source], contentStore: nil)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.sources, [source])
        XCTAssertFalse(result.sources[0].requiresReinstall)
    }

    func testSharedServicesPreferenceOverlayMigratesThenIsolatesProfilesAndBackupRestore() throws {
        let metadataName = "ReaderExtensionCoreTests.metadata.\(UUID().uuidString)"
        let profileAName = "ReaderExtensionCoreTests.profileA.\(UUID().uuidString)"
        let profileBName = "ReaderExtensionCoreTests.profileB.\(UUID().uuidString)"
        let restoredName = "ReaderExtensionCoreTests.restored.\(UUID().uuidString)"
        let metadata = try XCTUnwrap(UserDefaults(suiteName: metadataName))
        let profileA = try XCTUnwrap(UserDefaults(suiteName: profileAName))
        let profileB = try XCTUnwrap(UserDefaults(suiteName: profileBName))
        let restoredProfile = try XCTUnwrap(UserDefaults(suiteName: restoredName))
        defer {
            metadata.removePersistentDomain(forName: metadataName)
            profileA.removePersistentDomain(forName: profileAName)
            profileB.removePersistentDomain(forName: profileBName)
            restoredProfile.removePersistentDomain(forName: restoredName)
        }

        try preservingGlobalReaderExtensionSettings {
            var legacy = installedSource(implementation: .javascript)
            legacy.preferences = ["reader_theme": .string("legacy")]
            try ReaderExtensionPersistence.persist(
                repositories: [],
                installedSources: [legacy],
                showMature: false,
                autoUpdate: true,
                lastAutoUpdate: nil,
                to: metadata
            )
            let embedded = try ReaderExtensionPersistence.loadInstalledSources(from: metadata)
            XCTAssertTrue(try ReaderExtensionPersistence.seedPreferenceOverlayIfNeeded(from: embedded, to: profileA))
            XCTAssertTrue(try ReaderExtensionPersistence.seedPreferenceOverlayIfNeeded(from: embedded, to: profileB))

            var profileASource = legacy
            profileASource.preferences = ["reader_theme": .string("sepia")]
            try ReaderExtensionPersistence.persist(
                repositories: [],
                installedSources: [profileASource],
                showMature: false,
                autoUpdate: true,
                lastAutoUpdate: nil,
                to: metadata,
                preferenceStore: profileA
            )

            XCTAssertTrue(
                try ReaderExtensionPersistence.loadInstalledSources(from: metadata).first?.preferences.isEmpty == true,
                "shared installed-software metadata must not contain profile values"
            )
            let snapshotA = try ReaderExtensionPersistence.backupSnapshot(
                from: metadata,
                preferenceStore: profileA
            )
            let snapshotB = try ReaderExtensionPersistence.backupSnapshot(
                from: metadata,
                preferenceStore: profileB
            )
            XCTAssertEqual(snapshotA.installedSources.first?.preferences["reader_theme"], .string("sepia"))
            XCTAssertEqual(snapshotB.installedSources.first?.preferences["reader_theme"], .string("legacy"))

            try ReaderExtensionPersistence.restoreMetadata(
                snapshotA,
                to: metadata,
                preferenceStore: restoredProfile
            )
            let restored = try ReaderExtensionPersistence.backupSnapshot(
                from: metadata,
                preferenceStore: restoredProfile
            )
            XCTAssertEqual(restored.installedSources.first?.preferences["reader_theme"], .string("sepia"))
            XCTAssertEqual(
                try ReaderExtensionPersistence.backupSnapshot(from: metadata, preferenceStore: profileB)
                    .installedSources.first?.preferences["reader_theme"],
                .string("legacy"),
                "restoring one profile must not replace another profile's overlay"
            )
        }
    }

    func testReaderPreferenceOverlayPreflightRejectsDenseStringListBeforeDecode() throws {
        let suiteName = "ReaderExtensionCoreTests.denseOverlay.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { store.removePersistentDomain(forName: suiteName) }

        let denseList = Array(
            repeating: "\"owned\"",
            count: ReaderExtensionPersistence.maximumInstalledSourceCount + 1
        ).joined(separator: ",")
        let data = Data("""
        {"values":{"reader:owned":{"display_mode":{"type":"stringList","list":[\(denseList)]}}}}
        """.utf8)
        XCTAssertLessThan(data.count, 4 * 1_024 * 1_024)
        store.set(data, forKey: ReaderExtensionPersistence.preferenceOverlayKey)

        XCTAssertThrowsError(try ReaderExtensionPersistence.applyingPreferenceOverlay(
            to: [installedSource(implementation: .madara)],
            from: store
        )) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }
    }

    func testUnsharedServicesPreferenceOverlayUsesEachProfileMetadataStore() throws {
        let aName = "ReaderExtensionCoreTests.unsharedA.\(UUID().uuidString)"
        let bName = "ReaderExtensionCoreTests.unsharedB.\(UUID().uuidString)"
        let storeA = try XCTUnwrap(UserDefaults(suiteName: aName))
        let storeB = try XCTUnwrap(UserDefaults(suiteName: bName))
        defer {
            storeA.removePersistentDomain(forName: aName)
            storeB.removePersistentDomain(forName: bName)
        }

        try preservingGlobalReaderExtensionSettings {
            var sourceA = installedSource(implementation: .javascript)
            sourceA.preferences = ["reader_theme": .string("profile-a")]
            var sourceB = sourceA
            sourceB.preferences = ["reader_theme": .string("profile-b")]
            try ReaderExtensionPersistence.persist(
                repositories: [], installedSources: [sourceA], showMature: false,
                autoUpdate: true, lastAutoUpdate: nil, to: storeA, preferenceStore: storeA
            )
            try ReaderExtensionPersistence.persist(
                repositories: [], installedSources: [sourceB], showMature: false,
                autoUpdate: true, lastAutoUpdate: nil, to: storeB, preferenceStore: storeB
            )
            XCTAssertEqual(
                try ReaderExtensionPersistence.backupSnapshot(from: storeA, preferenceStore: storeA)
                    .installedSources.first?.preferences["reader_theme"],
                .string("profile-a")
            )
            XCTAssertEqual(
                try ReaderExtensionPersistence.backupSnapshot(from: storeB, preferenceStore: storeB)
                    .installedSources.first?.preferences["reader_theme"],
                .string("profile-b")
            )
            XCTAssertTrue(try ReaderExtensionPersistence.loadInstalledSources(from: storeA).first?.preferences.isEmpty == true)
            XCTAssertTrue(try ReaderExtensionPersistence.loadInstalledSources(from: storeB).first?.preferences.isEmpty == true)
        }
    }

    func testUnreadableRosterOrMetadataRetainsAllContentAndFailsPreflight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let contentStore = try ReaderExtensionContentStore(rootURL: root)
        let script = Data("class DefaultExtension extends MProvider { getPopular() {} }".utf8)
        let digest = try contentStore.activate(contentStore.stageExactScript(script))

        let validName = "ReaderExtensionCoreTests.retention.valid.\(UUID().uuidString)"
        let corruptName = "ReaderExtensionCoreTests.retention.corrupt.\(UUID().uuidString)"
        let validStore = try XCTUnwrap(UserDefaults(suiteName: validName))
        let corruptStore = try XCTUnwrap(UserDefaults(suiteName: corruptName))
        defer {
            validStore.removePersistentDomain(forName: validName)
            corruptStore.removePersistentDomain(forName: corruptName)
        }
        try preservingGlobalReaderExtensionSettings {
            var source = installedSource(implementation: .javascript)
            source.activeContentDigest = digest
            try ReaderExtensionPersistence.persist(
                repositories: [], installedSources: [source], showMature: false,
                autoUpdate: true, lastAutoUpdate: nil, to: validStore
            )
            corruptStore.set(Data("{".utf8), forKey: ReaderExtensionPersistence.installedSourcesKey)

            XCTAssertNil(ReaderExtensionContentRetentionPolicy.referencedDigests(
                rosterStoreIsReadable: false,
                stores: [validStore]
            ))
            XCTAssertNil(ReaderExtensionContentRetentionPolicy.referencedDigests(
                rosterStoreIsReadable: true,
                stores: [validStore, corruptStore]
            ))
            XCTAssertFalse(ReaderExtensionPersistence.metadataIsReadable(
                in: corruptStore,
                preferenceStore: corruptStore
            ))
            if let keeping = ReaderExtensionContentRetentionPolicy.referencedDigests(
                rosterStoreIsReadable: false,
                stores: [validStore]
            ) {
                contentStore.removeUnreferencedContent(keeping: keeping)
            }
            XCTAssertEqual(try contentStore.scriptData(digest: digest), script)
        }
    }

    func testSharedUninstallPolicyCleansEveryReadableProfileNamespace() throws {
        let profileA = UUID()
        let profileB = UUID()
        XCTAssertNil(ReaderExtensionProfileDeviceStatePolicy.removalNamespaces(
            sharesServices: true,
            rosterStoreIsReadable: false,
            profileIDs: [profileA, profileB],
            activeProfileID: profileA
        ))
        let namespaces = try XCTUnwrap(ReaderExtensionProfileDeviceStatePolicy.removalNamespaces(
            sharesServices: true,
            rosterStoreIsReadable: true,
            profileIDs: [profileA, profileB],
            activeProfileID: profileA
        ))
        XCTAssertEqual(Set(namespaces), Set([profileA.uuidString, profileB.uuidString]))

        let source = installedSource(implementation: .javascript)
        let keychainAccess = ReaderExtensionInjectedKeychainAccess(accounts: [:])
        for namespace in namespaces {
            let keychain = ReaderExtensionKeychainStore(
                sourceID: source.id,
                values: source.preferences,
                namespace: namespace,
                schemaSecretKeys: source.secretPreferenceKeys,
                keychain: keychainAccess
            )
            try keychain.setSecret("owned-secret", for: "api_token")
            try keychain.setApprovedDomains(["93.184.216.34"])
        }
        defer {
            namespaces.forEach {
                try? ReaderExtensionKeychainStore(
                    sourceID: source.id,
                    namespace: $0,
                    keychain: keychainAccess
                ).removeAllDeviceState()
            }
        }
        for namespace in namespaces {
            try ReaderExtensionKeychainStore(
                sourceID: source.id,
                namespace: namespace,
                keychain: keychainAccess
            ).removeAllDeviceState()
        }
        for namespace in namespaces {
            let keychain = ReaderExtensionKeychainStore(
                sourceID: source.id,
                namespace: namespace,
                keychain: keychainAccess
            )
            XCTAssertNil(try keychain.secret(for: "api_token"))
            XCTAssertTrue(keychain.approvedDomains().isEmpty)
        }
        let pending = try ReaderExtensionAuthenticationCleanupPolicy.adding(
            sourceIDs: [source.id],
            namespaces: namespaces,
            kind: .deviceState,
            to: []
        )
        var sharedRetries = Set<String>()
        let sharedOutcome = ReaderExtensionAuthenticationCleanupPolicy.retry(
            pending,
            sourceIDs: [source.id],
            namespaces: Set(namespaces)
        ) { sharedRetries.insert($0.namespace) }
        XCTAssertEqual(sharedRetries, Set(namespaces))
        XCTAssertTrue(sharedOutcome.remaining.isEmpty)

        var scopedRetries = Set<String>()
        let scopedOutcome = ReaderExtensionAuthenticationCleanupPolicy.retry(
            pending,
            sourceIDs: [source.id],
            namespaces: [profileB.uuidString]
        ) { scopedRetries.insert($0.namespace) }
        XCTAssertEqual(scopedRetries, [profileB.uuidString])
        XCTAssertEqual(Set(scopedOutcome.remaining.map(\.namespace)), [profileA.uuidString])
        XCTAssertEqual(
            ReaderExtensionProfileDeviceStatePolicy.removalNamespaces(
                sharesServices: false,
                rosterStoreIsReadable: true,
                profileIDs: [profileA, profileB],
                activeProfileID: profileB
            ),
            [profileB.uuidString]
        )
    }

    func testNovelSanitizerRemovesActiveAndUnapprovedContent() throws {
        let dirty = """
        <p onclick='steal()'>Owned text</p><script>steal()</script><form><input></form>
        <img src='http://127.0.0.1/private.jpg'><a href='https://93.184.216.34/chapter'>Next</a>
        """
        let clean = try ReaderExtensionNovelSanitizer.sanitize(
            dirty,
            baseURL: publicBaseURL,
            approvedDomains: [publicBaseURL.host!]
        )
        XCTAssertTrue(clean.contains("Owned text"))
        XCTAssertFalse(clean.lowercased().contains("script"))
        XCTAssertFalse(clean.lowercased().contains("form"))
        XCTAssertFalse(clean.lowercased().contains("onclick"))
        XCTAssertFalse(clean.contains("127.0.0.1"))
        XCTAssertFalse(clean.lowercased().contains("<img"))
        XCTAssertFalse(clean.contains("93.184.216.34/chapter"))
        let document = try SwiftSoup.parse(clean)
        XCTAssertEqual(try document.select("a").text(), "Next")
        XCTAssertTrue(try document.select("[href], [action], [formaction], [cite], [src], [srcset], [poster], [data], [ping], [target]").isEmpty())
    }

    func testNovelSanitizerStripsEveryNavigationAttributeFromThousandsOfLinks() throws {
        let linkCount = ReaderExtensionNovelSanitizer.maximumDOMElements + 1
        let links = (0..<linkCount).map { index in
            "<a href='https://unique-\(index).invalid/chapter' ping='https://tracker-\(index).invalid/p' target='_blank'>Link \(index)</a>"
        }.joined()
        let dirty = links + "<blockquote cite='https://quote.invalid/source'>Quote</blockquote>"
            + "<form action='https://form.invalid/post'><button formaction='https://button.invalid/post'>Submit</button></form>"
        XCTAssertLessThan(dirty.utf8.count, ReaderExtensionNovelSanitizer.maximumInputBytes)

        XCTAssertThrowsError(try ReaderExtensionNovelSanitizer.sanitize(
            dirty,
            baseURL: publicBaseURL,
            approvedDomains: [publicBaseURL.host!]
        )) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }
    }

    func testHTMLPreflightRejectsTagFloodBeforeEveryReaderDOMParser() async throws {
        let tokenLimit = ReaderExtensionNovelSanitizer.maximumDOMElements - 4
        let nearLimit = String(repeating: "<i>x</i>", count: tokenLimit)
        XCTAssertNoThrow(try ReaderExtensionHTMLPreflight.validate(
            nearLimit,
            maximumBytes: ReaderExtensionNovelSanitizer.maximumInputBytes,
            maximumNodeTokens: tokenLimit
        ))

        let smallFakeTags = String(repeating: "<i>", count: 128)
        let smallRawText = "<!--\(smallFakeTags)--><script>\(smallFakeTags)</script><style>\(smallFakeTags)</style><p>Owned</p>"
        XCTAssertNoThrow(try ReaderExtensionHTMLPreflight.validate(
            smallRawText,
            maximumBytes: ReaderExtensionNovelSanitizer.maximumInputBytes,
            maximumNodeTokens: tokenLimit
        ), "ordinary bounded comment and script/style text should remain compatible")

        let largeFakeTags = String(repeating: "<i>", count: tokenLimit + 100)
        let largeRawText = "<!--\(largeFakeTags)--><script>\(largeFakeTags)</script><style>\(largeFakeTags)</style>"
        XCTAssertThrowsError(try ReaderExtensionHTMLPreflight.validate(
            largeRawText,
            maximumBytes: ReaderExtensionNovelSanitizer.maximumInputBytes,
            maximumNodeTokens: tokenLimit
        )) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }

        let mismatchTail = String(repeating: "<i>x</i>", count: tokenLimit + 40)
        let parserMismatchFloods = [
            "<!--x--!>" + mismatchTail,
            "<!-->" + mismatchTail,
            "<!--->" + mismatchTail,
            "<script>x</script/>" + mismatchTail,
            "<div x=a' >" + mismatchTail,
            "<!foo ' >" + mismatchTail,
            String(repeating: "</br>", count: 100_000)
        ]
        for payload in parserMismatchFloods {
            XCTAssertThrowsError(try ReaderExtensionHTMLPreflight.validate(
                payload,
                maximumBytes: ReaderExtensionNovelSanitizer.maximumInputBytes,
                maximumNodeTokens: tokenLimit
            )) { error in
                XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
            }
        }

        let ordinaryAttributes = "<div "
            + (0..<64).map { "data-a\($0)='owned > value'" }.joined(separator: " ")
            + ">Owned</div>"
        XCTAssertNoThrow(try ReaderExtensionHTMLPreflight.validate(
            ordinaryAttributes,
            maximumBytes: ReaderExtensionNovelSanitizer.maximumInputBytes,
            maximumNodeTokens: tokenLimit
        ))
        let attributeStorm = "<div "
            + (0..<100_000).map { "a\($0)=x" }.joined(separator: " ")
            + ">Owned</div>"
        let closingAttributeStorm = "</div "
            + (0..<100_000).map { "a\($0)=x" }.joined(separator: " ")
            + ">"
        let nonASCIIAttributeStorm = "<é "
            + (0..<100_000).map { "a\($0)=x" }.joined(separator: " ")
            + ">Owned</é>"
        XCTAssertLessThan(attributeStorm.utf8.count, ReaderExtensionNovelSanitizer.maximumInputBytes)
        XCTAssertLessThan(closingAttributeStorm.utf8.count, ReaderExtensionNovelSanitizer.maximumInputBytes)
        XCTAssertLessThan(nonASCIIAttributeStorm.utf8.count, ReaderExtensionNovelSanitizer.maximumInputBytes)
        for hostileAttributes in [attributeStorm, closingAttributeStorm, nonASCIIAttributeStorm] {
            XCTAssertThrowsError(try ReaderExtensionHTMLPreflight.validate(
                hostileAttributes,
                maximumBytes: ReaderExtensionNovelSanitizer.maximumInputBytes,
                maximumNodeTokens: tokenLimit
            )) { error in
                XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
            }
        }

        let flood = String(repeating: "<i>x</i>", count: 400_000)
        XCTAssertLessThan(flood.utf8.count, ReaderExtensionNovelSanitizer.maximumInputBytes)
        XCTAssertThrowsError(try ReaderExtensionHTMLPreflight.validate(
            flood,
            maximumBytes: ReaderExtensionNovelSanitizer.maximumInputBytes,
            maximumNodeTokens: tokenLimit
        )) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }
        let parserMismatchFlood = parserMismatchFloods[0] + "<script>x</script/>"
        XCTAssertThrowsError(try ReaderExtensionNovelSanitizer.sanitize(
            parserMismatchFlood,
            baseURL: publicBaseURL,
            approvedDomains: [publicBaseURL.host!]
        )) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }

        // The extension DOM bridge and the native parsers admit documents up
        // to the catalog-scale element cap, so their flood fixture must be
        // sized past that cap rather than the novel sanitizer's.
        let bridgeFlood = "<script>x</script/>"
            + String(repeating: "<i>x</i>", count: ReaderExtensionSecurityPolicy.maximumDOMElementsPerDocument + 100)
        let bridge = ReaderExtensionDOMBridge(baseURL: publicBaseURL)
        XCTAssertEqual(bridge.parse(bridgeFlood), 0)
        XCTAssertEqual(bridge.parse(attributeStorm), 0)

        XCTAssertThrowsError(try ReaderExtensionWebNovelSanitizer.plainText(from: parserMismatchFlood)) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }

        let nativeProvider = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .madara),
            network: ReaderExtensionFixtureNetwork(body: Data(bridgeFlood.utf8)),
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "native-dom-preflight"
        )
        do {
            _ = try await nativeProvider.popular(page: 1)
            XCTFail("native provider parsed a hostile tag flood")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .contentTooLarge)
        }
    }

    func testReaderJSONPreflightRejectsStructuralAmplificationBeforeFoundationDecode() async throws {
        let exactRows = Data(("[" + Array(repeating: "null", count: 10_000).joined(separator: ",") + "]").utf8)
        XCTAssertNoThrow(try ReaderExtensionJSONPreflight.validate(exactRows, limits: .init(
            maximumBytes: 4 * 1_024 * 1_024,
            maximumDepth: 8,
            maximumContainerEntries: 20_000,
            maximumTopLevelEntries: 10_000,
            maximumTotalTokens: 20_000
        )))
        let oneTooMany = Data(("[" + Array(repeating: "null", count: 10_001).joined(separator: ",") + "]").utf8)
        XCTAssertThrowsError(try ReaderExtensionJSONPreflight.validate(oneTooMany, limits: .init(
            maximumBytes: 4 * 1_024 * 1_024,
            maximumDepth: 8,
            maximumContainerEntries: 20_000,
            maximumTopLevelEntries: 10_000,
            maximumTotalTokens: 30_000
        ))) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }

        let escapedStructure = Data(#"{"value":"[null,{\"chapters\":[1,2,3]}]"}"#.utf8)
        XCTAssertNoThrow(try ReaderExtensionJSONPreflight.validate(escapedStructure, limits: .init(
            maximumBytes: 1_024,
            maximumDepth: 4,
            maximumContainerEntries: 4,
            maximumTopLevelEntries: 2,
            maximumTotalTokens: 4
        )))
        let tooDeep = Data((String(repeating: "[", count: 9) + "0" + String(repeating: "]", count: 9)).utf8)
        XCTAssertThrowsError(try ReaderExtensionJSONPreflight.validate(tooDeep, limits: .init(
            maximumBytes: 1_024,
            maximumDepth: 8,
            maximumContainerEntries: 2,
            maximumTotalTokens: 32
        ))) { error in
            XCTAssertEqual(error as? ReaderExtensionError, .contentTooLarge)
        }

        let chaptersScript = Data("""
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) {
            return {name: "Owned", chapters: Array.from({length: 10001}, (_, index) => ({name: "C", url: "/c/" + index}))};
          }
          async getPageList(url) { return []; }
        }
        """.utf8)
        let javascriptProvider = try JavaScriptReaderProvider(
            source: installedSource(implementation: .javascript),
            scriptData: chaptersScript,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            consentScopeID: "json-preflight-js",
            preferenceStore: ReaderExtensionInMemoryPreferenceStore()
        )
        do {
            _ = try await javascriptProvider.chapters(itemKey: "/owned")
            XCTFail("a cap+1 JavaScript chapter array reached Foundation decoding")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .contentTooLarge)
        }

        let nepRows = (0...20_000).map { "{\"s\":\"Owned\",\"i\":\"item-\($0)\",\"vm\":1}" }.joined(separator: ",")
        let nepFixture = "vm.Directory = [\(nepRows)]; vm.GetIntValue"
        XCTAssertLessThan(nepFixture.utf8.count, ReaderExtensionSecurityPolicy.maximumDOMBytes)
        let nepProvider = try ReaderExtensionNativeProviderFactory.make(
            source: installedSource(implementation: .nepNep),
            network: ReaderExtensionFixtureNetwork(body: Data(nepFixture.utf8)),
            approvedDomains: [publicBaseURL.host!],
            consentScopeID: "json-preflight-native"
        )
        do {
            _ = try await nepProvider.popular(page: 1)
            XCTFail("a cap+1 NepNep directory reached Foundation decoding")
        } catch let error as ReaderExtensionError {
            XCTAssertEqual(error, .contentTooLarge)
        }
    }

    func testOfflineReaderExtensionNovelTextIsEscapedExactlyOnceWithoutChangingLegacyDownloads() throws {
        let plainText = "Literal <style>body{display:none}</style> &lt;style&gt; <img src=x> & tail"
        let readerRoute = MangaContentRoute.readerExtension(
            source: ReaderExtensionSourceID(rawValue: "reader:owned-offline-novel"),
            itemKey: "owned-item",
            legacyStableKey: nil
        )
        let escaped = ReaderExtensionOfflineNovelHTML.bodyContent(
            for: plainText,
            route: readerRoute
        )

        XCTAssertEqual(
            escaped,
            "Literal &lt;style&gt;body{display:none}&lt;/style&gt; &amp;lt;style&amp;gt; &lt;img src=x&gt; &amp; tail"
        )
        let document = try SwiftSoup.parse("<html><body>\(escaped)</body></html>")
        XCTAssertTrue(try document.select("style,img").isEmpty())
        XCTAssertEqual(try document.body()?.text(), plainText)

        let legacyRoute = MangaContentRoute.legacyModule(
            moduleUUID: "owned-legacy",
            contentParams: "owned-item",
            isNovel: true
        )
        XCTAssertEqual(
            ReaderExtensionOfflineNovelHTML.bodyContent(for: plainText, route: legacyRoute),
            plainText,
            "legacy download rendering is outside the Reader Extension migration scope"
        )
    }

    func testReaderExtensionRepositorySearchIndexBoundsAndNormalizesLargeCatalogFiltering() throws {
        let repositoryURL = try XCTUnwrap(URL(string: "https://repo.example/index.json"))
        let otherRepositoryURL = try XCTUnwrap(URL(string: "https://other.example/index.json"))
        let repositoryID = ReaderExtensionRepositoryRecord(indexURL: repositoryURL).id
        var sources = (0..<600).map { index in
            catalogSearchSource(
                index: index,
                name: index == 420 ? "Café Comix" : "Source \(index)",
                language: ["en", "fr", "ja"][index % 3],
                maturity: index == 419 ? .mature : .safe,
                repositoryURL: repositoryURL
            )
        }
        sources.append(catalogSearchSource(
            index: 999,
            name: "Wrong Repository",
            language: "en",
            maturity: .safe,
            repositoryURL: otherRepositoryURL
        ))

        let entries = ReaderExtensionCatalogSearchIndex.build(
            sources: sources,
            repositoryID: repositoryID,
            showMatureSources: false,
            localeIdentifier: "en_US",
            preferredLanguageIdentifiers: ["en-US", "fr-FR"]
        )

        XCTAssertEqual(entries.count, 599)
        XCTAssertEqual(entries.first?.source.language, "en")
        XCTAssertFalse(entries.contains { $0.source.name == "Wrong Repository" })
        XCTAssertFalse(entries.contains { $0.source.name == "Source 419" })

        let filtered = ReaderExtensionCatalogSearchIndex.filter(
            entries,
            query: "  CAFE   english ",
            localeIdentifier: "en_US"
        )
        XCTAssertEqual(filtered.map(\.source.name), ["Café Comix"])
        XCTAssertEqual(
            ReaderExtensionCatalogSearchIndex.filter(
                entries,
                query: "",
                localeIdentifier: "en_US"
            ),
            entries
        )
    }

    func testPrivateCloudConfigurationPortsSecretsAndClearsAuthoritativelyWithoutCookies() throws {
        let metadataSuite = "reader-private-cloud-metadata-\(UUID().uuidString)"
        let profileSuite = "reader-private-cloud-profile-\(UUID().uuidString)"
        let metadata = try XCTUnwrap(UserDefaults(suiteName: metadataSuite))
        let preferences = try XCTUnwrap(UserDefaults(suiteName: profileSuite))
        defer {
            metadata.removePersistentDomain(forName: metadataSuite)
            preferences.removePersistentDomain(forName: profileSuite)
        }
        let profileID = UUID()
        var source = installedSource(implementation: .javascript)
        source.preferenceSchemaFingerprint = String(repeating: "a", count: 64)
        source.secretPreferenceKeys = ["apiToken"]
        source.preferences = [
            "theme": .string("dark"),
            "apiToken": .secretReference("apiToken")
        ]
        try ReaderExtensionPersistence.persist(
            repositories: [],
            installedSources: [source],
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: metadata,
            preferenceStore: preferences
        )

        let prefix = "\(profileID.uuidString).\(source.id.rawValue)"
        let cookieData = Data("device-cookie".utf8)
        let declaredData = try JSONEncoder().encode(Set(["declared.example"]))
        let userDomainData = try JSONEncoder().encode(Set(["reader.example"]))
        let keychain = ReaderExtensionInjectedKeychainAccess(accounts: [
            "\(prefix).secret.apiToken": Data("owned-secret".utf8),
            "\(prefix).user-domains": userDomainData,
            "\(prefix).cookies": cookieData,
            "\(prefix).domains": declaredData
        ])

        let captured = try ReaderExtensionPersistence.capturePrivateCloudConfiguration(
            profileID: profileID,
            metadataStore: metadata,
            preferenceStore: preferences,
            keychain: keychain
        )
        XCTAssertTrue(captured.configurationIsComplete)
        XCTAssertEqual(captured.sources.first?.ordinaryPreferences["theme"], .string("dark"))
        XCTAssertEqual(captured.sources.first?.keychain.secrets["apiToken"], "owned-secret")
        XCTAssertEqual(captured.sources.first?.keychain.userApprovedDomains, ["reader.example"])
        let privateCloudText = String(
            decoding: try JSONEncoder().encode(captured),
            as: UTF8.self
        )
        XCTAssertTrue(privateCloudText.contains("owned-secret"))
        XCTAssertFalse(privateCloudText.contains("device-cookie"))
        XCTAssertFalse(privateCloudText.contains("declared.example"))

        let manual = try ReaderExtensionPersistence.backupSnapshot(
            from: metadata,
            preferenceStore: preferences
        )
        XCTAssertNil(manual.installedSources.first?.preferences["apiToken"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(manual), as: UTF8.self)
            .contains("owned-secret"))

        let staleAdmission = ReaderExtensionAuthenticatedRequestAdmission(
            sourceID: source.id,
            namespace: profileID.uuidString
        )
        try ReaderExtensionPersistence.applyPrivateCloudConfiguration(
            ReaderExtensionPrivateCloudConfiguration(profileID: profileID, sources: []),
            profileID: profileID,
            metadataStore: metadata,
            preferenceStore: preferences,
            keychain: keychain
        )
        let restored = try ReaderExtensionPersistence.applyingPreferenceOverlay(
            to: ReaderExtensionPersistence.loadInstalledSources(from: metadata),
            from: preferences
        )
        XCTAssertEqual(restored.first?.preferences, [:])
        XCTAssertNil(keychain.accounts["\(prefix).secret.apiToken"])
        XCTAssertNil(keychain.accounts["\(prefix).user-domains"])
        XCTAssertEqual(keychain.accounts["\(prefix).cookies"], cookieData)
        XCTAssertEqual(keychain.accounts["\(prefix).domains"], declaredData)
        XCTAssertThrowsError(try staleAdmission.validate())
    }

    func testPrivateCloudConfigurationRejectsOneMismatchedSourceBeforeMutation() throws {
        let metadataSuite = "reader-private-cloud-invalid-metadata-\(UUID().uuidString)"
        let profileSuite = "reader-private-cloud-invalid-profile-\(UUID().uuidString)"
        let metadata = try XCTUnwrap(UserDefaults(suiteName: metadataSuite))
        let preferences = try XCTUnwrap(UserDefaults(suiteName: profileSuite))
        defer {
            metadata.removePersistentDomain(forName: metadataSuite)
            preferences.removePersistentDomain(forName: profileSuite)
        }
        let profileID = UUID()
        var source = installedSource(implementation: .javascript)
        source.secretPreferenceKeys = ["apiToken"]
        source.preferences = ["apiToken": .secretReference("apiToken")]
        try ReaderExtensionPersistence.persist(
            repositories: [],
            installedSources: [source],
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: metadata,
            preferenceStore: preferences
        )
        let account = "\(profileID.uuidString).\(source.id.rawValue).secret.apiToken"
        let original = Data("local-secret".utf8)
        let keychain = ReaderExtensionInjectedKeychainAccess(accounts: [account: original])
        var incoming = try ReaderExtensionPersistence.capturePrivateCloudConfiguration(
            profileID: profileID,
            metadataStore: metadata,
            preferenceStore: preferences,
            keychain: keychain
        )
        incoming.sources[0].codeProvenanceFingerprint = String(repeating: "f", count: 64)
        incoming.sources[0].keychain.secrets["apiToken"] = "remote-secret"

        XCTAssertThrowsError(try ReaderExtensionPersistence.applyPrivateCloudConfiguration(
            incoming,
            profileID: profileID,
            metadataStore: metadata,
            preferenceStore: preferences,
            keychain: keychain
        ))
        XCTAssertEqual(keychain.accounts[account], original)
    }

    func testPrivateCloudConfigurationRollsBackAfterDurabilityCheckpointFailure() throws {
        let metadataSuite = "reader-private-cloud-durability-metadata-\(UUID().uuidString)"
        let profileSuite = "reader-private-cloud-durability-profile-\(UUID().uuidString)"
        let metadata = try XCTUnwrap(UserDefaults(suiteName: metadataSuite))
        let preferences = try XCTUnwrap(UserDefaults(suiteName: profileSuite))
        defer {
            metadata.removePersistentDomain(forName: metadataSuite)
            preferences.removePersistentDomain(forName: profileSuite)
        }
        let profileID = UUID()
        var source = installedSource(implementation: .javascript)
        source.preferenceSchemaFingerprint = String(repeating: "a", count: 64)
        source.secretPreferenceKeys = ["apiToken"]
        source.preferences = [
            "theme": .string("local"),
            "apiToken": .secretReference("apiToken")
        ]
        try ReaderExtensionPersistence.persist(
            repositories: [],
            installedSources: [source],
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: metadata,
            preferenceStore: preferences
        )
        let account = "\(profileID.uuidString).\(source.id.rawValue).secret.apiToken"
        let localSecret = Data("local-secret".utf8)
        let keychain = ReaderExtensionInjectedKeychainAccess(accounts: [account: localSecret])
        var incoming = try ReaderExtensionPersistence.capturePrivateCloudConfiguration(
            profileID: profileID,
            metadataStore: metadata,
            preferenceStore: preferences,
            keychain: keychain
        )
        incoming.sources[0].ordinaryPreferences["theme"] = .string("remote")
        incoming.sources[0].keychain.secrets["apiToken"] = "remote-secret"

        XCTAssertThrowsError(try ReaderExtensionPersistence.applyPrivateCloudConfiguration(
            incoming,
            profileID: profileID,
            metadataStore: metadata,
            preferenceStore: preferences,
            keychain: keychain,
            postMutationVerification: {
                throw ReaderExtensionError.persistenceFailed("durability checkpoint failed")
            }
        ))

        let restored = try ReaderExtensionPersistence.applyingPreferenceOverlay(
            to: ReaderExtensionPersistence.loadInstalledSources(from: metadata),
            from: preferences
        )
        XCTAssertEqual(restored.first?.preferences, source.preferences)
        XCTAssertEqual(keychain.accounts[account], localSecret)
    }

    func testPrivateCloudConfigurationClearsAuthenticationForRemovedSource() throws {
        let metadataSuite = "reader-private-cloud-removed-metadata-\(UUID().uuidString)"
        let profileSuite = "reader-private-cloud-removed-profile-\(UUID().uuidString)"
        let metadata = try XCTUnwrap(UserDefaults(suiteName: metadataSuite))
        let preferences = try XCTUnwrap(UserDefaults(suiteName: profileSuite))
        defer {
            metadata.removePersistentDomain(forName: metadataSuite)
            preferences.removePersistentDomain(forName: profileSuite)
        }
        let profileID = UUID()
        var removedSource = installedSource(implementation: .javascript)
        removedSource.preferenceSchemaFingerprint = String(repeating: "a", count: 64)
        removedSource.secretPreferenceKeys = ["apiToken"]
        removedSource.preferences = ["apiToken": .secretReference("apiToken")]
        try ReaderExtensionPersistence.persist(
            repositories: [],
            installedSources: [],
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: metadata,
            preferenceStore: preferences
        )
        let prefix = "\(profileID.uuidString).\(removedSource.id.rawValue)"
        let cookieData = Data("device-cookie".utf8)
        let declaredData = try JSONEncoder().encode(Set(["declared.example"]))
        let keychain = ReaderExtensionInjectedKeychainAccess(accounts: [
            "\(prefix).secret.apiToken": Data("removed-secret".utf8),
            "\(prefix).user-domains": try JSONEncoder().encode(Set(["reader.example"])),
            "\(prefix).cookies": cookieData,
            "\(prefix).domains": declaredData
        ])
        let staleAdmission = ReaderExtensionAuthenticatedRequestAdmission(
            sourceID: removedSource.id,
            namespace: profileID.uuidString
        )

        try ReaderExtensionPersistence.applyPrivateCloudConfiguration(
            ReaderExtensionPrivateCloudConfiguration(profileID: profileID, sources: []),
            profileID: profileID,
            metadataStore: metadata,
            preferenceStore: preferences,
            keychain: keychain,
            previousSources: [removedSource]
        )

        XCTAssertNil(keychain.accounts["\(prefix).secret.apiToken"])
        XCTAssertNil(keychain.accounts["\(prefix).user-domains"])
        XCTAssertEqual(keychain.accounts["\(prefix).cookies"], cookieData)
        XCTAssertEqual(keychain.accounts["\(prefix).domains"], declaredData)
        XCTAssertThrowsError(try staleAdmission.validate())
    }

    func testReaderMetadataDeletionRollsBackWhenRemovedSourceAuthenticationCleanupFails() throws {
        let metadataSuite = "reader-private-cloud-delete-rollback-metadata-\(UUID().uuidString)"
        let profileSuite = "reader-private-cloud-delete-rollback-profile-\(UUID().uuidString)"
        let metadata = try XCTUnwrap(UserDefaults(suiteName: metadataSuite))
        let preferences = try XCTUnwrap(UserDefaults(suiteName: profileSuite))
        defer {
            metadata.removePersistentDomain(forName: metadataSuite)
            preferences.removePersistentDomain(forName: profileSuite)
        }
        let profileID = UUID()
        var firstSource = installedSource(implementation: .javascript, mediaType: .manga)
        var secondSource = installedSource(implementation: .javascript, mediaType: .novel)
        firstSource.preferenceSchemaFingerprint = String(repeating: "a", count: 64)
        secondSource.preferenceSchemaFingerprint = String(repeating: "b", count: 64)
        firstSource.secretPreferenceKeys = ["apiToken"]
        secondSource.secretPreferenceKeys = ["apiToken"]
        firstSource.preferences = ["apiToken": .secretReference("apiToken")]
        secondSource.preferences = ["apiToken": .secretReference("apiToken")]
        let sourceFixtures = [firstSource, secondSource].sorted {
            $0.id.rawValue < $1.id.rawValue
        }
        try ReaderExtensionPersistence.persist(
            repositories: [],
            installedSources: sourceFixtures,
            showMature: false,
            autoUpdate: true,
            lastAutoUpdate: nil,
            to: metadata,
            preferenceStore: preferences
        )
        let previousSources = try ReaderExtensionPersistence.applyingPreferenceOverlay(
            to: ReaderExtensionPersistence.loadInstalledSources(from: metadata),
            from: preferences
        )
        let accounts = Dictionary(uniqueKeysWithValues: previousSources.map { source in
            (
                "\(profileID.uuidString).\(source.id.rawValue).secret.apiToken",
                Data("secret-\(source.id.rawValue)".utf8)
            )
        })
        let failedAccount = "\(profileID.uuidString).\(previousSources[1].id.rawValue).secret.apiToken"
        let keychain = ReaderExtensionInjectedKeychainAccess(
            accounts: accounts,
            deletionFailureAccounts: [failedAccount]
        )
        let admissions = previousSources.map {
            ReaderExtensionAuthenticatedRequestAdmission(
                sourceID: $0.id,
                namespace: profileID.uuidString
            )
        }
        let incoming = BackupReaderExtensionState(
            metadataJSON: nil,
            installedSourceCount: 0,
            showMatureSources: false,
            autoUpdateSources: true,
            lastAutoUpdate: nil
        )

        XCTAssertThrowsError(try incoming.restore(
            to: metadata,
            preferenceStore: preferences,
            postRestoreVerification: {
                try ReaderExtensionPersistence.applyPrivateCloudConfiguration(
                    ReaderExtensionPrivateCloudConfiguration(profileID: profileID, sources: []),
                    profileID: profileID,
                    metadataStore: metadata,
                    preferenceStore: preferences,
                    keychain: keychain,
                    previousSources: previousSources
                )
            }
        ))

        let restoredSources = try ReaderExtensionPersistence.applyingPreferenceOverlay(
            to: ReaderExtensionPersistence.loadInstalledSources(from: metadata),
            from: preferences
        )
        XCTAssertEqual(restoredSources, previousSources)
        XCTAssertEqual(keychain.accounts, accounts)
        for admission in admissions {
            XCTAssertThrowsError(try admission.validate())
        }
    }

    private func installedSource(
        implementation: ReaderExtensionImplementation,
        mediaType: ReaderExtensionMediaType = .manga,
        additionalParameters: String? = nil,
        name: String = "Owned Fixture"
    ) -> ReaderExtensionInstalledSource {
        let repositoryURL = publicBaseURL.appendingPathComponent("index.json")
        let catalog = ReaderExtensionCatalogSource(
            id: ReaderExtensionSourceID(repositoryURL: repositoryURL, upstreamID: implementation.rawValue, language: "en", mediaType: mediaType),
            upstreamID: implementation.rawValue,
            repositoryID: "fixture",
            repositoryURL: repositoryURL,
            name: name,
            baseURL: publicBaseURL,
            apiURL: nil,
            language: "en",
            mediaType: mediaType,
            implementation: implementation,
            sourceCodeURL: implementation == .javascript ? publicBaseURL.appendingPathComponent("fixture.js") : nil,
            version: "1.0.0",
            maturity: .safe,
            hasCloudflare: false,
            dateFormat: nil,
            dateFormatLocale: nil,
            additionalParameters: additionalParameters,
            notes: nil,
            license: ReaderExtensionLicense(kind: .mit, name: "MIT License", url: nil, textSHA256: nil, detectedAt: Date())
        )
        return ReaderExtensionInstalledSource(catalog: catalog, sortIndex: 0)
    }

    private func catalogSearchSource(
        index: Int,
        name: String,
        language: String,
        maturity: ReaderExtensionMaturity,
        repositoryURL: URL
    ) -> ReaderExtensionCatalogSource {
        let repositoryID = ReaderExtensionRepositoryRecord(indexURL: repositoryURL).id
        let upstreamID = "search-fixture-\(index)"
        return ReaderExtensionCatalogSource(
            id: ReaderExtensionSourceID(
                repositoryURL: repositoryURL,
                upstreamID: upstreamID,
                language: language,
                mediaType: .manga
            ),
            upstreamID: upstreamID,
            repositoryID: repositoryID,
            repositoryURL: repositoryURL,
            name: name,
            baseURL: publicBaseURL,
            apiURL: nil,
            language: language,
            mediaType: .manga,
            implementation: .javascript,
            sourceCodeURL: publicBaseURL.appendingPathComponent("source-\(index).js"),
            version: "1.0.0",
            maturity: maturity,
            hasCloudflare: false,
            dateFormat: nil,
            dateFormatLocale: nil,
            additionalParameters: nil,
            notes: nil,
            license: ReaderExtensionLicense(
                kind: .mit,
                name: "MIT License",
                url: nil,
                textSHA256: nil,
                detectedAt: Date(timeIntervalSince1970: 1)
            )
        )
    }

    private func mangaDexArabicSource(
        languageSelectionVersion: Int?,
        upstreamID: String = "202373705",
        name: String = "MangaDex",
        scriptURL: String = "https://raw.githubusercontent.com/m2k3a/mangayomi-extensions/main/javascript/manga/src/all/mangadex.js",
        repositoryURL rawRepositoryURL: String = "https://m2k3a.github.io/mangayomi-extensions/index.json"
    ) throws -> ReaderExtensionInstalledSource {
        let repositoryURL = try XCTUnwrap(URL(
            string: rawRepositoryURL
        ))
        let catalog = ReaderExtensionCatalogSource(
            id: ReaderExtensionSourceID(
                repositoryURL: repositoryURL,
                upstreamID: upstreamID,
                language: "ar",
                mediaType: .manga
            ),
            upstreamID: upstreamID,
            repositoryID: ReaderExtensionRepositoryRecord(indexURL: repositoryURL).id,
            repositoryURL: repositoryURL,
            name: name,
            baseURL: try XCTUnwrap(URL(string: "https://mangadex.org")),
            apiURL: try XCTUnwrap(URL(string: "https://api.mangadex.org")),
            language: "ar",
            mediaType: .manga,
            implementation: .javascript,
            sourceCodeURL: try XCTUnwrap(URL(string: scriptURL)),
            version: "0.1.4",
            maturity: .safe,
            hasCloudflare: false,
            dateFormat: nil,
            dateFormatLocale: nil,
            additionalParameters: nil,
            notes: nil,
            license: ReaderExtensionLicense(
                kind: .gpl3,
                name: "GPL-3.0-or-later",
                url: nil,
                textSHA256: nil,
                detectedAt: Date(timeIntervalSince1970: 1)
            )
        )
        var source = ReaderExtensionInstalledSource(catalog: catalog, sortIndex: 0)
        source.languageSelectionVersion = languageSelectionVersion
        return source
    }

    private func syntheticNAT64Prefix(length: Int) -> [UInt8] {
        let base: [UInt8] = [
            0x26, 0x06, 0x47, 0x00, 0x71, 0x00, 0x12, 0x34,
            0x00, 0x00, 0x00, 0x00
        ]
        return Array(base.prefix(length / 8))
    }

    private func rfc6052Address(prefix: [UInt8], length: Int, ipv4: [UInt8]) -> [UInt8] {
        precondition(ReaderExtensionNAT64Prefix.supportedLengths.contains(length))
        precondition(prefix.count == length / 8)
        precondition(ipv4.count == 4)
        if length == 96 { return prefix + ipv4 }

        var withoutU = [UInt8](repeating: 0, count: 15)
        withoutU.replaceSubrange(0..<prefix.count, with: prefix)
        withoutU.replaceSubrange(prefix.count..<(prefix.count + 4), with: ipv4)
        return Array(withoutU[0..<8]) + [0] + Array(withoutU[8..<15])
    }

    private func mangaDexAdvancedFilterRows() -> [[String: Any]] {
        func checkBox(_ name: String, _ value: String, state: Bool? = nil) -> [String: Any] {
            var row: [String: Any] = [
                "type_name": "CheckBox",
                "name": name,
                "value": value
            ]
            if let state { row["state"] = state }
            return row
        }

        func triState(_ entry: (String, String)) -> [String: Any] {
            ["type_name": "TriState", "name": entry.0, "value": entry.1]
        }

        func group(_ type: String, _ name: String, _ state: [[String: Any]]) -> [String: Any] {
            ["type_name": "GroupFilter", "type": type, "name": name, "state": state]
        }

        func select(
            _ type: String,
            _ name: String,
            state: Int,
            values: [(String, String)]
        ) -> [String: Any] {
            [
                "type_name": "SelectFilter",
                "type": type,
                "name": name,
                "state": state,
                "values": values.map {
                    ["type_name": "SelectOption", "name": $0.0, "value": $0.1]
                }
            ]
        }

        let formatValues = [
            ("4-Koma", "b11fda93-8f1d-4bef-b2ed-8803d3733170"),
            ("Adaptation", "f4122d1c-3b44-44d0-9936-ff7502c39ad3"),
            ("Anthology", "51d83883-4103-437c-b4b1-731cb73d786c"),
            ("Award Winning", "0a39b5a1-b235-4886-a747-1d05d216532d"),
            ("Doujinshi", "b13b2a48-c720-44a9-9c77-39c9979373fb"),
            ("Fan Colored", "7b2ce280-79ef-4c09-9b58-12b7c23a9b78"),
            ("Full Color", "f5ba408b-0e7a-484d-8d49-4e9125ac96de"),
            ("Long Strip", "3e2b8dae-350e-4ab8-a8ce-016e844b9f0d"),
            ("Official Colored", "320831a8-4026-470b-94f6-8353740e6f04"),
            ("Oneshot", "0234a31e-a729-4e28-9d6a-3f87c4966b9e"),
            ("User Created", "891cf039-b895-47f0-9229-bef4c96eccd4"),
            ("Web Comic", "e197df38-d0e7-43b5-9b09-2842d0c326dd")
        ]
        let genreValues = [
            ("Action", "391b0423-d847-456f-aff0-8b0cfc03066b"),
            ("Adventure", "87cc87cd-a395-47af-b27a-93258283bbc6"),
            ("Boys' Love", "5920b825-4181-4a17-beeb-9918b0ff7a30"),
            ("Comedy", "4d32cc48-9f00-4cca-9b5a-a839f0764984"),
            ("Crime", "5ca48985-9a9d-4bd8-be29-80dc0303db72"),
            ("Drama", "b9af3a63-f058-46de-a9a0-e0c13906197a"),
            ("Fantasy", "cdc58593-87dd-415e-bbc0-2ec27bf404cc"),
            ("Girls' Love", "a3c67850-4684-404e-9b7f-c69850ee5da6"),
            ("Historical", "33771934-028e-4cb3-8744-691e866a923e"),
            ("Horror", "cdad7e68-1419-41dd-bdce-27753074a640"),
            ("Isekai", "ace04997-f6bd-436e-b261-779182193d3d"),
            ("Magical Girls", "81c836c9-914a-4eca-981a-560dad663e73"),
            ("Mecha", "50880a9d-5440-4732-9afb-8f457127e836"),
            ("Medical", "c8cbe35b-1b2b-4a3f-9c37-db84c4514856"),
            ("Mystery", "ee968100-4191-4968-93d3-f82d72be7e46"),
            ("Philosophical", "b1e97889-25b4-4258-b28b-cd7f4d28ea9b"),
            ("Psychological", "3b60b75c-a2d7-4860-ab56-05f391bb889c"),
            ("Romance", "423e2eae-a7a2-4a8b-ac03-a8351462d71d"),
            ("Sci-Fi", "256c8bd9-4904-4360-bf4f-508a76d67183"),
            ("Slice of Life", "e5301a23-ebd9-49dd-a0cb-2add944c7fe9"),
            ("Sports", "69964a64-2f90-4d33-beeb-f3ed2875eb4c"),
            ("Superhero", "7064a261-a137-4d3a-8848-2d385de3a99c"),
            ("Thriller", "07251805-a27e-4d59-b488-f0bfbec15168"),
            ("Tragedy", "f8f62932-27da-4fe4-8ee1-6779a8c5edba"),
            ("Wuxia", "acc803a4-c95a-4c22-86fc-eb6b582d82a2")
        ]
        let themeValues = [
            ("Aliens", "e64f6742-c834-471d-8d72-dd51fc02b835"),
            ("Animals", "3de8c75d-8ee3-48ff-98ee-e20a65c86451"),
            ("Cooking", "ea2bc92d-1c26-4930-9b7c-d5c0dc1b6869"),
            ("Crossdressing", "9ab53f92-3eed-4e9b-903a-917c86035ee3"),
            ("Delinquents", "da2d50ca-3018-4cc0-ac7a-6b7d472a29ea"),
            ("Demons", "39730448-9a5f-48a2-85b0-a70db87b1233"),
            ("Genderswap", "2bd2e8d0-f146-434a-9b51-fc9ff2c5fe6a"),
            ("Ghosts", "3bb26d85-09d5-4d2e-880c-c34b974339e9"),
            ("Gyaru", "fad12b5e-68ba-460e-b933-9ae8318f5b65"),
            ("Harem", "aafb99c1-7f60-43fa-b75f-fc9502ce29c7"),
            ("Loli", "2d1f5d56-a1e5-4d0d-a961-2193588b08ec"),
            ("Mafia", "85daba54-a71c-4554-8a28-9901a8b0afad"),
            ("Magic", "a1f53773-c69a-4ce5-8cab-fffcd90b1565"),
            ("Martial Arts", "799c202e-7daa-44eb-9cf7-8a3c0441531e"),
            ("Military", "ac72833b-c4e9-4878-b9db-6c8a4a99444a"),
            ("Monster Girls", "dd1f77c5-dea9-4e2b-97ae-224af09caf99"),
            ("Monsters", "36fd93ea-e8b8-445e-b836-358f02b3d33d"),
            ("Music", "f42fbf9e-188a-447b-9fdc-f19dc1e4d685"),
            ("Ninja", "489dd859-9b61-4c37-af75-5b18e88daafc"),
            ("Office Workers", "92d6d951-ca5e-429c-ac78-451071cbf064"),
            ("Police", "df33b754-73a3-4c54-80e6-1a74a8058539"),
            ("Post-Apocalyptic", "9467335a-1b83-4497-9231-765337a00b96"),
            ("Reincarnation", "0bc90acb-ccc1-44ca-a34a-b9f3a73259d0"),
            ("Reverse Harem", "65761a2a-415e-47f3-bef2-a9dababba7a6"),
            ("Samurai", "81183756-1453-4c81-aa9e-f6e1b63be016"),
            ("School Life", "caaa44eb-cd40-4177-b930-79d3ef2afe87"),
            ("Shota", "ddefd648-5140-4e5f-ba18-4eca4071d19b"),
            ("Supernatural", "eabc5b4c-6aff-42f3-b657-3e90cbd00b75"),
            ("Survival", "5fff9cde-849c-4d78-aab0-0d52b2ee1d25"),
            ("Time Travel", "292e862b-2d17-4062-90a2-0356caa4ae27"),
            ("Traditional Games", "31932a7e-5b8e-49a6-9f12-2afa39dc544c"),
            ("Vampires", "d7d1730f-6eb0-4ba6-9437-602cac38664c"),
            ("Video Games", "9438db5a-7e2a-4ac0-b39e-e0d95a34b8a8"),
            ("Villainess", "d14322ac-4d6f-4e9b-afd9-629d5f4d8a41"),
            ("Virtual Reality", "8c86611e-fab7-4986-9dec-d1a2f44acdd5"),
            ("Zombies", "631ef465-9aba-4afb-b0fc-ea10efe274a8")
        ]

        return [
            [
                "type_name": "CheckBox",
                "type": "HasAvailableChaptersFilter",
                "name": "Has available chapters",
                "value": ""
            ],
            group("OriginalLanguageList", "Original language", [
                checkBox("Japanese (Manga)", "originalLanguage[]=ja"),
                checkBox("Chinese (Manhua)", "originalLanguage[]=zh&originalLanguage[]=zh-hk"),
                checkBox("Korean (Manhwa)", "originalLanguage[]=ko")
            ]),
            group("ContentRatingList", "Content rating", [
                checkBox("Safe", "contentRating[]=safe", state: true),
                checkBox("Suggestive", "contentRating[]=suggestive", state: true)
            ]),
            group("DemographicList", "Publication demographic", [
                checkBox("None", "publicationDemographic[]=none"),
                checkBox("Shounen", "publicationDemographic[]=shounen"),
                checkBox("Shoujo", "publicationDemographic[]=shoujo"),
                checkBox("Seinen", "publicationDemographic[]=seinen"),
                checkBox("Josei", "publicationDemographic[]=josei")
            ]),
            group("StatusList", "Status", [
                checkBox("Ongoing", "status[]=ongoing"),
                checkBox("Completed", "status[]=completed"),
                checkBox("Hiatus", "status[]=hiatus"),
                checkBox("Cancelled", "status[]=cancelled")
            ]),
            [
                "type_name": "SortFilter",
                "type": "SortFilter",
                "name": "Sort",
                "state": ["type_name": "SortState", "index": 5, "ascending": false],
                "values": [
                    ("Alphabetic", "title"),
                    ("Chapter uploded at", "latestUploadedChapter"),
                    ("Number of follows", "followedCount"),
                    ("Content created at", "createdAt"),
                    ("Content info updated at", "updatedAt"),
                    ("Relevance", "relevance"),
                    ("Year", "year"),
                    ("Rating", "rating")
                ].map {
                    ["type_name": "SelectOption", "name": $0.0, "value": $0.1]
                }
            ],
            group("TagsFilter", "Tags mode", [
                select(
                    "TagInclusionMode",
                    "Included tags mode",
                    state: 0,
                    values: [("AND", "includedTagsMode=AND"), ("OR", "includedTagsMode=OR")]
                ),
                select(
                    "TagExclusionMode",
                    "Excluded tags mode",
                    state: 1,
                    values: [("AND", "excludedTagsMode=AND"), ("OR", "excludedTagsMode=OR")]
                )
            ]),
            group("ContentsFilter", "Content", [
                triState(("Gore", "b29d6a3d-1569-4e7a-8caf-7557bc92cd5d")),
                triState(("Sexual Violence", "97893a4c-12af-4dac-b6be-0dffb353568e"))
            ]),
            group("FormatFilter", "Format", formatValues.map(triState)),
            group("GenreFilter", "Genre", genreValues.map(triState)),
            group("ThemeFilter", "Theme", themeValues.map(triState))
        ]
    }

    private func requiredMangaScript(preferenceBody: String) -> String {
        """
        class DefaultExtension extends MProvider {
          async getPopular(page) { return {list: [], hasNextPage: false}; }
          async search(query, page, filters) { return {list: [], hasNextPage: false}; }
          async getDetail(url) { return {name: "Owned Fixture", chapters: []}; }
          async getPageList(url) { return []; }
          getSourcePreferences() { \(preferenceBody) }
        }
        """
    }

    private func preservingGlobalReaderExtensionSettings(_ body: () throws -> Void) rethrows {
        let global = UserDefaults.standard
        let keys = [
            ReaderExtensionPersistence.showMatureSourcesKey,
            ReaderExtensionPersistence.autoUpdateSourcesKey,
            ReaderExtensionPersistence.lastAutoUpdateKey
        ]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, global.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = previous[key] ?? nil { global.set(value, forKey: key) }
                else { global.removeObject(forKey: key) }
            }
        }
        try body()
    }
}

private final class ReaderExtensionPopularOnlyFixtureProvider: ReaderSourceProvider {
    let source: ReaderExtensionInstalledSource
    private(set) var latestCallCount = 0

    init(source: ReaderExtensionInstalledSource) {
        self.source = source
    }

    func popular(page: Int) async throws -> ReaderExtensionPagedResult {
        ReaderExtensionPagedResult(
            items: [ReaderExtensionItem(key: "owned-popular", title: "Owned Popular")],
            hasNextPage: false
        )
    }

    func latest(page: Int) async throws -> ReaderExtensionPagedResult {
        latestCallCount += 1
        throw ReaderExtensionError.unsupportedSource
    }

    func search(query: String, page: Int, filters: [ReaderExtensionFilter]) async throws -> ReaderExtensionPagedResult {
        ReaderExtensionPagedResult(items: [], hasNextPage: false)
    }

    func detail(itemKey: String) async throws -> ReaderExtensionItem {
        ReaderExtensionItem(key: itemKey, title: "Owned Popular")
    }

    func chapters(itemKey: String) async throws -> [ReaderExtensionChapter] { [] }
    func pages(chapterKey: String) async throws -> [ReaderExtensionPage] { [] }
}

private final class ReaderExtensionFixtureNetwork: ReaderExtensionNetworkClient, @unchecked Sendable {
    let body: Data
    init(body: Data) { self.body = body }
    func request(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        ReaderExtensionNetworkResponse(statusCode: 200, finalURL: request.url, headers: ["Content-Type": "text/html"], body: body)
    }
}

private final class ReaderExtensionRecordingNetwork: ReaderExtensionNetworkClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ReaderExtensionRecordingNetwork")
    private let body: Data
    private var requests: [ReaderExtensionNetworkRequest] = []

    init(body: Data) {
        self.body = body
    }

    var lastRequest: ReaderExtensionNetworkRequest? {
        queue.sync { requests.last }
    }

    func request(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        queue.sync { requests.append(request) }
        return ReaderExtensionNetworkResponse(
            statusCode: 200,
            finalURL: request.url,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }
}

private final class ReaderExtensionDelayedFixtureNetwork: ReaderExtensionNetworkClient, @unchecked Sendable {
    let delayNanoseconds: UInt64
    let body: Data

    init(delayNanoseconds: UInt64, body: Data) {
        self.delayNanoseconds = delayNanoseconds
        self.body = body
    }

    func request(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return ReaderExtensionNetworkResponse(
            statusCode: 200,
            finalURL: request.url,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }
}

private final class ReaderExtensionBlockingAdmissionNetwork: ReaderExtensionNetworkClient, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func request(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        entered.signal()
        guard release.wait(timeout: .now() + 5) == .success else {
            throw ReaderExtensionError.runtimeFailed("owned admission fixture was not released")
        }
        return ReaderExtensionNetworkResponse(
            statusCode: 200,
            finalURL: request.url,
            headers: ["Content-Type": "application/json"],
            body: Data("{}".utf8)
        )
    }
}

private final class ReaderExtensionAdmissionLeaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ReaderExtensionRuntimeAdmissionGate.Lease?

    var value: ReaderExtensionRuntimeAdmissionGate.Lease? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ value: ReaderExtensionRuntimeAdmissionGate.Lease?) {
        lock.lock(); defer { lock.unlock() }
        stored = value
    }
}

private final class ReaderExtensionRecordingPreferenceStore: ReaderExtensionPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private let secretKeys: Set<String>
    private var values: [String: ReaderExtensionPreferenceValue] = [:]
    private var secrets: [String: String] = [:]

    init(secretKeys: Set<String>) { self.secretKeys = secretKeys }

    func value(for key: String) -> ReaderExtensionPreferenceValue? {
        lock.lock(); defer { lock.unlock() }; return values[key]
    }

    func setValue(_ value: ReaderExtensionPreferenceValue, for key: String) throws {
        lock.lock(); defer { lock.unlock() }; values[key] = value
    }

    func secret(for key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }; return secrets[key]
    }

    func setSecret(_ value: String?, for key: String) throws {
        lock.lock(); defer { lock.unlock() }; secrets[key] = value
    }

    func shouldStoreAsSecret(_ key: String) -> Bool {
        secretKeys.contains(key) || ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
    }

    func mayReadSecret(_ key: String) -> Bool {
        shouldStoreAsSecret(key)
    }
}

private final class ReaderExtensionInjectedKeychainAccess: ReaderExtensionKeychainAccess {
    var accounts: [String: Data]
    let enumerationFailure: OSStatus?
    let deletionFailure: OSStatus?
    let deletionFailureAccounts: Set<String>
    let retainDeletedAccounts: Bool
    let beforeAdd: (() -> Void)?
    let addFailure: OSStatus?

    init(
        accounts: [String: Data],
        enumerationFailure: OSStatus? = nil,
        deletionFailure: OSStatus? = nil,
        deletionFailureAccounts: Set<String> = [],
        retainDeletedAccounts: Bool = false,
        beforeAdd: (() -> Void)? = nil,
        addFailure: OSStatus? = nil
    ) {
        self.accounts = accounts
        self.enumerationFailure = enumerationFailure
        self.deletionFailure = deletionFailure
        self.deletionFailureAccounts = deletionFailureAccounts
        self.retainDeletedAccounts = retainDeletedAccounts
        self.beforeAdd = beforeAdd
        self.addFailure = addFailure
    }

    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        if let account = query[kSecAttrAccount as String] as? String {
            guard let data = accounts[account] else { return errSecItemNotFound }
            if query[kSecReturnData as String] as? Bool == true {
                result = data as CFData
            } else {
                result = [kSecAttrAccount as String: account] as CFDictionary
            }
            return errSecSuccess
        }
        if let enumerationFailure { return enumerationFailure }
        guard !accounts.isEmpty else { return errSecItemNotFound }
        result = accounts.keys.sorted().map {
            [kSecAttrAccount as String: $0]
        } as CFArray
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        if let deletionFailure { return deletionFailure }
        guard let account = query[kSecAttrAccount as String] as? String,
              accounts[account] != nil else { return errSecItemNotFound }
        if deletionFailureAccounts.contains(account) { return errSecInteractionNotAllowed }
        if !retainDeletedAccounts { accounts[account] = nil }
        return errSecSuccess
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        guard let account = query[kSecAttrAccount as String] as? String,
              accounts[account] != nil else { return errSecItemNotFound }
        guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        accounts[account] = data
        return errSecSuccess
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        beforeAdd?()
        if let addFailure { return addFailure }
        guard let account = attributes[kSecAttrAccount as String] as? String,
              let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        guard accounts[account] == nil else { return errSecDuplicateItem }
        accounts[account] = data
        return errSecSuccess
    }
}

private final class ReaderExtensionFormPOSTFixtureHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let completed: XCTestExpectation
    private let lock = NSLock()
    private var storedRequest: ReaderExtensionNetworkRequest?

    init(expectation: XCTestExpectation) {
        completed = expectation
    }

    var capturedRequest: ReaderExtensionNetworkRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    func webView(_: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(ReaderExtensionError.insecureURL)
            return
        }
        if task.request.httpMethod?.uppercased() == "POST" {
            do {
                let translated = try ReaderExtensionSignInRequestTranslator.networkRequest(
                    from: task.request,
                    sourceID: ReaderExtensionSourceID(rawValue: "reader:owned-webkit-form"),
                    approvedDomains: ["reader.example"],
                    baseDomain: "reader.example"
                )
                lock.lock()
                storedRequest = translated
                lock.unlock()
                completed.fulfill()
                respond(task, url: url, body: Data("ok".utf8), contentType: "text/plain")
            } catch {
                task.didFailWithError(error)
            }
            return
        }
        let html = """
        <!doctype html><html><body>
        <form id="login" method="post" action="\(ReaderExtensionSignInURLProxy.secureScheme)://reader.example/session">
          <input name="username" value="owned@example.test">
          <input name="password" value="fixture">
        </form>
        <script>document.getElementById('login').submit();</script>
        </body></html>
        """
        respond(task, url: url, body: Data(html.utf8), contentType: "text/html; charset=utf-8")
    }

    func webView(_: WKWebView, stop _: WKURLSchemeTask) {}

    private func respond(
        _ task: WKURLSchemeTask,
        url: URL,
        body: Data,
        contentType: String
    ) {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": contentType,
                "Content-Length": String(body.count)
            ]
        ) else { return }
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }
}

final class ReaderExtensionMetadataReacquisitionPolicyTests: XCTestCase {
    private let repositoryURL = URL(string: "https://extensions.example.org/index.json")!

    private func fixtureSource(
        licenseKind: ReaderExtensionLicenseKind = .mit,
        implementation: ReaderExtensionImplementation = .javascript
    ) -> ReaderExtensionInstalledSource {
        let catalog = ReaderExtensionCatalogSource(
            id: ReaderExtensionSourceID(
                repositoryURL: repositoryURL,
                upstreamID: "fixture",
                language: "en",
                mediaType: .manga
            ),
            upstreamID: "fixture",
            repositoryID: "fixture-repo",
            repositoryURL: repositoryURL,
            name: "Fixture",
            baseURL: URL(string: "https://reader.example.org")!,
            apiURL: nil,
            language: "en",
            mediaType: .manga,
            implementation: implementation,
            sourceCodeURL: implementation == .javascript
                ? URL(string: "https://extensions.example.org/fixture.js")
                : nil,
            version: "1.0.0",
            maturity: .safe,
            hasCloudflare: false,
            dateFormat: nil,
            dateFormatLocale: nil,
            additionalParameters: nil,
            notes: nil,
            license: ReaderExtensionLicense(
                kind: licenseKind,
                name: "Fixture License",
                url: nil,
                textSHA256: nil,
                detectedAt: Date()
            )
        )
        return ReaderExtensionInstalledSource(catalog: catalog, sortIndex: 0)
    }

    func testRestoredMetadataGrantsFreshCatalogDomainsWithoutExpandingScope() {
        let approved = ReaderExtensionMetadataReacquisitionPolicy.fetchAuthorizedDomains(
            allowScopeExpansion: false,
            reacquiresMetadataOnlyInstall: true,
            catalogInstallationDomains: ["extensions.example.org", "reader.example.org"],
            currentInstallationDomains: ["extensions.example.org", "reader.example.org", "cdn.example.org"],
            runtimeAuthorizedDomains: {
                XCTFail("A metadata-only reacquisition must not depend on runtime domain authority")
                return []
            }
        )
        XCTAssertEqual(approved, ["extensions.example.org", "reader.example.org"])
    }

    func testReacquisitionNeverExceedsTheRestoredInstallationDomains() {
        var runtimeAuthorityConsulted = false
        let approved = ReaderExtensionMetadataReacquisitionPolicy.fetchAuthorizedDomains(
            allowScopeExpansion: false,
            reacquiresMetadataOnlyInstall: true,
            catalogInstallationDomains: ["extensions.example.org", "attacker.example.net"],
            currentInstallationDomains: ["extensions.example.org"],
            runtimeAuthorizedDomains: {
                runtimeAuthorityConsulted = true
                return []
            }
        )
        XCTAssertTrue(runtimeAuthorityConsulted)
        XCTAssertEqual(approved, [])
    }

    func testHealthySourceUpdatesKeepRuntimeDomainAuthority() {
        let approved = ReaderExtensionMetadataReacquisitionPolicy.fetchAuthorizedDomains(
            allowScopeExpansion: false,
            reacquiresMetadataOnlyInstall: false,
            catalogInstallationDomains: ["extensions.example.org"],
            currentInstallationDomains: ["extensions.example.org"],
            runtimeAuthorizedDomains: { ["extensions.example.org", "consented.example.org"] }
        )
        XCTAssertEqual(approved, ["extensions.example.org", "consented.example.org"])
    }

    func testScopeExpansionUsesTheFreshCatalogDomains() {
        let approved = ReaderExtensionMetadataReacquisitionPolicy.fetchAuthorizedDomains(
            allowScopeExpansion: true,
            reacquiresMetadataOnlyInstall: false,
            catalogInstallationDomains: ["expanded.example.org"],
            currentInstallationDomains: ["extensions.example.org"],
            runtimeAuthorizedDomains: {
                XCTFail("Scope expansion carries explicit consent and must not consult runtime authority")
                return []
            }
        )
        XCTAssertEqual(approved, ["expanded.example.org"])
    }

    func testNeedsCodeReacquisitionSelectsOnlyRepairableRestoredSources() {
        let restored = fixtureSource().metadataForBackup()
        XCTAssertTrue(
            ReaderExtensionMetadataReacquisitionPolicy.needsCodeReacquisition(restored, blockedSourceIDs: [])
        )

        var healthy = fixtureSource()
        healthy.activeContentDigest = String(repeating: "a", count: 64)
        XCTAssertFalse(
            ReaderExtensionMetadataReacquisitionPolicy.needsCodeReacquisition(healthy, blockedSourceIDs: [])
        )

        XCTAssertFalse(
            ReaderExtensionMetadataReacquisitionPolicy.needsCodeReacquisition(
                restored,
                blockedSourceIDs: [restored.id]
            )
        )

        let unsupported = fixtureSource(implementation: .unsupportedNative).metadataForBackup()
        XCTAssertFalse(
            ReaderExtensionMetadataReacquisitionPolicy.needsCodeReacquisition(unsupported, blockedSourceIDs: [])
        )

        let restrictive = fixtureSource(licenseKind: .restrictive).metadataForBackup()
        XCTAssertFalse(
            ReaderExtensionMetadataReacquisitionPolicy.needsCodeReacquisition(restrictive, blockedSourceIDs: [])
        )
    }

    func testRestoredUnknownLicenseConsentCarriesAcrossDevices() {
        XCTAssertTrue(
            ReaderExtensionMetadataReacquisitionPolicy.allowsUnknownLicense(
                allowScopeExpansion: false,
                currentLicenseKind: .unknown
            )
        )
        XCTAssertFalse(
            ReaderExtensionMetadataReacquisitionPolicy.allowsUnknownLicense(
                allowScopeExpansion: false,
                currentLicenseKind: .mit
            )
        )
        XCTAssertTrue(
            ReaderExtensionMetadataReacquisitionPolicy.allowsUnknownLicense(
                allowScopeExpansion: true,
                currentLicenseKind: .mit
            )
        )
    }

    func testDomainConsentIsOfferedAsAnUpdateConsentReason() {
        let reason = ReaderExtensionSourceUpdateConsentPolicy.reason(
            for: .domainConsentRequired("reader.example.org")
        )
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("reader.example.org") ?? false)
        XCTAssertNil(ReaderExtensionSourceUpdateConsentPolicy.reason(for: .sourceNotFound))
    }
}
#endif
