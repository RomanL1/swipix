import XCTest

/// Run only on a dedicated simulator seeded with Tests/Fixtures via Scripts/seed-simulator.sh.
final class SwipixUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor private func launchAuthorized() -> XCUIApplication {
        addUIInterruptionMonitor(withDescription: "Photos authorization on synthetic QA library") { alert in
            for label in ["Allow Full Access", "Allow Access to All Photos", "Allow", "OK"] {
                if alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            }
            return false
        }
        let app = XCUIApplication()
        app.terminate(); app.resetAuthorizationStatus(for: .photos); app.launch()
        if app.buttons["Choose Photos access"].exists { app.buttons["Choose Photos access"].tap() }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.buttons["Allow Full Access"].waitForExistence(timeout: 2) { springboard.buttons["Allow Full Access"].tap() }
        return app
    }
    @MainActor func testFullscreenPreviewZoomAndReturn() throws {
        let app = launchAuthorized()
        let preview = app.buttons["preview-fullscreen"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10)); preview.tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        let photo = app.images["Full screen photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.pinch(withScale: 2, velocity: 1)
        photo.doubleTap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Fullscreen zoom"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Close"].tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Loading preview…"].exists)
        let card = XCTAttachment(screenshot: app.screenshot()); card.name = "Adaptive review card"; card.lifetime = .keepAlways; add(card)
    }
    @MainActor func testReviewBinRestorePersistenceAndCancelDeletion() throws {
        let app = launchAuthorized()
        app.tabBars.buttons["Bin"].tap()
        if app.buttons["Select all"].waitForExistence(timeout: 3), app.buttons["Select all"].isEnabled {
            app.buttons["Select all"].tap()
            let restore = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Restore '")).firstMatch
            if restore.exists { restore.tap() }
        }
        app.tabBars.buttons["Review"].tap()
        let keep = app.buttons["Keep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 10), "Seed the QA simulator with synthetic photos first")
        keep.tap()
        let undo = app.buttons["Undo last decision"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5)); undo.tap()
        let binButton = app.buttons["review-bin"]
        XCTAssertTrue(binButton.waitForExistence(timeout: 5)); binButton.tap()
        app.tabBars.buttons["Bin"].tap()
        let binPath = FileManager.default.temporaryDirectory.appendingPathComponent("swipix-bin.png")
        try app.screenshot().pngRepresentation.write(to: binPath)
        print("BIN_SCREENSHOT: \(binPath.path)")
        let binShot = XCTAttachment(screenshot: app.screenshot()); binShot.name = "Bin"; binShot.lifetime = .keepAlways; add(binShot)
        XCTAssertTrue(app.buttons["Select all"].waitForExistence(timeout: 5))
        app.buttons["Select all"].tap()
        XCTAssertTrue(app.buttons["Delete 1 from Photos"].exists)
        app.buttons["Delete 1 from Photos"].tap()
        XCTAssertTrue(app.buttons["Delete from Photos"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        // Cancellation leaves the decision and original intact, including after app relaunch.
        app.terminate(); app.launch(); app.tabBars.buttons["Bin"].tap()
        app.buttons["Select all"].tap()
        XCTAssertTrue(app.buttons["Restore 1"].exists)
        app.buttons["Restore 1"].tap()
        XCTAssertTrue(app.staticTexts["Your Bin is empty. Photos you swipe left will appear here."].waitForExistence(timeout: 5))
        app.tabBars.buttons["Review"].tap()
        XCTAssertTrue(app.buttons["Keep"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Swipe screen"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    @MainActor func testCompressionReviewAndSaveKeepsOriginal() throws {
        let app = launchAuthorized()
        XCTAssertTrue(app.buttons["Compress"].waitForExistence(timeout: 10))
        let beforeLabel = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'to review'")).firstMatch.label
        let beforeCount = Int(beforeLabel.split(separator: " ").first ?? "")!
        app.buttons["Compress"].tap()
        app.sliders.firstMatch.adjust(toNormalizedSliderPosition: 0)
        app.buttons["Prepare compressed copy"].tap()
        let save = app.buttons["Save compressed copy to Photos"]
        XCTAssertTrue(app.staticTexts["Copy review"].waitForExistence(timeout: 30))
        for _ in 0..<8 { if save.exists && save.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Compression review"; screenshot.lifetime = .keepAlways; add(screenshot)
        save.tap()
        app.buttons["Save copy — keep original"].tap()
        XCTAssertTrue(app.staticTexts["Copy saved. Original retained."].waitForExistence(timeout: 15))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Keep"].waitForExistence(timeout: 5))
        let afterLabel = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'to review'")).firstMatch.label
        XCTAssertEqual(Int(afterLabel.split(separator: " ").first ?? ""), beforeCount + 1, "A new copy must be added without removing the original")
    }
    @MainActor func testTransactionDeletionAndSystemCancellation() throws {
        let app = launchAuthorized()
        XCTAssertTrue(app.buttons["review-bin"].waitForExistence(timeout: 10))
        app.buttons["review-bin"].tap()
        app.tabBars.buttons["Bin"].tap()
        app.buttons["Select all"].tap()
        app.buttons["Delete 1 from Photos"].tap()
        app.alerts.buttons["Delete from Photos"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.alerts.firstMatch.waitForExistence(timeout: 10))
        let cancel = springboard.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Don' OR label == 'Cancel'")).firstMatch
        XCTAssertTrue(cancel.exists); cancel.tap()
        XCTAssertTrue(app.alerts["Unable to finish"].waitForExistence(timeout: 10))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["Restore 1"].exists, "System cancellation must retain the Bin decision")
        app.buttons["Delete 1 from Photos"].tap()
        app.alerts.buttons["Delete from Photos"].tap()
        XCTAssertTrue(springboard.alerts.firstMatch.waitForExistence(timeout: 10))
        let delete = springboard.alerts.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Delete' AND NOT label CONTAINS[c] 'Don'")).firstMatch
        XCTAssertTrue(delete.exists); delete.tap()
        XCTAssertTrue(app.staticTexts["Your Bin is empty. Photos you swipe left will appear here."].waitForExistence(timeout: 15))
    }
    @MainActor func testZPermissionDenialAndRecovery() throws {
        let app = XCUIApplication()
        app.terminate(); app.resetAuthorizationStatus(for: .photos); app.launch()
        XCTAssertTrue(app.buttons["Choose Photos access"].waitForExistence(timeout: 10))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "Do not request Photos until onboarding's action")
        app.buttons["Choose Photos access"].tap()
        let deny = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Allow' AND label CONTAINS[c] 'Don'")).firstMatch
        XCTAssertTrue(deny.waitForExistence(timeout: 5)); deny.tap()
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Permission denied"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.resetAuthorizationStatus(for: .photos)
        let recovered = launchAuthorized()
        XCTAssertTrue(recovered.segmentedControls.buttons["Review"].waitForExistence(timeout: 10))
    }

    @MainActor func testZZLimitedAccessAndNativePicker() throws {
        let app = XCUIApplication()
        app.terminate(); app.resetAuthorizationStatus(for: .photos); app.launch()
        XCTAssertTrue(app.buttons["Choose Photos access"].waitForExistence(timeout: 10))
        app.buttons["Choose Photos access"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let limit = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Select' OR label CONTAINS[c] 'Limit'")).firstMatch
        XCTAssertTrue(limit.waitForExistence(timeout: 5)); limit.tap()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(app.staticTexts["Selected photos only"].waitForExistence(timeout: 10))
        let chooseMore = app.buttons["Choose more photos"].firstMatch
        XCTAssertTrue(chooseMore.exists); chooseMore.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 10), "The native limited-library picker must be presented")
        done.tap()
        XCTAssertTrue(app.staticTexts["Selected photos only"].waitForExistence(timeout: 10))
    }

}
