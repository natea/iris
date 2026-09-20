//
//  VoiceChoiceTests.swift
//
//  LINK_API.md §13: what the phone stores, what it sends, and what it does
//  when the Mac says the stored name is not a voice any more.
//

import XCTest
@testable import IrisLivePrototype

@MainActor
final class VoiceChoiceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "iris.tests.voice.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: Persistence

    func testNoChoiceMeansTheMacDecides() {
        let store = VoiceChoiceStore(defaults: defaults)
        XCTAssertNil(store.selected)
        // §13.4: sending no `voice` is what gets `default_voice`.
        XCTAssertNil(store.requestedVoice)
        XCTAssertEqual(store.effectiveName(macDefault: "Zephyr"), "Zephyr")
    }

    func testAChoiceSurvivesALaunch() {
        VoiceChoiceStore(defaults: defaults).select("Algenib")
        let reloaded = VoiceChoiceStore(defaults: defaults)
        XCTAssertEqual(reloaded.selected, "Algenib")
        XCTAssertEqual(reloaded.requestedVoice, "Algenib")
        XCTAssertEqual(reloaded.effectiveName(macDefault: "Zephyr"), "Algenib")
    }

    func testChoosingTheMacDefaultClearsTheStoredName() {
        let store = VoiceChoiceStore(defaults: defaults)
        store.select("Algenib")
        store.select(nil)
        XCTAssertNil(store.selected)
        XCTAssertNil(VoiceChoiceStore(defaults: defaults).selected)
    }

    func testBlankAndWhitespaceAreNotAChoice() {
        let store = VoiceChoiceStore(defaults: defaults)
        store.select("   ")
        XCTAssertNil(store.selected)
    }

    // MARK: invalid_voice

    func testInvalidVoiceFallsBackToTheMacDefaultAndSaysSo() {
        let store = VoiceChoiceStore(defaults: defaults)
        store.select("Algenib")
        store.fallBackToMacDefault(macDefault: "Zephyr")

        XCTAssertNil(store.selected, "the refused name must not be retried")
        XCTAssertNil(VoiceChoiceStore(defaults: defaults).selected, "and must not survive a launch")
        XCTAssertTrue(store.fallbackNotice.contains("Algenib"))
        XCTAssertTrue(store.fallbackNotice.contains("Zephyr"))
    }

    func testTheFallbackNoticeSurvivesAnUnknownMacDefault() {
        let store = VoiceChoiceStore(defaults: defaults)
        store.select("Algenib")
        store.fallBackToMacDefault(macDefault: "")
        XCTAssertFalse(store.fallbackNotice.isEmpty)
        XCTAssertTrue(store.fallbackNotice.contains("default"))
    }

    func testChoosingAgainClearsTheNotice() {
        let store = VoiceChoiceStore(defaults: defaults)
        store.select("Algenib")
        store.fallBackToMacDefault(macDefault: "Zephyr")
        store.select("Puck")
        XCTAssertTrue(store.fallbackNotice.isEmpty)
    }

    // MARK: Catalogue drift

    func testAStoredNameMissingFromTheCatalogueIsStale() {
        let store = VoiceChoiceStore(defaults: defaults)
        store.select("Algenib")
        XCTAssertTrue(store.isStale(against: [LinkVoice(name: "Zephyr", style: "Bright")]))
    }

    func testCatalogueMatchingIsCaseInsensitive() {
        let store = VoiceChoiceStore(defaults: defaults)
        store.select("algenib")
        XCTAssertFalse(store.isStale(against: [LinkVoice(name: "Algenib", style: "Gravelly")]))
    }

    /// An older desktop sends no catalogue at all. That proves nothing about
    /// the stored name, so it must not be treated as a refusal.
    func testAnEmptyCatalogueIsNeverStale() {
        let store = VoiceChoiceStore(defaults: defaults)
        store.select("Algenib")
        XCTAssertFalse(store.isStale(against: []))
    }

    // MARK: Catalogue decoding

    func testVoiceDecodingAndLabel() {
        let voice = LinkVoice(json: ["name": "Algenib", "style": "Gravelly"])
        XCTAssertEqual(voice?.label, "Algenib · Gravelly")
        XCTAssertEqual(LinkVoice(json: ["name": "Algenib"])?.label, "Algenib")
        XCTAssertNil(LinkVoice(json: ["style": "Gravelly"]), "a voice with no name is not a voice")
        XCTAssertNil(LinkVoice(json: ["name": "   "]))
    }
}
