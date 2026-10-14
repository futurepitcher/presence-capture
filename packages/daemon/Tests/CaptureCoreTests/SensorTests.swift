import AVFoundation
import CoreMedia
import CoreText
import Foundation
import XCTest

@testable import CaptureCore

final class OCRTests: XCTestCase {
    /// Black text on white, drawn here: no screen, no permission.
    private func page(_ lines: [String], width: Int = 900, height: Int = 300, size: CGFloat = 40) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font, .init(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
            context.textPosition = CGPoint(x: 40, y: CGFloat(height) - 2 * size - CGFloat(index) * size * 2.25)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testReadsEachLineTopToBottomWithItsBox() throws {
        let lines = try OCR.read(try page(["Trip budget draft", "Flights and hotel"]))
        XCTAssertEqual(lines.map(\.text), ["Trip budget draft", "Flights and hotel"])
        XCTAssertGreaterThan(lines[0].y, lines[1].y, "the first line is the higher one")
        XCTAssertTrue(lines.allSatisfy { $0.conf > 0.3 && $0.w > 0 && $0.h > 0 })
        XCTAssertTrue(lines.allSatisfy { [$0.x, $0.y, $0.w, $0.h].allSatisfy { abs($0 * 10_000 - ($0 * 10_000).rounded()) < 1e-6 } }, "boxes to a ten-thousandth")
    }

    func testSeesAChangeOfOneSmallCharacterInALargeWindow() throws {
        // A Retina window, one digit changed in a corner: a thumbnail would hash them alike.
        let before = try page(["Budget", "Total 7"], width: 2880, height: 1800, size: 14)
        let after = try page(["Budget", "Total 1"], width: 2880, height: 1800, size: 14)
        XCTAssertNotEqual(OCR.hash(before), OCR.hash(after))
    }

    func testOrdersLinesRowByRowEvenOnASlantedBaseline() {
        // Each next to the next by less than a row's slack, the first and last by more: rows first,
        // each left to right, so the order never depends on which pairs a sort compares.
        let line = { (text: String, x: Double, y: Double) in Line(text: text, conf: 1, x: x, y: y, w: 0.1, h: 0.02) }
        let lines = [line("c", 0.1, 0.500), line("b", 0.5, 0.504), line("a", 0.9, 0.508), line("top", 0.2, 0.9)]
        for shuffled in [lines, lines.reversed(), [lines[1], lines[3], lines[0], lines[2]]] {
            XCTAssertEqual(OCR.ordered(shuffled).map(\.text), ["top", "b", "a", "c"])
        }
    }

    func testHashesTheSameImageAlikeAndAChangedOneNot() throws {
        let first = try page(["Trip budget draft"])
        XCTAssertEqual(OCR.hash(first), OCR.hash(try page(["Trip budget draft"])))
        XCTAssertNotEqual(OCR.hash(first), OCR.hash(try page(["Trip budget final, sent"])))
    }
}

final class UtteranceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_791_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testKeepsEachUtteranceStampedWhenItWasSaid() {
        let spoken = Utterance.row("let's ship it", start: at(2), end: at(4.04), device: "MacBook Pro Microphone (input)", deviceType: "input")
        XCTAssertEqual(spoken?.at, at(2), "when it began, so an assistant's own voice can be told apart by when it was said")
        XCTAssertEqual(spoken?.seconds, 2, "its length, to a tenth of a second")
        XCTAssertEqual(spoken?.text, "let's ship it")
        XCTAssertEqual(spoken?.device, "MacBook Pro Microphone (input)")
        XCTAssertEqual(spoken?.deviceType, "input")
    }

    func testKeepsNoWordTheTranscriberWasUnsureOf() {
        let row = { (text: String, conf: Double?) in Utterance.row(text, start: self.at(0), end: self.at(1), device: "mic", deviceType: "input", conf: conf) }
        // On real speech here: one-word rows below 0.6 were mostly noise; longer ones only below 0.3.
        XCTAssertNil(row("Yeah.", 0.55), "a single word it was unsure of")
        XCTAssertNotNil(row("Yeah.", 0.6))
        XCTAssertNil(row("so we should", 0.25))
        XCTAssertNotNil(row("so we should", 0.35), "longer words kept unless it was quite unsure")
        XCTAssertNotNil(row("Yeah.", nil), "kept when it didn't say how sure it was")
        XCTAssertNotNil(row("今日はいい天気です", 0.45), "words without spaces between them are still several words")
        XCTAssertNil(row("はい", 0.45), "and one is still one")
        XCTAssertEqual(row("ship it", 0.9)?.conf, 0.9)
    }

    func testKeepsNoRowOfSilence() {
        XCTAssertNil(Utterance.row("  \n", start: at(0), end: at(1), device: "System Audio (output)", deviceType: "output"))
    }

    func testDatesWhatWasSaidByHowLongAgoItEndedOnItsStreamsClock() {
        let range = CMTimeRange(start: CMTime(seconds: 990, preferredTimescale: 600), end: CMTime(seconds: 994, preferredTimescale: 600))
        let heard = Utterance.wallTimes(range, clockNow: CMTime(seconds: 1000, preferredTimescale: 600), now: at(60))
        XCTAssertEqual(heard.end, at(54))
        XCTAssertEqual(heard.start, at(50))
        let future = Utterance.wallTimes(range, clockNow: CMTime(seconds: 900, preferredTimescale: 600), now: at(60))
        XCTAssertEqual(future.end, at(60), "a time that can't be: just now")
        XCTAssertEqual(future.start, at(56))
    }
}

final class TranscriberTests: XCTestCase {
    /// Speech made here by `say`, read from a file: no microphone, no permission. Skipped on a Mac
    /// without the speech model (nothing is downloaded by a test).
    func testHearsSpeechAndSaysWhenOnTheStreamsClock() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("needs macOS 26") }
        guard let locale = try await Transcriber.prepare(locale: Locale(identifier: "en_US"), download: false) else { throw XCTSkip("no speech model on this Mac") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-say-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let speech = dir.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", speech.path, "--data-format=LEI16@22050", "Let's ship the deck on Friday."]
        try say.run()
        say.waitUntilExit()
        XCTAssertEqual(say.terminationStatus, 0)

        let heard = Heard()
        let transcriber = try await Transcriber(locale: locale) { text, range, _ in heard.add(text, range) }
        let file = try AVAudioFile(forReading: speech)
        let rate = file.processingFormat.sampleRate
        var position: AVAudioFramePosition = 0
        while position < file.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            try file.read(into: buffer)
            transcriber.feed(buffer, at: CMTime(seconds: 1000 + Double(position) / rate, preferredTimescale: 48_000))
            position += AVAudioFramePosition(buffer.frameLength)
        }
        // Made to finish what's older than half a second while still listening: what was said is
        // given without waiting for the stream to end, so no row waits long to be written.
        let end = CMTime(seconds: 1000 + Double(file.length) / rate, preferredTimescale: 48_000)
        transcriber.settle(olderThan: 0.5, now: end)
        for _ in 0..<50 where heard.all.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(heard.all.isEmpty, "given before the stream ended")
        await transcriber.finish()

        let all = heard.all
        let words = all.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(words.contains("ship") && words.contains("friday"), words)
        let first = try XCTUnwrap(all.first?.range)
        XCTAssertGreaterThanOrEqual(first.start.seconds, 999.9, "on the clock its audio was given with")
        XCTAssertLessThanOrEqual(first.end.seconds, 1000 + Double(file.length) / rate + 0.5)
    }
}

extension TranscriberTests {
    /// Dictation's first word (R2b): audio heard before the transcriber is ready is held, then given
    /// first, so the opening word is in the text.
    func testTheFirstWordFedBeforeTheTranscriberIsReadyIsHeard() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("needs macOS 26") }
        guard let locale = try await Transcriber.prepare(locale: Locale(identifier: "en_US"), download: false) else { throw XCTSkip("no speech model on this Mac") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-say-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let speech = dir.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", speech.path, "--data-format=LEI16@22050", "Pineapple meeting moved to Thursday."]
        try say.run()
        say.waitUntilExit()

        let feed = DictationFeed<AVAudioPCMBuffer>()
        let file = try AVAudioFile(forReading: speech)
        let rate = file.processingFormat.sampleRate
        var position: AVAudioFramePosition = 0
        // All of it heard before there's a transcriber.
        while position < file.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            try file.read(into: buffer)
            feed.take(buffer, at: CMTime(seconds: 1000 + Double(position) / rate, preferredTimescale: 48_000), seconds: Double(buffer.frameLength) / rate)
            position += AVAudioFramePosition(buffer.frameLength)
        }
        let heard = Heard()
        let transcriber = try await Transcriber(locale: locale) { text, range, _ in heard.add(text, range) }
        feed.ready { buffer, time in transcriber.feed(buffer, at: time) }
        feed.close()
        await transcriber.finish()
        let words = heard.all.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(words.hasPrefix("pineapple"), "the first word was lost: \(words)")
    }

    /// A source that went quiet (no more buffers, as system audio sends none in silence): by the
    /// clock, all it heard is older than the cutoff, so all of it is finished, without more audio.
    func testFinishesWhatAQuietSourceHeardByTheClock() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("needs macOS 26") }
        guard let locale = try await Transcriber.prepare(locale: Locale(identifier: "en_US"), download: false) else { throw XCTSkip("no speech model on this Mac") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pc-say-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let speech = dir.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", speech.path, "--data-format=LEI16@22050", "See you on Monday."]
        try say.run()
        say.waitUntilExit()
        let heard = Heard()
        let transcriber = try await Transcriber(locale: locale) { text, range, _ in heard.add(text, range) }
        let file = try AVAudioFile(forReading: speech)
        let rate = file.processingFormat.sampleRate
        var position: AVAudioFramePosition = 0
        while position < file.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
            try file.read(into: buffer)
            transcriber.feed(buffer, at: CMTime(seconds: 1000 + Double(position) / rate, preferredTimescale: 48_000))
            position += AVAudioFramePosition(buffer.frameLength)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        // 25 s on, nothing more fed: the cutoff (now − 20 s) is past all of it.
        transcriber.settle(olderThan: 20, now: CMTime(seconds: 1000 + Double(file.length) / rate + 25, preferredTimescale: 48_000))
        for _ in 0..<50 where heard.all.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(heard.all.map(\.text).joined().lowercased().contains("monday"), "given while still listening")
        await transcriber.finish()
    }
}

/// What a transcriber heard, gathered from its callbacks.
private final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(text: String, range: CMTimeRange)] = []
    func add(_ text: String, _ range: CMTimeRange) { lock.lock(); items.append((text, range)); lock.unlock() }
    var all: [(text: String, range: CMTimeRange)] { lock.lock(); defer { lock.unlock() }; return items }
}

final class FrontWindowTests: XCTestCase {
    private func listed(_ id: CGWindowID, pid: pid_t = 42, width: Double = 1512, height: Double = 949, alpha: Double = 1) -> FrontWindow.Listed {
        FrontWindow.Listed(id: id, pid: pid, layer: 0, width: width, height: height, alpha: alpha)
    }

    func testSkipsAnInvisibleStripInFrontOfTheRealWindow() {
        // Claude: an invisible 1512x32 strip (7) in front of its real window (9).
        let list = [listed(7, height: 32, alpha: 0), listed(9), listed(12)]
        XCTAssertEqual(FrontWindow.of([9, 12], pid: 42, frontToBack: list), 9)
        XCTAssertEqual(FrontWindow.of([9, 12], pid: 42, frontToBack: [list[0], list[2], list[1]]), 12)
    }

    func testMarksNoneWhenTheFrontWindowWasntCaptured() {
        // A window the app opened after the windows were listed for capture: in front, not captured.
        XCTAssertNil(FrontWindow.of([9], pid: 42, frontToBack: [listed(15), listed(9)]))
        XCTAssertEqual(FrontWindow.of([9], pid: 42, frontToBack: [listed(3, pid: 77), listed(9)]), 9, "another app's window is no matter")
    }
}
