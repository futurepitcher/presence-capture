import CoreGraphics
import CoreMedia
import Foundation
import XCTest

@testable import CaptureCore

/// Dictation's rules (R2b), without a microphone, a key or an app: holding the key, what's typed,
/// what ambient audio drops, and the clipboard.
final class DictationTests: XCTestCase {
    // MARK: The key

    private let fnDown = CGEventFlags.maskSecondaryFn.rawValue

    func testHoldingTheKeyBeginsAndReleasingItEnds() {
        var hold = DictationHold(key: .fn)
        XCTAssertEqual(hold.flagsChanged(keyCode: 63, flags: fnDown, at: 10), .begin(1))
        XCTAssertEqual(hold.flagsChanged(keyCode: 63, flags: fnDown, at: 10.1), .none, "a repeat began a second dictation")
        XCTAssertEqual(hold.flagsChanged(keyCode: 56, flags: fnDown | 0x2, at: 10.2), .none, "another modifier ended it")
        XCTAssertEqual(hold.flagsChanged(keyCode: 63, flags: 0, at: 11), .end(1))
        XCTAssertEqual(hold.flagsChanged(keyCode: 63, flags: fnDown, at: 12), .begin(2), "each dictation has a token of its own")
    }

    func testAShortTapIsAnOrdinaryPressNotADictation() {
        var hold = DictationHold(key: .fn)
        XCTAssertEqual(hold.flagsChanged(keyCode: 63, flags: fnDown, at: 0), .begin(1))
        XCTAssertEqual(hold.flagsChanged(keyCode: 63, flags: 0, at: 0.2), .cancel(1, .tooShort))
    }

    func testAReleaseThatNeverArrivesIsCaughtByReadingTheKey() {
        var hold = DictationHold(key: .fn)
        _ = hold.flagsChanged(keyCode: 63, flags: fnDown, at: 0)
        XCTAssertEqual(hold.poll(keyDown: true, at: 1), .none)
        XCTAssertEqual(hold.poll(keyDown: false, at: 1.25), .end(1), "a key no longer down wasn't taken as released")
        XCTAssertNil(hold.token)
        XCTAssertEqual(hold.poll(keyDown: false, at: 1.5), .none)
    }

    func testAReleaseThePollMissedPastTheCapIsStillCancelled() {
        var hold = DictationHold(key: .fn)
        _ = hold.flagsChanged(keyCode: 63, flags: fnDown, at: 0)
        // No poll ran (menu tracking, say); the release arrives late.
        XCTAssertEqual(hold.flagsChanged(keyCode: 63, flags: 0, at: 130), .cancel(1, .tooLong), "a hold over the cap was typed")
    }

    func testAHoldPastTheLimitIsCancelled() {
        var hold = DictationHold(key: .rightOption)
        _ = hold.flagsChanged(keyCode: 61, flags: 0x40, at: 0)
        XCTAssertEqual(hold.poll(keyDown: true, at: 119.9), .none)
        XCTAssertEqual(hold.poll(keyDown: true, at: 120), .cancel(1, .tooLong))
    }

    func testChangingTheKeyMidHoldCancelsAndTheLeftHandKeyNeverStarts() {
        var hold = DictationHold(key: .rightCommand)
        XCTAssertEqual(hold.flagsChanged(keyCode: 55, flags: 0x8 | CGEventFlags.maskCommand.rawValue, at: 0), .none, "left Command began a dictation")
        XCTAssertEqual(hold.flagsChanged(keyCode: 54, flags: 0x10 | CGEventFlags.maskCommand.rawValue, at: 0), .begin(1))
        XCTAssertEqual(hold.setKey(.fn), .cancel(1, .keyChanged))
        XCTAssertEqual(hold.flagsChanged(keyCode: 54, flags: 0, at: 1), .none, "the old key's release ended something")
    }

    func testCancellingForLockPauseOrPermissionEndsWithNothing() {
        for why in [DictationCancel.locked, .paused, .turnedOff, .permissionLost, .tapDisabled] {
            var hold = DictationHold(key: .fn)
            _ = hold.flagsChanged(keyCode: 63, flags: fnDown, at: 0)
            XCTAssertEqual(hold.cancel(why), .cancel(1, why))
            XCTAssertEqual(hold.flagsChanged(keyCode: 63, flags: 0, at: 5), .none, "\(why): a cancelled dictation still ended")
        }
        var idle = DictationHold(key: .fn)
        XCTAssertEqual(idle.cancel(.locked), .none)
    }

    func testTheTapAsksForModifierChangesAlone() {
        XCTAssertEqual(DictationKey.eventMask, CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        XCTAssertEqual(DictationKey.eventMask & (CGEventMask(1) << CGEventType.keyDown.rawValue), 0, "the tap sees keys typed")
    }

    // MARK: What's typed

    func testSpokenCommandsBecomeWhatTheyName() {
        XCTAssertEqual(DictationText.spokenCommands("hello comma world period new line how are you question mark"), "hello, world.\nhow are you?")
        XCTAssertEqual(DictationText.spokenCommands("Dear Sam, new paragraph Thanks Period"), "Dear Sam,\n\nThanks.")
        XCTAssertEqual(DictationText.spokenCommands("a new idea"), "a new idea", "a word that only begins a command was taken for one")
    }

    func testTidyingIsTakenOnlyWhenItRemovesFillersAndFalseStartsOrChangesPunctuation() {
        let said = "um so go to the go to the store and uh buy milk not bread"
        XCTAssertTrue(DictationText.tidyKeepsMeaning("So, go to the store and buy milk, not bread.", of: said))
        XCTAssertTrue(DictationText.tidyKeepsMeaning("SO GO TO THE STORE AND BUY MILK NOT BREAD", of: said))
        XCTAssertTrue(DictationText.tidyKeepsMeaning("Don't stop.", of: "don’t stop"))

        XCTAssertFalse(DictationText.tidyKeepsMeaning("So go to the store and buy milk, bread.", of: said), "a removed \"not\" was taken")
        XCTAssertFalse(DictationText.tidyKeepsMeaning("Send it to Bob, not Alice.", of: "send it to Alice not Bob"), "reordered recipients were taken")
        XCTAssertFalse(DictationText.tidyKeepsMeaning("Buy the the milk.", of: "buy the milk"), "a doubled word was taken")
        XCTAssertFalse(DictationText.tidyKeepsMeaning("Remind me.", of: "remind me at noon"), "a dropped argument was taken")
        XCTAssertFalse(DictationText.tidyKeepsMeaning("Please buy milk.", of: "buy milk"), "an added word was taken")
        XCTAssertFalse(DictationText.tidyKeepsMeaning("Buy oat milk.", of: "buy milk"), "a replaced word was taken")
        XCTAssertFalse(DictationText.tidyKeepsMeaning("Pay $100.", of: "pay €100"), "a currency changed")
        XCTAssertFalse(DictationText.tidyKeepsMeaning("3 + 4", of: "3 - 4 um"), "a sign changed")
        XCTAssertFalse(DictationText.tidyKeepsMeaning("Great 👎", of: "great 👍"), "an emoji changed")
        XCTAssertTrue(DictationText.tidyKeepsMeaning("Pay €100, please.", of: "um pay €100 please"))
    }

    func testTerminalsAndEditorsAreNeverTidied() {
        for app in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.microsoft.VSCode", "com.apple.dt.Xcode"] {
            XCTAssertTrue(DictationText.neverTidied.contains(app), app)
        }
        XCTAssertFalse(DictationText.neverTidied.contains("com.apple.TextEdit"))
    }

    // MARK: Ambient audio doesn't keep a dictation twice

    func testAmbientSpeechSaidWhileDictatingIsDroppedHoweverLateItArrives() {
        let spans = DictationSpans()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        spans.began(at: t0)
        XCTAssertEqual(spans.verdict(at: t0.addingTimeInterval(1), seconds: 2, now: t0.addingTimeInterval(3)), .dictated, "during a dictation")
        spans.ended(at: t0.addingTimeInterval(5))
        XCTAssertEqual(spans.verdict(at: t0.addingTimeInterval(2), seconds: 1, now: t0.addingTimeInterval(6)), .dictated, "delivered after release")
        XCTAssertEqual(spans.verdict(at: t0.addingTimeInterval(4), seconds: 2, now: t0.addingTimeInterval(180)), .dictated, "delivered minutes later")
        XCTAssertEqual(spans.verdict(at: t0.addingTimeInterval(5.4), seconds: 1, now: t0.addingTimeInterval(7)), .dictated, "within the margin")
        XCTAssertEqual(spans.verdict(at: t0.addingTimeInterval(8), seconds: 1, now: t0.addingTimeInterval(10)), .keep)
        XCTAssertEqual(spans.verdict(at: t0.addingTimeInterval(-30), seconds: 2, now: t0.addingTimeInterval(1)), .keep)
        XCTAssertEqual(spans.verdict(at: t0.addingTimeInterval(8), seconds: 1, now: t0.addingTimeInterval(8 + 1 + 601)), .tooLate)
    }

    // MARK: The first word

    func testWhatsHeardBeforeTheTranscriberIsReadyIsGivenFirstAndInOrder() {
        let feed = DictationFeed<Int>(limit: 2)
        feed.take(1, at: CMTime(value: 0, timescale: 10), seconds: 0.5)
        feed.take(2, at: CMTime(value: 5, timescale: 10), seconds: 0.5)
        var given: [Int] = []
        feed.ready { buffer, _ in given.append(buffer) }
        feed.take(3, at: CMTime(value: 10, timescale: 10), seconds: 0.5)
        XCTAssertEqual(given, [1, 2, 3], "the first word was lost or out of order")

        let capped = DictationFeed<Int>(limit: 1)
        for i in 0..<4 { capped.take(i, at: .zero, seconds: 0.5) }
        var kept: [Int] = []
        capped.ready { buffer, _ in kept.append(buffer) }
        XCTAssertEqual(kept, [0, 1], "more than the limit was held")
        capped.close()
        capped.take(9, at: .zero, seconds: 0.1)
        XCTAssertEqual(kept, [0, 1], "a closed feed gave more")
    }

    // MARK: The clipboard

    private final class FakePasteboard: Clipboard {
        var changeCount = 0
        var items: [[String: Data]] = [["public.utf8-plain-text": Data("the person's".utf8)]]
        var text: String? { items.first?["public.utf8-plain-text"].map { String(decoding: $0, as: UTF8.self) } }
        func snapshot() -> [[String: Data]] { items }
        func restore(_ items: [[String: Data]]) { self.items = items; changeCount += 1 }
        func write(_ text: String) { items = [["public.utf8-plain-text": Data(text.utf8)]]; changeCount += 1 }
    }

    /// Runs scheduled work when told, in time order, as the main run loop would.
    private final class Later {
        var waiting: [(at: TimeInterval, run: () -> Void)] = []
        var now: TimeInterval = 0
        func schedule(_ delay: TimeInterval, _ run: @escaping () -> Void) { waiting.append((now + delay, run)) }
        func advance(to time: TimeInterval) {
            while let next = waiting.enumerated().filter({ $0.element.at <= time }).min(by: { $0.element.at < $1.element.at }) {
                waiting.remove(at: next.offset)
                now = next.element.at
                next.element.run()
            }
            now = time
        }
    }

    func testAPasteRestoresTheClipboardOnlyWhileItHoldsTheDictation() {
        let board = FakePasteboard(), later = Later()
        var pasted: [String?] = []
        let paster = ClipboardPaster(pasteboard: board, paste: { pasted.append(board.text) }, schedule: later.schedule)
        var restored: Bool?
        paster.paste("dictated") { restored = $0 }
        XCTAssertEqual(pasted, ["dictated"])
        later.advance(to: 1)
        XCTAssertEqual(restored, true)
        XCTAssertEqual(board.text, "the person's")

        // Something else copies before the restore: it's left as it is.
        paster.paste("again") { restored = $0 }
        board.write("copied meanwhile")
        later.advance(to: 3)
        XCTAssertEqual(restored, false)
        XCTAssertEqual(board.text, "copied meanwhile")
    }

    func testAPasteWaitingItsTurnIsCheckedWhenItsMadeAndQuitPutsTheClipboardBack() {
        let board = FakePasteboard(), later = Later()
        var pasted: [String?] = []
        let paster = ClipboardPaster(pasteboard: board, paste: { pasted.append(board.text) }, schedule: later.schedule)
        var allowed = true
        var second: Bool?? = .none
        paster.paste("first")
        paster.paste("second", check: { $0(allowed) }, done: { second = .some($0) })
        // While the first holds the clipboard, the focus moves (or Pause): the second isn't made.
        allowed = false
        later.advance(to: 1)
        XCTAssertEqual(pasted, ["first"], "a paste was made after its check said no")
        XCTAssertEqual(second, .some(nil))
        XCTAssertEqual(board.text, "the person's")

        // Quitting with a paste holding the clipboard: put back at once.
        paster.paste("third")
        paster.finishNow()
        XCTAssertEqual(board.text, "the person's", "the clipboard was left holding a dictation")
    }

    func testTwoOverlappingPastesLeaveThePersonsClipboardNotADictation() {
        let board = FakePasteboard(), later = Later()
        var pasted: [String?] = []
        let paster = ClipboardPaster(pasteboard: board, paste: { pasted.append(board.text) }, schedule: later.schedule)
        paster.paste("first")
        later.advance(to: 0.1)
        paster.paste("second")
        XCTAssertEqual(pasted, ["first"], "the second paste didn't wait for the first's restore")
        later.advance(to: 5)
        XCTAssertEqual(pasted, ["first", "second"])
        XCTAssertEqual(board.text, "the person's", "a dictation was left on the clipboard")
    }

    // MARK: Typing in, and keeping

    func testFocusThatMovedOrASecureFieldTypesNothing() {
        let field = DictationFocus(app: "com.apple.TextEdit", element: 1, security: .open)
        let other = DictationFocus(app: "com.apple.TextEdit", element: 2, security: .open)
        let password = DictationFocus(app: "com.apple.TextEdit", element: 3, security: .secure)
        let unknown = DictationFocus(app: "com.apple.TextEdit", element: nil, security: .open)
        let unsure = DictationFocus(app: "com.apple.TextEdit", element: 1, security: .unknown)
        XCTAssertEqual(DictationOutcome.typing(began: field, released: field, now: field), .type)
        XCTAssertEqual(DictationOutcome.typing(began: field, released: other, now: other), .focusMoved)
        XCTAssertEqual(DictationOutcome.typing(began: field, released: field, now: DictationFocus(app: "com.apple.Safari", element: 1, security: .open)), .focusMoved)
        // Released in a password field, then back: still refused.
        XCTAssertEqual(DictationOutcome.typing(began: field, released: password, now: field), .secure)
        // A field that can't be identified is never taken for the same one.
        XCTAssertEqual(DictationOutcome.typing(began: unknown, released: unknown, now: unknown), .focusMoved)
        // A field whose security couldn't be told is taken as a password field.
        XCTAssertEqual(DictationOutcome.typing(began: unsure, released: unsure, now: unsure), .secure)
    }

    func testWhatsKeptAndWhatIsnt() {
        XCTAssertNil(DictationOutcome.skip(remember: true, excluded: false, secure: false, cancelled: false, paused: false))
        XCTAssertEqual(DictationOutcome.skip(remember: false, excluded: false, secure: false, cancelled: false, paused: false), .rememberOff)
        XCTAssertEqual(DictationOutcome.skip(remember: true, excluded: true, secure: false, cancelled: false, paused: false), .excluded)
        XCTAssertEqual(DictationOutcome.skip(remember: true, excluded: false, secure: true, cancelled: false, paused: false), .secure)
        XCTAssertEqual(DictationOutcome.skip(remember: true, excluded: false, secure: false, cancelled: true, paused: false), .cancelled)
        XCTAssertEqual(DictationOutcome.skip(remember: true, excluded: false, secure: false, cancelled: false, paused: true), .paused)
    }

    // MARK: The transcriber, made ahead

    /// What was asked of `make`, and whether a download works now.
    private final class Made: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [Bool] = []
        private var online = false
        private var gate: CheckedContinuation<Void, Never>?
        private var holding = false
        var downloads: [Bool] { lock.withLock { asked } }
        var reachable: Bool {
            get { lock.withLock { online } }
            set { lock.withLock { online = newValue } }
        }
        func hold() { lock.withLock { holding = true } }
        var waiting: Bool { lock.withLock { gate != nil } }
        func release() {
            lock.withLock {
                holding = false
                gate?.resume()
                gate = nil
            }
        }
        /// No model on this Mac: only a download, while reachable, makes one.
        func make(_ download: Bool) async -> Int? {
            let held = lock.withLock { () -> Bool in
                asked.append(download)
                return holding
            }
            if held { await withCheckedContinuation { c in lock.withLock { gate = c } } }
            return download && reachable ? 1 : nil
        }
    }

    private func until(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testOneThatFailedIsntKeptSoTurningDictationOnAgainDownloads() async {
        let made = Made()
        let ahead = MadeAhead<Int> { await made.make($0) }
        ahead.prepare(download: true)
        await until { !ahead.waiting }
        XCTAssertEqual(made.downloads, [true])
        // Used, with nothing to hear it; and made again after, without leave to download.
        let used = await ahead.take().value
        XCTAssertNil(used)
        ahead.prepare(download: false)
        await until { !ahead.waiting }
        // Turned on again, now online: a download, not the failure kept from before.
        made.reachable = true
        ahead.prepare(download: true)
        let ready = await ahead.take().value
        XCTAssertEqual(ready, 1)
        XCTAssertEqual(made.downloads, [true, false, false, true])
    }

    func testADownloadAskedForWhileOneWithoutIsBeingMadeComesNextIfThatFails() async {
        let made = Made()
        made.reachable = true
        made.hold()
        let ahead = MadeAhead<Int> { await made.make($0) }
        ahead.prepare(download: false)
        await until { made.waiting }
        ahead.prepare(download: true)
        made.release()
        await until { made.downloads.count == 2 && ahead.waiting }
        let ready = await ahead.take().value
        XCTAssertEqual(ready, 1)
        XCTAssertEqual(made.downloads, [false, true])
    }
}
