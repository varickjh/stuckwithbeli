import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import Vision

private struct AutomationConfiguration: Decodable {
    let sessionId: String
    let restaurantName: String
    let address: String
    let rating: String
    let category: String
    let description: String
    let visitDate: String
    let photoPaths: [String]
    let photoDescriptions: [String]?
    let debugDirectory: String?
    // Populated once `compare_restaurants` duel automation is implemented;
    // decoded now so config.json's shape doesn't need to change again then.
    let existingRatings: [String: Double]?
    let computedScore: Double?
}

private struct OCRItem: Encodable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var center: CGPoint {
        CGPoint(x: x + width / 2, y: y + height / 2)
    }
}

private enum AutomationFailure: LocalizedError {
    case message(String)
    case photosNotFound

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .photosNotFound: "Not every meal photo could be matched in the Beli album."
        }
    }

    var recoveryCode: String? {
        switch self {
        case .message: nil
        case .photosNotFound: "photos_not_found"
        }
    }
}

private final class PhoneScreenshot {
    let window: SCWindow
    private var hasCapturedImage = false

    init() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let phoneWindow = content.windows.first(where: { window in
            let appName = window.owningApplication?.applicationName.lowercased() ?? ""
            return appName.contains("iphone mirroring")
        }) else {
            throw AutomationFailure.message("iPhone Mirroring is not open.")
        }
        window = phoneWindow
    }

    func image() async throws -> CGImage {
        if hasCapturedImage {
            try await Task.sleep(
                nanoseconds: UInt64.random(in: 0...200_000_000)
            )
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        hasCapturedImage = true
        return image
    }
}

private final class BeliAutomation {
    private let configuration: AutomationConfiguration
    private let startStep: String
    // A continuous ScreenCaptureKit stream, not one-off screenshots -- Beli
    // detects discrete screenshots and responds with its own share-sheet
    // nudge (confirmed live, see StreamingPhoneScreenshot), which would
    // otherwise interrupt every OCR-driven step in this whole automation.
    private let capture: StreamingPhoneScreenshot
    private let visionQueue = DispatchQueue(label: "auto-beli.vision")
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var reportedWindowMove = false

    // How close a feature-print distance must be to call a thumbnail "this photo".
    // Measured live: clear genuine matches 0.74-0.83, but a genuine photo in the
    // picker's bottom row reads 0.91+ because the date-search bar covers part of
    // its cell; unrelated photos 1.1+; and a sibling dish photographed at the
    // same table 0.91-0.96. The last two overlap, so no cutoff separates them --
    // tightening it would reject real photos. Protection is structural instead:
    // a click TOGGLES a photo, so a cell is never clicked twice on a page
    // (see selectPhotos), and the description step checks every photo made it
    // into Beli's list.
    private static let photoMatchCutoff: Float = 0.95

    init(configuration: AutomationConfiguration, startStep: String) async throws {
        self.configuration = configuration
        self.startStep = startStep
        capture = try await StreamingPhoneScreenshot.start()
    }

    fileprivate func cleanup() async {
        await capture.stop()
    }

    func run() async throws {
        do {
            try await runSteps()
        } catch {
            await recordFailure(error)
            throw error
        }
    }

    // Only the photo step used to keep a frame when it failed, so most failures
    // left nothing to look at. Keep the last frame and the text on it for any of
    // them; the text goes to the server log next to the other diagnostics.
    private func recordFailure(_ error: Error) async {
        guard let image = try? await capture.image() else { return }
        saveDebugImage(image, named: "failure-latest.png")
        let seen = ((try? recognizeText(in: image)) ?? [])
            .map { "\"\($0.text)\"@\(String(format: "%.2f", $0.center.y))" }
            .joined(separator: ", ")
        emit(
            type: "diagnostic",
            step: nil,
            message: "failed: \(error.localizedDescription) | screen text: \(seen)"
        )
    }

    private func runSteps() async throws {
        if startStep == "skip_photos" {
            try await skipPhotos()
            try await finishingInBeli()
            emit(type: "complete", step: nil, message: nil)
            return
        }
        if startStep == "continue_photos" {
            try await continueFromPhotoPicker()
            try await addingPhotoDescriptions()
            try await finishingInBeli()
            emit(type: "complete", step: nil, message: nil)
            return
        }
        guard let startIndex = Self.stepOrder.firstIndex(of: startStep) else {
            throw AutomationFailure.message("The retry checkpoint is invalid.")
        }
        if startIndex <= 0 { try await openingBeli() }
        if startIndex <= 1 { try await findingRestaurant() }
        if startIndex <= 2 { try await startingRating() }
        if startIndex <= 3 { try await choosingCategory() }
        if startIndex <= 4 { try await addingRating() }
        if startIndex <= 5 { try await addingNotes() }
        if startIndex <= 6 { try await settingVisitDate() }
        if startIndex <= 7 { try await findingPhotos() }
        if startIndex <= 8 { try await addingPhotoDescriptions() }
        if startIndex <= 9 { try await finishingInBeli() }
        emit(type: "complete", step: nil, message: nil)
    }

    private func openingBeli() async throws {
        start("open_beli")
        activatePhoneWindow()
        _ = try await waitForText("beli", timeout: 90) { item in
            item.center.x < 0.32 && item.center.y < 0.25
        }
        finish("open_beli")
    }

    private func findingRestaurant() async throws {
        start("find_restaurant")
        // Beli has reworded this box more than once ("Search a restaurant",
        // "Search restaurant, cuisine, occasion", now "Search a restaurant,
        // member, etc."), so no phrase here has stayed true. What has kept
        // working is the bottom "Search" tab, which opens the same screen --
        // so aim at that on purpose instead of by way of a partial match.
        let search = try await waitForText("search", timeout: 30) { $0.center.y > 0.85 }
        try await clickDetectedTarget(search.center)
        try await pause(1.1)
        try typeText("\(configuration.restaurantName) \(configuration.address)")

        let currentLocation = try await waitForText("current location", timeout: 20)
        let prefix = String(configuration.restaurantName.prefix(10))
        let resultPredicate: (OCRItem) -> Bool = { item in
            item.center.y > currentLocation.center.y + 0.025
        }
        let firstResult = try await waitForText(prefix, timeout: 45, predicate: resultPredicate)
        emit(
            type: "diagnostic",
            step: "find_restaurant",
            message: "search result \"\(firstResult.text)\" found at \(firstResult.center), tapping"
        )
        // Tap the restaurant NAME (not the row's own "+"/bookmark icons,
        // which are a different action) to open its profile page. A blind
        // tap here doesn't reliably register or land correctly even with a
        // fixed double-tap (confirmed live -- this is the *same* code path
        // on both a working and a failing run, so it isn't a timing fluke
        // that a longer pause fixes). Retry against a freshly re-located row
        // each attempt, and confirm the profile page actually opened -- its
        // own teal rating button is visible, the same one start_rating looks
        // for -- before moving on, instead of trusting a fixed tap count.
        try click(firstResult.center)
        try await pause(0.9)
        var opened = false
        for _ in 0..<5 {
            if Self.findTealCircle(in: try await capture.image()) != nil {
                opened = true
                break
            }
            if let result = try await findText(prefix, timeout: 3, predicate: resultPredicate) {
                emit(
                    type: "diagnostic",
                    step: "find_restaurant",
                    message: "still on search results, retrying tap at \(result.center)"
                )
                try click(result.center)
            }
            try await pause(0.9)
        }
        if !opened {
            opened = Self.findTealCircle(in: try await capture.image()) != nil
        }
        guard opened else {
            throw AutomationFailure.message("Tapping the restaurant did not open its profile page.")
        }
        finish("find_restaurant")
    }

    private func addingRating() async throws {
        start("add_rating")
        let label: String
        switch configuration.rating {
        case "liked": label = "i liked it"
        case "fine": label = "it was fine"
        case "disliked": label = "i didn’t like it"
        default: throw AutomationFailure.message("The selected rating is invalid.")
        }

        let ratingLabel = try await waitForText(label, timeout: 15)
        try await clickDetectedTarget(
            CGPoint(x: ratingLabel.center.x, y: max(0.05, ratingLabel.center.y - 0.055))
        )
        finish("add_rating")
    }


    // Duels ("Which do you prefer?") appear AFTER tapping "Okay" on the full
    // form, as part of finishingInBeli()'s wait for the share page -- NOT
    // right after picking a tier (confirmed live; an earlier attempt at a
    // separate compare_restaurants step between add_rating and add_notes
    // was wrong). Called from within that step's polling loop.
    private func resolveAnyPendingDuels() async throws {
        let deadline = Date().addingTimeInterval(10 * 60)
        var duelCount = 0

        while Date() < deadline && duelCount < 60 {
            let image = try await capture.image()
            let items = try recognizeText(in: image)

            guard let duel = parseDuelScreen(items) else { break }
            duelCount += 1

            guard let opponentScore = duel.opponentScore,
                  let computedScore = configuration.computedScore
            else {
                if let tooTough = try? await findText("too tough", timeout: 3) {
                    try await clickDetectedTarget(tooTough.center)
                }
                emit(
                    type: "duel",
                    step: "finish_in_beli",
                    message: "Duel \(duelCount): could not read opponent score or no computed score, used Too tough"
                )
                try await pause(0.6)
                continue
            }

            let chooseNew = computedScore > opponentScore
            let tapRightSide = chooseNew ? !duel.opponentOnRight : duel.opponentOnRight
            let tapPoint = CGPoint(x: tapRightSide ? 0.72 : 0.28, y: duel.opponentLineY - 0.03)
            try await clickDetectedTarget(tapPoint)
            emit(
                type: "duel",
                step: "finish_in_beli",
                message: "Duel \(duelCount): opponent \(opponentScore), computed \(computedScore), chose \(chooseNew ? "new restaurant" : "opponent")"
            )
            try await pause(0.6)
        }

        if duelCount >= 60 {
            throw AutomationFailure.message("Too many comparison rounds -- please finish ranking manually.")
        }
    }

    private func startingRating() async throws {
        start("start_rating")
        // The restaurant page loads a map and network data before this button
        // renders -- a single capture right after navigating can land mid-load
        // and see no teal ring at all, not because the detector is wrong but
        // because the button genuinely isn't drawn yet. Poll instead of
        // gambling on one fixed settle pause being long enough.
        var plusPoint: CGPoint?
        var lastImage: CGImage?
        let deadline = Date().addingTimeInterval(10)
        while plusPoint == nil && Date() < deadline {
            let image = try await capture.image()
            lastImage = image
            plusPoint = Self.findTealCircle(in: image)
            if plusPoint == nil { try await pause(0.3) }
        }
        guard let plusPoint else {
            if let lastImage { saveTealDebugImage(lastImage) }
            throw AutomationFailure.message("The teal rating button could not be found.")
        }
        // Tap once and check the rating sheet's own header, tapping again only if it
        // didn't open. This used to be a blind double-tap (tap, wait, tap at the
        // same spot), a workaround from when first taps were swallowed by a window
        // that wasn't active yet. Now that the phone is raised before each click,
        // the first tap lands -- and a second one then hits the sheet it just
        // opened, or the page while the sheet is still sliding in.
        var sheetOpened = false
        for attempt in 1...3 {
            try click(plusPoint)
            try await pause(0.4)
            if try await findText("how was it", timeout: 3) != nil {
                sheetOpened = true
                break
            }
            // Keep what the tap did, so "nothing opened" can be told apart from
            // "something else opened" (a menu, a prompt) without guessing.
            if let image = try? await capture.image() {
                saveDebugImage(image, named: "rating-tap-\(attempt).png")
                let seen = ((try? recognizeText(in: image)) ?? [])
                    .filter { $0.text.count > 2 }
                    .prefix(40)
                    .map { "\"\($0.text)\"@\(String(format: "%.2f", $0.center.y))" }
                    .joined(separator: ", ")
                emit(
                    type: "diagnostic",
                    step: "start_rating",
                    message: "rating sheet not open after tap \(attempt) at (\(String(format: "%.3f", plusPoint.x)), \(String(format: "%.3f", plusPoint.y))); screen text: \(seen)"
                )
            }
        }
        guard sheetOpened else {
            throw AutomationFailure.message(
                "The rating sheet did not open after clicking where the + button is. "
                    + "Check that the pointer actually reached the button, then retry."
            )
        }
        finish("start_rating")
    }

    // Saved only when findTealCircle fails to find a match on a live run, so a real
    // failure case (as opposed to a hand-picked test screenshot) can be inspected later.
    private func saveTealDebugImage(_ image: CGImage) {
        guard let debugDirectory = configuration.debugDirectory else { return }
        let url = URL(fileURLWithPath: debugDirectory).appendingPathComponent("teal-search-failed.png")
        try? Foundation.FileManager().removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private func choosingCategory() async throws {
        // Skipped: Beli already defaults to the right category, and
        // changing it isn't needed, so this no longer touches the UI at
        // all -- avoids the category picker's flaky OCR/timing entirely.
        start("choose_category")
        finish("choose_category")
    }

    private func addingNotes() async throws {
        start("add_notes")
        if !configuration.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let addNotes = try await waitForText("add notes", timeout: 20)
            // Tap, then wait for the sheet's own placeholder; if it never appears the
            // tap didn't open it, so tap again rather than type into the page behind.
            var openedArea: OCRItem?
            for _ in 0..<3 {
                try await clickDetectedTarget(addNotes.center)
                if let found = try await findText("tips, tricks", timeout: 5) {
                    openedArea = found
                    break
                }
            }
            guard let textArea = openedArea else {
                throw AutomationFailure.message("Could not open the notes editor.")
            }
            // A single tap silently failed to focus small targets elsewhere
            // in this flow (confirmed live) -- use the same double-tap
            // workaround already established for the teal button.
            // Verify the placeholder actually disappeared (i.e. the field
            // received the text) before tapping Done -- a focus click that
            // silently failed would otherwise leave the note empty. The
            // placeholder only shows while the field is empty, so when it is
            // still there nothing was typed and trying again can't double up.
            var noteTyped = false
            for attempt in 1...3 {
                // Vary where the field is tapped. The placeholder is a label sitting on
                // top of the text view, and a retry that taps the very same spot fails
                // the very same way (seen live: three identical attempts, three
                // misses). The blank area below the label belongs to the text view.
                let tapPoint: CGPoint
                switch attempt {
                case 1: tapPoint = textArea.center
                case 2: tapPoint = CGPoint(x: 0.5, y: min(0.9, textArea.center.y + 0.12))
                default: tapPoint = CGPoint(x: 0.3, y: min(0.9, textArea.center.y + 0.28))
                }
                try await clickThroughScreenshot(tapPoint)
                try typeText(configuration.description)
                if try await findText("tips, tricks", timeout: 2) == nil {
                    noteTyped = true
                    break
                }
                // Keep what the screen showed, so "typed into the wrong place", "the
                // sheet closed" and "the keyboard never came up" can be told apart.
                var seen = ""
                if let image = try? await capture.image() {
                    saveDebugImage(image, named: "notes-attempt-\(attempt).png")
                    seen = ((try? recognizeText(in: image)) ?? [])
                        .filter { $0.text.count > 1 }
                        .prefix(30)
                        .map { "\"\($0.text)\"@\(String(format: "%.2f", $0.center.y))" }
                        .joined(separator: ", ")
                }
                emit(
                    type: "diagnostic",
                    step: "add_notes",
                    message: "notes: field still empty after typing (attempt \(attempt) of 3); screen text: \(seen)"
                )
            }
            guard noteTyped else {
                throw AutomationFailure.message("The notes field did not receive the typed text.")
            }
            let done = try await waitForText("done", timeout: 15) { $0.center.y < 0.18 }
            // A fixed double-tap still wasn't reliably dismissing this sheet
            // (confirmed live) -- retry tapping Done until the sheet is
            // actually confirmed closed, rather than guessing a tap count.
            var closed = false
            for _ in 0..<5 {
                try await clickDetectedTarget(done.center)
                try await pause(0.4)
                if try await findText("your notes", timeout: 2, predicate: { $0.center.y < 0.18 }) == nil {
                    closed = true
                    break
                }
            }
            guard closed else {
                throw AutomationFailure.message("Could not close the notes editor.")
            }
        }
        finish("add_notes")
    }

    private func settingVisitDate() async throws {
        start("set_visit_date")
        guard let targetDate = Self.dateFormatter.date(from: configuration.visitDate) else {
            throw AutomationFailure.message("The visit date is invalid.")
        }

        let addDate = try await waitForText("add visit date", timeout: 20)
        try await clickDetectedTarget(addDate.center)

        let calendar = Calendar(identifier: .gregorian)
        let targetComponents = calendar.dateComponents([.year, .month], from: targetDate)
        guard let targetYear = targetComponents.year, let targetMonth = targetComponents.month else {
            throw AutomationFailure.message("The visit date is invalid.")
        }

        var visibleMonth = try await readVisibleMonth(timeout: 20)

        if visibleMonth.year != targetYear || visibleMonth.month != targetMonth {
            try await selectMonthYear(targetMonth: targetMonth, targetYear: targetYear, visibleMonth: visibleMonth)
            visibleMonth = try await readVisibleMonth(timeout: 20)
            emit(
                type: "diagnostic",
                step: "set_visit_date",
                message: "month confirmation: read \(visibleMonth.month)/\(visibleMonth.year), "
                    + "target \(targetMonth)/\(targetYear)"
            )
            guard visibleMonth.year == targetYear, visibleMonth.month == targetMonth else {
                throw AutomationFailure.message("The visit month could not be set.")
            }
        }

        let day = calendar.component(.day, from: targetDate)
        let dayItem = try await waitForDay(day, date: targetDate)
        try await clickDetectedTarget(dayItem.center)
        let done = try await waitForText("done", timeout: 15) { $0.center.y < 0.18 }
        try await clickDetectedTarget(done.center)
        finish("set_visit_date")
    }

    private func findingPhotos() async throws {
        start("add_photos")
        let addPhotos = try await waitForText("add photos", timeout: 20)
        try await clickDetectedTarget(addPhotos.center)
        try await pause(0.6)

        // Clear leftovers BEFORE the date search, not just after it. The system
        // picker keeps its selection across re-presenting in the same session,
        // so in a queue it reopens with the previous restaurant's photos still
        // checked -- and those are from a different visit date, so once the
        // search below jumps to this visit's day they're scrolled out of view
        // and the pass inside selectPhotos() (which only ever looks at the
        // visible page) can't see them. They then ride along into Beli's Photo
        // Upload list as extra rows, which both attaches the wrong photo and
        // leaves more rows than this run has descriptions for, so filling them
        // fails partway and nothing gets saved. Right here the picker is still
        // showing where the previous run left it, which is where those stale
        // selections actually are.
        try await clearStaleSelections()

        // No "Beli" album navigation needed -- selectPhotos() already finds
        // target photos by visual pixel-signature matching while scrolling
        // whatever grid it's shown. Instead of scrolling blind through
        // Recents, search the visit date first (confirmed live: the
        // system photo picker's search bar accepts a natural-language date
        // like "August 9, 2026" and surfaces a date suggestion chip that
        // boosts that day's photos to the top of the results) so matching
        // has to look through far fewer candidates.
        if let dateQuery = Self.dateFormatter.date(from: configuration.visitDate).map(Self.searchDateFormatter.string(from:)) {
            do {
                var tappedSuggestion = false
                for attempt in 1...3 {
                    // The search icon is a TOGGLE (tap again closes it) -- unlike
                    // the idempotent buttons elsewhere, a blind double-tap here
                    // re-closes it (confirmed live). Single-tap, then verify it
                    // actually opened before proceeding, retrying only if it
                    // didn't. Seeing the empty field's placeholder also proves the
                    // date is typed into a clean field, not on top of leftover text.
                    var searchOpened = false
                    for _ in 0..<3 {
                        try await clickDetectedTarget(CGPoint(x: 0.86, y: 0.94))
                        try await pause(0.4)
                        if try await findText("search your library", timeout: 2) != nil {
                            searchOpened = true
                            break
                        }
                    }
                    guard searchOpened else {
                        throw AutomationFailure.message("Could not open photo search.")
                    }
                    let searchField = try await waitForText("search your library", timeout: 5)
                    try await clickDetectedTarget(searchField.center)
                    try typeText(dateQuery)

                    // The date suggestion chip can take a moment to populate
                    // after typing finishes (Photos indexes it locally), so
                    // this waits for it rather than doing one quick look and
                    // silently moving on -- without tapping it, the search
                    // never actually boosts that day's photos.
                    if let suggestion = try await waitForDateChip(dateQuery, timeout: 8) {
                        try await clickDetectedTarget(suggestion.center)
                        try await pause(0.4)
                        emit(
                            type: "diagnostic",
                            step: "add_photos",
                            message: "date search: tapped suggestion \"\(suggestion.text)\""
                        )
                        tappedSuggestion = true
                        break
                    }

                    emit(
                        type: "diagnostic",
                        step: "add_photos",
                        message: "date search: no suggestion chip appeared for \"\(dateQuery)\" (attempt \(attempt) of 3)"
                    )
                    if attempt == 3 {
                        await recordDateSearchMiss()
                        break
                    }
                    // Close this search so the retry starts from a fresh one.
                    try await clickDetectedTarget(CGPoint(x: 0.86, y: 0.94))
                    try await pause(0.6)
                }
                if !tappedSuggestion {
                    emit(
                        type: "diagnostic",
                        step: "add_photos",
                        message: "date search: continuing without the date filter"
                    )
                }
            } catch {
                emit(
                    type: "diagnostic",
                    step: "add_photos",
                    message: "Date search unavailable, falling back to scrolling: \(error.localizedDescription)"
                )
            }
        }

        let targets = configuration.photoPaths.compactMap(Self.loadImage)
        guard targets.count == configuration.photoPaths.count else {
            throw AutomationFailure.message("One of the meal photos could not be read.")
        }
        try saveSelectedPhotoOrder([])
        _ = try await selectPhotos(targets)

        // A blind click at a hardcoded absolute fraction landed on iPhone
        // Mirroring's own "Home" control instead of the picker's checkmark
        // (confirmed live: sent the phone to its home screen mid-run) --
        // anchoring to the "Photos" tab, which sits on the exact same row
        // as the checkmark in every capture tonight, keeps the click
        // targeted at the picker's own chrome even if its exact position
        // shifts.
        let photosTab = try await waitForText("photos", timeout: 10) { $0.center.y < 0.25 }
        emit(
            type: "diagnostic",
            step: "add_photos",
            message: "confirming photo selection: \"Photos\" tab at \(photosTab.center), tapping checkmark"
        )
        try click(CGPoint(x: 0.9, y: photosTab.center.y))
        try await dismissPhotoAccessPromptIfPresent()
        _ = try await waitForText("photo upload", timeout: 20) { $0.center.y < 0.2 }
        finish("add_photos")
    }

    // Only appears for users whose Beli photo-access permission is set to
    // "Limited" rather than full access -- iOS asks whether to keep the
    // just-made selection or pick more. A no-op when full access is granted
    // and this prompt never shows.
    private func dismissPhotoAccessPromptIfPresent() async throws {
        if let keepSelection = try? await findText("keep current selection", timeout: 3) {
            try await clickDetectedTarget(keepSelection.center)
        }
    }

    private func continueFromPhotoPicker() async throws {
        let existingUpload = try await findText("photo upload", timeout: 2) {
            $0.center.y < 0.2
        }
        if existingUpload == nil {
            let photosTab = try await waitForText("photos", timeout: 10) { $0.center.y < 0.25 }
            try click(CGPoint(x: 0.9, y: photosTab.center.y))
            try await dismissPhotoAccessPromptIfPresent()
            _ = try await waitForText("photo upload", timeout: 20) { $0.center.y < 0.2 }
        }
    }

    private func addingPhotoDescriptions() async throws {
        start("add_photo_descriptions")
        _ = try await waitForText("photo upload", timeout: 20) { $0.center.y < 0.2 }
        let descriptions = loadSelectedPhotoOrder().map { index in
            guard let photoDescriptions = configuration.photoDescriptions,
                  photoDescriptions.indices.contains(index) else {
                return "Menu"
            }
            let value = photoDescriptions[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "Menu" : value
        }
        // Each row is matched back to its photo by thumbnail, so the dish names
        // land on the right pictures whatever order Beli lists them in.
        let targetImages = configuration.photoPaths.compactMap(Self.loadImage)
        let targetPrints = targetImages.count == configuration.photoPaths.count
            ? try targetImages.map { try Self.featurePrint(Self.centerSquare($0)) }
            : []
        let targetDescriptions = configuration.photoPaths.indices.map { index -> String in
            guard let photoDescriptions = configuration.photoDescriptions,
                  photoDescriptions.indices.contains(index) else {
                return "Menu"
            }
            let value = photoDescriptions[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? "Menu" : value
        }
        if targetPrints.isEmpty {
            try await addPhotoDescriptionsInOrder(descriptions)
        } else {
            try await reconcilePhotoDescriptions(
                targetPrints: targetPrints,
                targetDescriptions: targetDescriptions,
                inOrder: descriptions
            )
        }
        let save = try await waitForText("save", timeout: 35) { $0.center.y < 0.18 }
        // Blindly double-tapping here (as clickThroughScreenshot does) risks the
        // second tap landing on whatever the review screen shows at this same
        // top-right spot -- confirmed live, it hit the "X" close button there
        // instead of Save having simply not registered. Retry and check each time
        // whether the review screen ("How was it?") actually appeared, same
        // pattern used for opening each photo's description editor.
        var saved = false
        for _ in 0..<5 {
            try await clickDetectedTarget(save.center)
            if try await findText("how was it", timeout: 2) != nil {
                saved = true
                break
            }
        }
        guard saved else {
            throw AutomationFailure.message("Could not confirm the photo descriptions were saved.")
        }
        finish("add_photo_descriptions")
    }

    // The original fill: the next empty row gets the next description, in the order the
    // photos were picked. Only used when the list can't be read row by row.
    private func addPhotoDescriptionsInOrder(_ descriptions: [String]) async throws {
        _ = try await waitForText("photo upload", timeout: 20) { $0.center.y < 0.2 }
        guard !descriptions.isEmpty else {
            throw AutomationFailure.message("No added photos were found to describe.")
        }

        // Drive this off what's actually still unfilled on screen rather than a
        // precomputed photo count -- that count (from loadSelectedPhotoOrder) can
        // drift from the real number of rows Beli shows. Hard-cap total attempts at
        // descriptions.count + 1 as a backup guardrail: even if something upstream
        // keeps reporting an unfilled field that never actually clears, this loop
        // cannot run away scrolling indefinitely looking for one more photo.
        var filledCount = 0
        let maxAttempts = descriptions.count + 1
        while filledCount < maxAttempts {
            guard let prompt = try await findUnfilledDescriptionPrompt(maxScrolls: maxAttempts) else {
                break
            }
            guard filledCount < descriptions.count else {
                // Almost always an extra photo this run never selected -- a
                // leftover from the picker's previous selection. Say so, since
                // the fix is to remove it rather than to retype anything.
                throw AutomationFailure.message(
                    "Beli is showing \(filledCount + 1) photos but only \(descriptions.count) were added for this restaurant. "
                        + "Remove the extra photo in Beli, then retry this step."
                )
            }
            let description = descriptions[filledCount]

            // A single tap silently failed to focus this field live -- but blindly
            // double-tapping risks the second tap landing on the editor screen the
            // first tap just opened, since a pushed detail screen doesn't share the
            // list row's layout. Retry the tap and check each time whether the
            // editor actually opened, same pattern as the "Done" retry below for
            // the notes sheet.
            var editorOpened = false
            for _ in 0..<5 {
                try await clickDetectedTarget(prompt.center)
                if try await findText("description", timeout: 2, predicate: { $0.center.y < 0.2 }) != nil {
                    editorOpened = true
                    break
                }
            }
            guard editorOpened else {
                throw AutomationFailure.message("Could not open the description editor for photo \(filledCount + 1).")
            }

            try await pause(0.4)
            try typeText(description)

            // Verify the text actually landed before moving on -- a focus click
            // that silently failed would otherwise leave this photo's description
            // empty while the loop happily continues to the next one.
            if try await findText(description, timeout: 2) == nil {
                throw AutomationFailure.message("Photo description \(filledCount + 1) did not receive the typed text.")
            }

            // Whether this is the last photo is exactly what we're trying to avoid
            // predicting from a possibly-stale count -- accept whichever of
            // "Next"/"Done" the editor actually shows.
            let button = try await waitForNextOrDoneButton()
            try await clickDetectedTarget(button.center)
            filledCount += 1
            emit(
                type: "diagnostic",
                step: "add_photo_descriptions",
                message: "added photo description \(filledCount)"
            )
        }

        guard filledCount > 0 else {
            throw AutomationFailure.message("No added photos were found to describe.")
        }
        if filledCount != descriptions.count {
            emit(
                type: "diagnostic",
                step: "add_photo_descriptions",
                message: "filled \(filledCount) photo description(s), expected \(descriptions.count)"
            )
        }

        _ = try await waitForText("photo upload", timeout: 20) {
            $0.center.y < 0.2
        }
    }

    // Same feature-print distance and cutoff as the picker; measured on a
    // real Photo Upload screen: the right photo 0.758, an unrelated one 1.328.
    // `top` is the thumbnail's top edge as a fraction of the screen height.
    private func matchThumbnail(
        top: CGFloat,
        in image: CGImage,
        targetPrints: [VNFeaturePrintObservation],
        candidates: Set<Int>
    ) throws -> (index: Int, distance: Float)? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let rect = CGRect(
            x: 0.067 * width,
            y: top * height,
            width: 0.221 * width,
            height: 0.134 * height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard rect.width > 20, rect.height > 20, let crop = image.cropping(to: rect) else { return nil }

        let rowPrint = try Self.featurePrint(Self.centerSquare(crop))
        var best: (index: Int, distance: Float)?
        for index in candidates {
            let distance = try Self.featurePrintDistance(targetPrints[index], rowPrint)
            if distance < Self.photoMatchCutoff, best == nil || distance < best!.distance {
                best = (index, distance)
            }
        }
        return best
    }

    // The list animates -- it slides in as the editor closes and bounces when
    // scrolled -- so a prompt read mid-motion is somewhere else by the time it is
    // tapped, and the tap opens a different row. Wait for two identical frames.
    private func waitForSettledFrame(timeout: TimeInterval = 2.5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: [Float]?
        var steady = 0
        while Date() < deadline {
            let feature = imageFeature(try await capture.image())
            if let previous, featureDistance(previous, feature) < 0.006 {
                steady += 1
                if steady >= 2 { return }
            } else {
                steady = 0
            }
            previous = feature
            try await pause(0.22)
        }
    }

    private func editDistance(_ first: String, _ second: String) -> Int {
        let a = Array(first), b = Array(second)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }

    // Whether the text OCR read on a row is the description meant for it. An
    // empty read means the text was too small to trust, not that it is wrong.
    private func descriptionAgrees(seen: String, expected: String) -> Bool {
        let seenText = normalize(seen)
        let expectedText = normalize(expected)
        if seenText.contains("what s this") { return false }
        if seenText.isEmpty || expectedText.isEmpty { return true }
        if seenText.contains(expectedText) || expectedText.contains(seenText) { return true }
        return editDistance(seenText, expectedText) <= max(2, expectedText.count / 3)
    }

    // One row of the Photo Upload list as it is on screen right now.
    private struct PhotoListRow {
        let target: Int?        // which of the restaurant's photos the thumbnail shows
        let seen: String        // the text OCR read on the row
        let prompt: OCRItem?    // the "What's this?" placeholder, present only while the row is empty
    }

    // Reads every row that is fully on screen. Rows are anchored on their "Mark as a
    // favorite dish" label, which -- unlike the placeholder -- is always there.
    private func readPhotoListRows(
        in image: CGImage,
        targetPrints: [VNFeaturePrintObservation]
    ) throws -> (rows: [PhotoListRow], cutOffAbove: Bool) {
        let items = try recognizeText(in: image)
        let anchors = items
            .filter { normalize($0.text).contains("mark as a favorite") }
            .sorted { $0.center.y < $1.center.y }

        var rows: [PhotoListRow] = []
        var cutOffAbove = false
        for anchor in anchors {
            let top = anchor.center.y - 0.125
            // Skip rows cut off by the header or the bottom edge.
            if top < 0.15 { cutOffAbove = true }
            guard top >= 0.15, top + 0.134 <= 0.97 else { continue }
            let inRow = items
                .filter {
                    $0.x >= 0.30 && $0.center.y >= top - 0.005 && $0.center.y < top + 0.09
                        && !normalize($0.text).contains("mark as a favorite")
                }
                .sorted { $0.center.y < $1.center.y }
            let match = try matchThumbnail(
                top: top,
                in: image,
                targetPrints: targetPrints,
                candidates: Set(targetPrints.indices)
            )
            rows.append(PhotoListRow(
                target: match?.index,
                seen: inRow.map(\.text).joined(separator: " "),
                prompt: inRow.first { normalize($0.text).contains("what s this") }
            ))
        }
        return (rows, cutOffAbove)
    }

    // Opens one row's editor, types its description, and confirms it landed.
    private func fillDescription(at prompt: OCRItem, _ description: String, label: String) async throws {
        // A single tap silently failed to focus this field live -- but blindly
        // double-tapping risks the second tap landing on the editor screen the
        // first tap just opened, since a pushed detail screen doesn't share the
        // list row's layout. Retry the tap and check each time whether the
        // editor actually opened.
        var editorOpened = false
        for _ in 0..<5 {
            try await clickDetectedTarget(prompt.center)
            if try await findText("description", timeout: 2, predicate: { $0.center.y < 0.2 }) != nil {
                editorOpened = true
                break
            }
        }
        guard editorOpened else {
            throw AutomationFailure.message("Could not open the description editor for \(label).")
        }

        try await pause(0.4)
        try typeText(description)

        if try await findText(description, timeout: 2) == nil {
            throw AutomationFailure.message("The description for \(label) did not receive the typed text.")
        }

        // Whether this is the last photo is exactly what we're trying to avoid
        // predicting -- accept whichever of "Next"/"Done" the editor actually shows.
        let button = try await waitForNextOrDoneButton()
        try await clickDetectedTarget(button.center)
    }

    // Fills the list by reading it, not by counting. Each round waits for the list to
    // stop moving, reads every row (which of the restaurant's photos it shows, and
    // what text it carries), types into the first row that is still empty, and
    // ends only when every one of the restaurant's photos shows its own text.
    // Whatever made a description go missing -- a row that moved, a tap that missed,
    // an editor that closed early -- the next read sees an empty row and fixes it,
    // and a bad list can't be saved without being noticed.
    private func reconcilePhotoDescriptions(
        targetPrints: [VNFeaturePrintObservation],
        targetDescriptions: [String],
        inOrder descriptions: [String]
    ) async throws {
        _ = try await waitForText("photo upload", timeout: 20) { $0.center.y < 0.2 }

        var typedCount: [Int: Int] = [:]
        var verified = Set<Int>()
        var unreadableRounds = 0
        var idleScrolls = 0
        let maxRounds = targetPrints.count * 4 + 6

        for _ in 0..<maxRounds {
            try await waitForSettledFrame()
            let image = try await capture.image()
            let (rows, cutOffAbove) = try readPhotoListRows(in: image, targetPrints: targetPrints)

            // Not a list we can read (an editor still open, a screen mid-change).
            if rows.isEmpty {
                unreadableRounds += 1
                if unreadableRounds >= 3 {
                    emit(
                        type: "diagnostic",
                        step: "add_photo_descriptions",
                        message: "photo list not readable row by row; filling rows in selection order instead"
                    )
                    try await addPhotoDescriptionsInOrder(descriptions)
                    return
                }
                try await pause(0.4)
                continue
            }
            unreadableRounds = 0

            // Thumbnails that match none of our photos: either matching doesn't work
            // here at all (use the old fill), or a photo that isn't ours is attached.
            if rows.contains(where: { $0.target == nil }) {
                if rows.allSatisfy({ $0.target == nil }) && verified.isEmpty && typedCount.isEmpty {
                    emit(
                        type: "diagnostic",
                        step: "add_photo_descriptions",
                        message: "no photo row matched this restaurant's photos; filling rows in selection order instead"
                    )
                    try await addPhotoDescriptionsInOrder(descriptions)
                    return
                }
                throw AutomationFailure.message(
                    "A photo in Beli's upload list isn't one of this restaurant's photos, so it was left alone. "
                        + "It is most likely left over from an earlier attempt. Remove it in Beli, "
                        + "or cancel the rating there and start it over, then retry."
                )
            }

            // Rows already carrying text: confirm it is the right text. Wrong text on a
            // row can't be typed over safely (the editor would append to it).
            var wrong: [String] = []
            for row in rows {
                guard let target = row.target, row.prompt == nil else { continue }
                if descriptionAgrees(seen: row.seen, expected: targetDescriptions[target]) {
                    verified.insert(target)
                } else {
                    wrong.append("photo \(target + 1) shows \"\(row.seen)\" but should say \"\(targetDescriptions[target])\"")
                }
            }
            if !wrong.isEmpty {
                throw AutomationFailure.message(
                    "Beli's photo list has the wrong text on a row, so nothing was saved: "
                        + wrong.joined(separator: "; ")
                        + ". Fix those rows in Beli, then retry."
                )
            }

            // The first row still empty gets its own photo's description.
            if let row = rows.first(where: { $0.prompt != nil }),
               let prompt = row.prompt,
               let target = row.target {
                typedCount[target, default: 0] += 1
                if typedCount[target]! > 3 {
                    throw AutomationFailure.message(
                        "Photo \(target + 1)'s description wouldn't stay on its row after three tries. "
                            + "Check that row in Beli, then retry."
                    )
                }
                emit(
                    type: "diagnostic",
                    step: "add_photo_descriptions",
                    message: "row shows photo \(target + 1) and is empty; typing \"\(targetDescriptions[target])\" (try \(typedCount[target]!))"
                )
                try await fillDescription(at: prompt, targetDescriptions[target], label: "photo \(target + 1)")
                idleScrolls = 0
                continue
            }

            if verified.count == targetPrints.count {
                emit(
                    type: "diagnostic",
                    step: "add_photo_descriptions",
                    message: "photo list check: all \(targetPrints.count) photo(s) show their own description"
                )
                return
            }

            // Everything on screen is done but some photos haven't shown up yet:
            // there are more rows -- above if the top one is cut off (the list can
            // sit scrolled a little), otherwise below.
            idleScrolls += 1
            if idleScrolls > 3 { break }
            try scrollPhotoUpload(up: cutOffAbove)
            try await pause(0.4)
        }

        let missing = targetPrints.indices.filter { !verified.contains($0) }.map { String($0 + 1) }.joined(separator: ", ")
        emit(
            type: "diagnostic",
            step: "add_photo_descriptions",
            message: "photo(s) \(missing) of \(targetPrints.count) never showed their description in Beli's upload list"
        )
        throw AutomationFailure.photosNotFound
    }

    private func waitForNextOrDoneButton() async throws -> OCRItem {
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            let items = try recognizeText(in: await capture.image()).filter { $0.center.y < 0.2 }
            if let button = bestTextMatch("done", in: items) ?? bestTextMatch("next", in: items) {
                return button
            }
            try await pause(0.22)
        }
        throw AutomationFailure.message("Could not find a Next/Done button after entering a photo description.")
    }

    // Scans the Photo Upload list (scrolling as needed) for the topmost still-unfilled
    // "What's this?" placeholder. Returns nil once scrolling stops revealing new content
    // or maxScrolls is hit -- capped relative to the actual photo count (rather than a
    // flat 40) since a short list needs at most one scroll per remaining photo, and a
    // fixed high cap turned a "nothing left to find" case into a long, visible scroll-hunt.
    private func findUnfilledDescriptionPrompt(maxScrolls: Int) async throws -> OCRItem? {
        var prompt: OCRItem?
        var previousScreenFeature: [Float]?
        var unchangedScreens = 0
        var scrolls = 0

        while prompt == nil && scrolls < maxScrolls {
            let image = try await capture.image()
            let items = try recognizeText(in: image)
            prompt = items
                .filter { item in
                    let text = normalize(item.text)
                    return text.contains("what s this") &&
                        item.center.y > 0.14 &&
                        item.center.y < 0.88
                }
                .min { $0.center.y < $1.center.y }

            if prompt != nil { break }

            let screenFeature = imageFeature(image)
            if let previousScreenFeature,
               featureDistance(previousScreenFeature, screenFeature) < 0.006 {
                unchangedScreens += 1
            } else {
                unchangedScreens = 0
            }
            if unchangedScreens >= 2 { break }
            previousScreenFeature = screenFeature
            try scrollPhotoUpload()
            try await pause(0.4)
            scrolls += 1
        }

        return prompt
    }

    private func finishingInBeli() async throws {
        start("finish_in_beli")
        let okay = try await waitForText("okay", timeout: 45) { $0.center.y > 0.72 }
        try await clickDetectedTarget(okay.center)

        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            let items = try recognizeText(in: await capture.image(), level: .fast)
            let sharePageIsOpen = items.contains { item in
                normalize(item.text).contains("share this page") &&
                    item.center.y > 0.65
            }
            // Landing back on the restaurant's own page ("Rank again" +
            // a checkmark badge showing the new score) is also a valid
            // completion signal -- confirmed live, "share this page" doesn't
            // always show/get caught.
            let rankAgainIsOpen = items.contains { item in
                normalize(item.text).contains("rank again")
            }
            if sharePageIsOpen || rankAgainIsOpen {
                emit(type: "celebrate", step: nil, message: nil)
                try await pause(2)
                try await returnToFeed()
                finish("finish_in_beli")
                return
            }
            // Duels ("Which do you prefer?") appear here, between tapping
            // "Okay" and the share/rank-again page (confirmed live). A
            // fast-mode miss just gets retried next iteration.
            if normalize(items.map { $0.text }.joined(separator: " ")).contains("which do you prefer") {
                try await resolveAnyPendingDuels()
                continue
            }
            try await pause(0.5)
        }
        throw AutomationFailure.message("Timed out while waiting for Beli's share page.")
    }

    // Both completion screens (share page, or landing back on the restaurant's
    // own page) have a back arrow at this same top-left spot, and popping it
    // repeatedly unwinds whatever got pushed onto the nav stack during rating --
    // rather than switching tabs from wherever we happen to land, which would
    // leave that stack in place for the next restaurant to trip over. Verified
    // by an actual screen change (not a fixed tap count) since there's no
    // reliable way to OCR/detect the arrow icon itself.
    private func returnToFeed() async throws {
        let backArrowPoint = CGPoint(x: 0.085, y: 0.15)
        for _ in 0..<10 {
            let before = imageFeature(try await capture.image())
            try click(backArrowPoint)
            try await pause(0.5)
            let after = imageFeature(try await capture.image())
            if featureDistance(before, after) < 0.01 {
                // Tapping here didn't change anything -- no back arrow left.
                break
            }
        }

        let feed = try await waitForText("feed", timeout: 20) { $0.center.y > 0.8 }
        try await clickDetectedTarget(feed.center)
        _ = try await waitForText("search restaurant", timeout: 20)
    }

    private func skipPhotos() async throws {
        start("add_photos")
        let pickerClosePoint = CGPoint(x: 0.107, y: 0.144)
        try await clickDetectedTarget(pickerClosePoint)
        try await pause(0.5)
        try await clickDetectedTarget(pickerClosePoint)
        try await pause(0.6)
        finish("add_photos")
        start("add_photo_descriptions")
        finish("add_photo_descriptions")
    }

    private func selectPhotos(_ targetImages: [CGImage]) async throws -> [Int] {
        let targetSignatures = try targetImages.map {
            try Self.featurePrint(Self.centerSquare($0))
        }
        var remaining = Set(targetSignatures.indices)
        var previousGridFeature: [Float]?
        var unchangedPages = 0
        var page = 0
        var selectedOrder: [Int] = []
        // Cells already clicked on the page currently shown. A click TOGGLES a
        // photo, so clicking the same cell twice silently un-selects it; the
        // grid doesn't move between clicks, so remembering them until it scrolls
        // is enough.
        var clickedCells = Set<Int>()

        // A photo can already be checked from an earlier attempt (the
        // system picker keeps its selection state across re-presenting in
        // the same session), which would otherwise stay selected alongside
        // whatever this run correctly matches. This runs exactly once,
        // before any of this run's own matching/clicking, and confirms
        // each deselect actually took effect before moving on -- a prior
        // version of this ran on every scroll page (including pages this
        // run had just selected on) and could misjudge a not-yet-settled
        // click as still-checked, toggling it back on and oscillating.
        // Running once, up front, with a confirm-or-stop loop avoids both.
        try await clearStaleSelections()

        while !remaining.isEmpty && page < 10 {
            let image = try await capture.image()
            savePhotoDebugImage(image)
            let cells = Self.gridCells(in: image)
            let cellSignatures = try cells.map { try Self.featurePrint($0.image) }
            var candidates: [(target: Int, cell: Int, distance: Float)] = []

            for targetIndex in remaining {
                for (cellIndex, cellSignature) in cellSignatures.enumerated() where !clickedCells.contains(cellIndex) {
                    let distance = try Self.featurePrintDistance(
                        targetSignatures[targetIndex],
                        cellSignature
                    )
                    candidates.append((targetIndex, cellIndex, distance))
                }
            }
            candidates.sort { $0.distance < $1.distance }
            let bestDistance = candidates.first.map { String(format: "%.3f", $0.distance) } ?? "none"
            let secondBestForBest = candidates.first.flatMap { best in
                candidates.first { $0.target == best.target && $0.cell != best.cell }
            }
            let secondBestDistance = secondBestForBest.map { String(format: "%.3f", $0.distance) } ?? "none"
            let bestCell = candidates.first.map(\.cell).map(String.init) ?? "none"
            emit(
                type: "diagnostic",
                step: "add_photos",
                message: "photo page \(page): \(cells.count) cells, best distance \(bestDistance) (cell \(bestCell)), second-best \(secondBestDistance)"
            )

            // Vision's feature-print distance separates real matches from
            // near-misses far more cleanly than the old diff-hash did
            // (confirmed live: genuine matches ~0.78, unrelated photos
            // 1.16+, though look-alikes from the same meal reach 0.91 -- see
            // photoMatchCutoff), so a plain absolute cutoff is enough -- no need for
            // the old hash's "must beat the runner-up by a margin" check,
            // which actively broke on duplicate/near-duplicate photos (a
            // photo saved twice makes its own best competitor its own
            // near-identical duplicate, so it could never win by a margin).
            if let candidate = candidates.first(where: { $0.distance < Self.photoMatchCutoff }) {
                try await clickDetectedTarget(cells[candidate.cell].point)
                clickedCells.insert(candidate.cell)
                remaining.remove(candidate.target)
                selectedOrder.append(candidate.target)
                emit(
                    type: "diagnostic",
                    step: "add_photos",
                    message: "selected photo \(candidate.target + 1) of \(targetImages.count) at cell \(candidate.cell) (distance \(String(format: "%.3f", candidate.distance)))"
                )
                try saveSelectedPhotoOrder(selectedOrder)
                try await pause(0.22)
                continue
            }

            let gridFeature = imageFeature(image)
            if let previousGridFeature,
               featureDistance(previousGridFeature, gridFeature) < 0.006 {
                unchangedPages += 1
            } else {
                unchangedPages = 0
            }
            if unchangedPages >= 2 { break }
            previousGridFeature = gridFeature
            try scrollDown()
            try await pause(0.45)
            clickedCells.removeAll()
            page += 1
        }

        guard remaining.isEmpty else {
            throw AutomationFailure.photosNotFound
        }
        return selectedOrder
    }

    private var selectedPhotoOrderURL: URL? {
        let directory = configuration.debugDirectory ?? configuration.photoPaths.first.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        }
        return directory.map {
            URL(fileURLWithPath: $0).appendingPathComponent("selected-photo-order.json")
        }
    }

    private func saveSelectedPhotoOrder(_ order: [Int]) throws {
        guard let selectedPhotoOrderURL else { return }
        let data = try JSONEncoder().encode(order)
        try data.write(to: selectedPhotoOrderURL, options: .atomic)
    }

    private func loadSelectedPhotoOrder() -> [Int] {
        guard let selectedPhotoOrderURL,
              let data = try? Data(contentsOf: selectedPhotoOrderURL),
              let order = try? JSONDecoder().decode([Int].self, from: data) else {
            return []
        }
        return order
    }

    private struct GridCell {
        let image: CGImage
        let point: CGPoint
    }

    private static func gridCells(in image: CGImage) -> [GridCell] {
        guard let separators = Self.photoGridSeparators(in: image) else { return [] }
        var cells: [GridCell] = []
        let expectedCellSize = separators.columns[2] - separators.columns[1]

        for row in 0..<(separators.rows.count - 1) {
            for column in 0..<(separators.columns.count - 1) {
                let left = separators.columns[column] + 3
                let right = separators.columns[column + 1] - 3
                let top = separators.rows[row] + 3
                let bottom = separators.rows[row + 1] - 3
                let rowHeight = separators.rows[row + 1] - separators.rows[row]
                guard right > left,
                      bottom > top,
                      rowHeight > expectedCellSize * 4 / 5,
                      rowHeight < expectedCellSize * 6 / 5,
                      let crop = image.cropping(to: CGRect(
                        x: left,
                        y: top,
                        width: right - left,
                        height: bottom - top
                      )) else {
                    continue
                }
                cells.append(GridCell(
                    image: crop,
                    point: CGPoint(
                        x: Double(left + right) / 2 / Double(image.width),
                        y: Double(top + bottom) / 2 / Double(image.height)
                    )
                ))
            }
        }
        return cells
    }

    // The system photo picker badges an already-selected thumbnail with a
    // solid blue checkmark circle in its bottom-right corner (confirmed
    // live, color ~RGB(74,146,239)). Checked against every cell in real
    // grid captures (oyster photos, travel screenshots, app screenshots,
    // job postings, LinkedIn-style cards) with zero false positives at
    // this threshold -- real photo content in that specific corner never
    // came close to the badge's blue ratio.
    // Color alone isn't enough: a photo can legitimately have a saturated
    // blue region (sky, a screen's glow) sitting right in this corner,
    // which a plain color-ratio check can't tell apart from the badge
    // (confirmed live against a blue-sky photo and a laptop-screen photo,
    // both false-positived on color alone). The badge's actual shape is
    // what's distinctive: a white ring around a blue fill, in that specific
    // corner -- requiring both, checked separately, cleared every false
    // positive found while still catching the real badge across two
    // differently-themed picker captures with 27 varied cells tested.
    private static func isCellSelected(_ cellImage: CGImage) -> Bool {
        guard let pixels = rgbaPixels(cellImage) else { return false }
        let width = cellImage.width
        let height = cellImage.height

        func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int)? {
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            let offset = (y * width + x) * 4
            return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
        }
        func isWhite(_ p: (r: Int, g: Int, b: Int)) -> Bool {
            p.r > 165 && p.g > 165 && p.b > 165 && max(p.r, p.g, p.b) - min(p.r, p.g, p.b) < 45
        }
        func isBlueFill(_ p: (r: Int, g: Int, b: Int)) -> Bool {
            p.b > p.r + 60 && p.b > p.g + 30 && p.b > 140
        }

        let cx = Double(width) * 0.905
        let cy = Double(height) * 0.72
        let angleSamples = 24
        let radialSamples = 5
        let ringLow = Double(width) * 0.040
        let ringHigh = Double(width) * 0.065
        let fillRadius = Double(width) * 0.030

        var whiteRingHits = 0
        var blueFillHits = 0
        for i in 0..<angleSamples {
            let angle = 2 * Double.pi * Double(i) / Double(angleSamples)

            var ringHit = false
            for j in 0..<radialSamples {
                let radius = ringLow + (ringHigh - ringLow) * Double(j) / Double(radialSamples - 1)
                let x = Int(cx + cos(angle) * radius)
                let y = Int(cy + sin(angle) * radius)
                if let p = pixel(x, y), isWhite(p) {
                    ringHit = true
                    break
                }
            }
            if ringHit { whiteRingHits += 1 }

            let fillX = Int(cx + cos(angle) * fillRadius)
            let fillY = Int(cy + sin(angle) * fillRadius)
            if let p = pixel(fillX, fillY), isBlueFill(p) {
                blueFillHits += 1
            }
        }

        let whiteRatio = Double(whiteRingHits) / Double(angleSamples)
        let blueRatio = Double(blueFillHits) / Double(angleSamples)
        // ANDing two fixed per-metric thresholds left almost no margin: a
        // real badge, recaptured, scored white=0.54 against a 0.55 cutoff
        // and was missed by a hair (confirmed live) -- a combined score
        // tolerates that capture-to-capture wobble in either metric while
        // the individual floors still block a cell that only nails one
        // metric (a sharp white/black edge scored white=1.00 blue=0.00 in
        // testing; a saturated blue photo scored white=0.46 blue=0.46).
        return whiteRatio + blueRatio > 1.2 && whiteRatio > 0.2 && blueRatio > 0.5
    }

    // Deselects any cell on the currently-visible page that's already
    // checked, confirming each one actually cleared before moving to the
    // next -- run once, before any of selectPhotos()'s own matching, so it
    // can never mistake this run's own selection for stale leftover state.
    private func clearStaleSelections() async throws {
        let image = try await capture.image()
        let cells = Self.gridCells(in: image)
        let staleCells = cells.filter { Self.isCellSelected($0.image) }
        guard !staleCells.isEmpty else { return }

        for cell in staleCells {
            try await clickDetectedTarget(cell.point)
            var cleared = false
            for _ in 0..<4 {
                try await pause(0.35)
                let recheck = try await capture.image()
                let recheckCells = Self.gridCells(in: recheck)
                guard let matching = recheckCells.first(where: {
                    abs($0.point.x - cell.point.x) < 0.02 && abs($0.point.y - cell.point.y) < 0.02
                }) else { continue }
                if !Self.isCellSelected(matching.image) {
                    cleared = true
                    break
                }
            }
            emit(
                type: "diagnostic",
                step: "add_photos",
                message: cleared
                    ? "cleared a stale photo selection before matching"
                    : "found a stale photo selection but could not confirm it cleared, continuing anyway"
            )
        }
    }

    // A date chip has to carry the WHOLE date. findText()'s matcher also accepts
    // any fragment of its target (needle.contains(value)), which is how a stray
    // "20" or "3" from elsewhere on screen got tapped as the chip in a live run.
    // Month abbreviations are accepted too ("Aug 30, 2026"), since that is how
    // the picker may spell it.
    private func isDateChip(_ text: String, for dateQuery: String) -> Bool {
        let wanted = normalize(dateQuery).split(separator: " ").map(String.init)
        guard wanted.count == 3 else { return normalize(text).contains(normalize(dateQuery)) }
        let tokens = Set(normalize(text).split(separator: " ").map(String.init))
        let monthMatches = tokens.contains(wanted[0]) || tokens.contains(String(wanted[0].prefix(3)))
        return monthMatches && tokens.contains(wanted[1]) && tokens.contains(wanted[2])
    }

    private func waitForDateChip(_ dateQuery: String, timeout: TimeInterval) async throws -> OCRItem? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let items = try recognizeText(in: await capture.image())
            // Above the search bar, where the suggestions list; the typed text in
            // the field itself sits lower and must not count.
            let chips = items.filter { $0.center.y < 0.9 && isDateChip($0.text, for: dateQuery) }
            if let chip = chips.max(by: { $0.confidence < $1.confidence }) { return chip }
            try await pause(0.22)
        }
        return nil
    }

    // When the chip never shows, keep what was on screen -- the only way to tell
    // "the chip is spelled differently" from "the text never reached the field".
    private func recordDateSearchMiss() async {
        guard let image = try? await capture.image() else { return }
        saveDebugImage(image, named: "date-search-failed.png")
        let seen = ((try? recognizeText(in: image)) ?? [])
            .filter { $0.center.y > 0.4 }
            .map { "\"\($0.text)\"@\(String(format: "%.2f", $0.center.y))" }
            .joined(separator: ", ")
        emit(
            type: "diagnostic",
            step: "add_photos",
            message: "date search: screen text when the chip never appeared: \(seen)"
        )
    }

    private func saveDebugImage(_ image: CGImage, named name: String) {
        guard let debugDirectory = configuration.debugDirectory else { return }
        let url = URL(fileURLWithPath: debugDirectory).appendingPathComponent(name)
        try? Foundation.FileManager().removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private func savePhotoDebugImage(_ image: CGImage) {
        let debugDirectory = configuration.debugDirectory ?? configuration.photoPaths.first.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        }
        guard let debugDirectory else { return }
        let url = URL(fileURLWithPath: debugDirectory).appendingPathComponent("photo-latest.png")
        try? Foundation.FileManager().removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    private struct GridSeparators {
        let columns: [Int]
        let rows: [Int]
    }

    // The system photo picker lays thumbnails out edge-to-edge in a fixed
    // 3-column grid with no visible border/gap between cells (confirmed
    // live) -- there is no dark separator line to hunt for, so this
    // computes cell boundaries directly from a fixed column count and
    // square cell size, only detecting where the grid *starts* vertically
    // (skipping past any permission-banner/header UI above it) by finding
    // the first row with enough color variance to be real photo content
    // rather than mostly-white banner/text background.
    private static func photoGridSeparators(in image: CGImage) -> GridSeparators? {
        guard let pixels = Self.rgbaPixels(image) else { return nil }
        let width = image.width
        let height = image.height
        let columnCount = 3
        let cellSize = width / columnCount

        func luminance(x: Int, y: Int) -> Double {
            let offset = (y * width + x) * 4
            let red = Double(pixels[offset])
            let green = Double(pixels[offset + 1])
            let blue = Double(pixels[offset + 2])
            return (red * 0.2126 + green * 0.7152 + blue * 0.0722) / 255
        }

        // Excludes the outer edges of the capture -- the iPhone Mirroring
        // window's dark bezel sits just past the real screen content there,
        // and sampling all the way to x=0/width picks up that bezel as a
        // huge, content-independent "variance" spike that swamps whatever
        // is actually on screen (confirmed live).
        let xMargin = Int(Double(width) * 0.07)

        func rowVariance(_ y: Int) -> Double {
            var minLuminance = 1.0
            var maxLuminance = 0.0
            for x in stride(from: xMargin, to: width - xMargin, by: 4) {
                let value = luminance(x: x, y: y)
                minLuminance = min(minLuminance, value)
                maxLuminance = max(maxLuminance, value)
            }
            return maxLuminance - minLuminance
        }

        // The photo picker's header varies in height: with the "Private
        // Access to Photos" banner showing, real photo content starts much
        // further down than it does once that banner is dismissed
        // (confirmed live) -- a fixed search-start fraction only works for
        // one of those two states. Instead this starts the search early
        // (past the status bar) and requires the high-variance region to
        // *sustain* for close to a full cell height before accepting it as
        // the grid top, which is what actually distinguishes a real photo
        // row from the "Photos/Collections" tab text or the banner's own
        // icon+text (both brief, separated from real content by gaps).
        let searchStart = Int(Double(height) * 0.08)
        let searchEnd = Int(Double(height) * 0.7)
        let sustainSpan = Int(Double(cellSize) * 0.6)
        var gridTop: Int?
        var y = searchStart
        while y < searchEnd {
            if rowVariance(y) > 0.35 {
                var sustained = true
                var checkY = y
                let sustainEnd = y + sustainSpan
                while checkY < sustainEnd {
                    if rowVariance(checkY) <= 0.15 {
                        sustained = false
                        break
                    }
                    checkY += 8
                }
                if sustained {
                    gridTop = y
                    break
                }
            }
            y += 4
        }
        guard let gridTop else { return nil }

        var rows: [Int] = [gridTop]
        var nextRow = gridTop + cellSize
        while nextRow < height {
            rows.append(nextRow)
            nextRow += cellSize
        }
        guard rows.count >= 2 else { return nil }

        var columns: [Int] = []
        for index in 0...columnCount {
            columns.append(min(width - 1, index * cellSize))
        }

        return GridSeparators(columns: columns, rows: rows)
    }

    // Waits for the day-grid header ("<Month> <Year>") and parses it, used
    // both to read the currently-displayed month and to locate the day
    // grid below it.
    private func monthYear(from text: String) -> (year: Int, month: Int)? {
        let words = text
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        guard let monthWord = words.first,
              let month = Self.months.firstIndex(where: {
                  $0.caseInsensitiveCompare(String(monthWord)) == .orderedSame
              }),
              // Must check for digits, not just length 4 -- "July" and
              // "June" are themselves 4 characters, so a length-only check
              // matched the month name itself before ever reaching the
              // actual year, silently failing to parse those two months.
              let yearWord = words.first(where: { $0.count == 4 && $0.allSatisfy(\.isNumber) }),
              let year = Int(yearWord) else { return nil }
        return (year, month + 1)
    }

    private func waitForDay(_ day: Int, date: Date) async throws -> OCRItem {
        let calendar = Calendar(identifier: .gregorian)
        let weekday = calendar.component(.weekday, from: date) - 1
        let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth) - 1
        let row = (firstWeekday + day - 1) / 7

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let items = try recognizeText(in: await capture.image())
            // Re-locate the month header on every poll instead of trusting
            // a position captured before this call -- the day grid can
            // still be settling into its final layout right after
            // collapsing the month/year picker, so a stale header y would
            // keep the day-number filter band wrong for the whole 15s wait.
            guard let monthHeaderY = items.first(where: {
                $0.center.y > 0.12 && $0.center.y < 0.34 && monthYear(from: $0.text) != nil
            })?.center.y else {
                try await pause(0.22)
                continue
            }

            let expected = CGPoint(
                x: 0.119 + Double(weekday) * 0.127,
                y: monthHeaderY + 0.086 + Double(row) * 0.057
            )
            let candidates = items.filter {
                normalize($0.text) == String(day) &&
                    $0.center.y > monthHeaderY + 0.035 && $0.center.y < 0.72
            }
            emit(
                type: "diagnostic",
                step: "set_visit_date",
                message: "day search: header y=\(String(format: "%.3f", monthHeaderY)), "
                    + "\(candidates.count) candidate(s) for day \(day), "
                    + "expected \(String(format: "(%.3f, %.3f)", expected.x, expected.y))"
            )
            if let closest = candidates.min(by: {
                distance($0.center, expected) < distance($1.center, expected)
            }) {
                return closest
            }
            try await pause(0.22)
        }
        throw AutomationFailure.message("The visit day could not be found in Beli's calendar.")
    }

    private func readVisibleMonth(
        timeout: TimeInterval
    ) async throws -> (year: Int, month: Int, x: Double, y: Double) {
        let deadline = Date().addingTimeInterval(timeout)
        var lastDiagnostic = Date.distantPast
        while Date() < deadline {
            let items = try recognizeText(in: await capture.image())
            for item in items where item.center.y > 0.12 && item.center.y < 0.34 {
                guard let (year, month) = monthYear(from: item.text) else { continue }
                // The "Add visit date" sheet can still be sliding into
                // place when this first finds readable text -- a header
                // caught mid-animation reports a transient y that isn't
                // where it actually settles (confirmed live: opened the
                // month/year wheel at y=0.33 instead of the correct 0.24,
                // which then made every subsequent nudge target the wrong
                // row entirely). Re-checking after a beat confirms the
                // position has actually stopped moving before trusting it.
                // Trimmed lighter than the bare filler pauses elsewhere: a
                // wrong reading here doesn't silently stick -- settingVisitDate
                // independently re-reads and throws if the final month/year
                // don't match, so this only risks more retries, not bad data.
                try await pause(0.22)
                let settledItems = try recognizeText(in: await capture.image())
                guard let settled = settledItems.first(where: {
                    $0.center.y > 0.12 && $0.center.y < 0.34 && monthYear(from: $0.text) != nil
                }), abs(settled.center.y - item.center.y) < 0.01 else {
                    continue
                }
                return (year, month, settled.center.x, settled.center.y)
            }
            // If this keeps timing out, this shows what OCR actually saw
            // near the top of the screen instead of leaving it a mystery.
            if Date().timeIntervalSince(lastDiagnostic) > 3 {
                lastDiagnostic = Date()
                let nearby = items
                    .filter { $0.center.y > 0.05 && $0.center.y < 0.4 }
                    .map { "\"\($0.text)\"@\(String(format: "%.2f", $0.center.y))" }
                    .joined(separator: ", ")
                emit(
                    type: "diagnostic",
                    step: "set_visit_date",
                    message: "month header not found; text near top: "
                        + (nearby.isEmpty ? "(none)" : nearby)
                )
            }
            try await pause(0.22)
        }
        throw AutomationFailure.message("Beli's visible calendar month could not be read.")
    }

    private struct WheelSelection {
        let text: String
        let point: CGPoint
        let year: Int
        let month: Int?
    }

    // The vertical offset from the "<Month> <Year> v" toggle down to the
    // wheel picker's highlighted/selected row, and the spacing between
    // rows, both estimated from a live screenshot of that picker. Kept
    // generous on either side since this is an estimate, not a measurement
    // of the running device.
    private static let wheelSelectedRowOffset = 0.186
    private static let wheelRowHeight = 0.037

    private func readWheelSelection(headerY: Double, knownYear: Int) async throws -> WheelSelection? {
        let items = try recognizeText(in: await capture.image())
        let expectedY = headerY + Self.wheelSelectedRowOffset
        let bandTop = expectedY - Self.wheelRowHeight * 2.5
        let bandBottom = expectedY + Self.wheelRowHeight * 2.5

        let candidates: [(item: OCRItem, month: Int?, year: Int?)] = items.compactMap { item in
            guard item.center.y > bandTop, item.center.y < bandBottom else { return nil }
            let text = item.text.trimmingCharacters(in: .whitespaces)
            if text.count == 4, let year = Int(text) {
                return (item, nil, year)
            }
            let words = text.split(whereSeparator: { $0.isWhitespace })
            guard let first = words.first,
                  let monthIndex = Self.months.firstIndex(where: {
                      $0.caseInsensitiveCompare(String(first)) == .orderedSame
                  }) else { return nil }
            if words.count > 1, let year = Int(words[1]) {
                return (item, monthIndex + 1, year)
            }
            return (item, monthIndex + 1, nil)
        }

        guard let closest = candidates.min(by: {
            abs($0.item.center.y - expectedY) < abs($1.item.center.y - expectedY)
        }) else { return nil }

        return WheelSelection(
            text: closest.item.text,
            point: closest.item.center,
            year: closest.year ?? knownYear,
            month: closest.month
        )
    }

    // Scrolls the "<Month> <Year> v" wheel picker to the target month/year.
    // The picker isn't a single chronological axis: scrolling up steps
    // through recent months of whatever year is currently selected, while
    // scrolling down jumps to whole-year shortcuts further back (confirmed
    // live) -- so which way to nudge depends on whether the year still
    // needs to change, not on how far away the target date is.
    private func selectMonthYear(
        targetMonth: Int,
        targetYear: Int,
        visibleMonth: (year: Int, month: Int, x: Double, y: Double)
    ) async throws {
        // Diagnostic only -- logs exactly what this click targets without
        // changing any click behavior, so if the wheel fails to open again
        // there's a concrete coordinate/frame to check instead of a guess.
        let openPoint = CGPoint(x: visibleMonth.x, y: visibleMonth.y)
        let resolvedOpenPoint = globalPoint(openPoint)
        emit(
            type: "diagnostic",
            step: "set_visit_date",
            message: "opening month/year picker: normalized \(openPoint), "
                + "screen \(resolvedOpenPoint), window frame \(capture.window.frame)"
        )
        try await clickDetectedTarget(openPoint)

        let headerY = visibleMonth.y
        var knownYear = visibleMonth.year
        var attempts = 0
        var lastNilDiagnostic = Date.distantPast

        while true {
            guard attempts < 80 else {
                throw AutomationFailure.message("The visit month/year picker did not converge.")
            }
            attempts += 1

            guard let selection = try await readWheelSelection(headerY: headerY, knownYear: knownYear) else {
                if Date().timeIntervalSince(lastNilDiagnostic) > 3 {
                    lastNilDiagnostic = Date()
                    emit(
                        type: "diagnostic",
                        step: "set_visit_date",
                        message: "visit date picker: no row detected near the selection band"
                    )
                }
                try await pause(0.22)
                continue
            }
            knownYear = selection.year

            if selection.month == targetMonth, selection.year == targetYear {
                // The wheel has scroll/snap momentum -- a capture taken
                // right after a nudge can catch the target row sliding
                // transiently through the selection band before the wheel
                // has actually settled there (confirmed live: closed on a
                // match that the collapsed grid then showed as unset,
                // because the wheel had drifted back off it by the time
                // the close tap landed). Re-checking after settling
                // catches that instead of trusting a single frame. Trimmed
                // lighter than bare filler pauses since a miss here just
                // retries (settingVisitDate's final check catches a wrong
                // date too), not silent bad data.
                try await pause(0.35)
                guard let settled = try await readWheelSelection(headerY: headerY, knownYear: knownYear),
                      settled.month == targetMonth, settled.year == targetYear else {
                    emit(
                        type: "diagnostic",
                        step: "set_visit_date",
                        message: "visit date picker: \"\(selection.text)\" match didn't hold after settling, retrying"
                    )
                    continue
                }
                emit(
                    type: "diagnostic",
                    step: "set_visit_date",
                    message: "visit date picker: matched \"\(settled.text)\" "
                        + "(parsed as \(settled.month.map(String.init) ?? "nil")/\(settled.year)), closing"
                )
                break
            }

            let down = selection.year != targetYear
            emit(
                type: "diagnostic",
                step: "set_visit_date",
                message: "visit date picker: read \"\(selection.text)\", nudging \(down ? "down" : "up")"
            )
            nudgeWheel(at: selection.point, down: down)
            try await pause(0.35)
        }

        try await clickDetectedTarget(CGPoint(x: visibleMonth.x, y: headerY))
    }

    private func nudgeWheel(at normalizedPoint: CGPoint, down: Bool) {
        activatePhoneWindow()
        let point = globalPoint(normalizedPoint)
        CGWarpMouseCursorPosition(point)
        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        usleep(40_000)
        CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 1,
            wheel1: down ? -50 : 50,
            wheel2: 0,
            wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    private func waitForText(
        _ target: String,
        timeout: TimeInterval,
        predicate: (OCRItem) -> Bool = { _ in true }
    ) async throws -> OCRItem {
        if let item = try await findText(target, timeout: timeout, predicate: predicate) {
            return item
        }
        throw AutomationFailure.message("Could not find “\(target)” in iPhone Mirroring.")
    }

    private func findText(
        _ target: String,
        timeout: TimeInterval,
        predicate: (OCRItem) -> Bool = { _ in true }
    ) async throws -> OCRItem? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let items = try recognizeText(in: await capture.image())
            if let match = bestTextMatch(target, in: items.filter(predicate)) {
                return match
            }
            // The capture stream only delivers a fresh frame every ~200ms
            // (minimumFrameInterval = 1/5 in StreamingPhoneScreenshot), so
            // polling faster than that just re-reads the same stale frame --
            // this sits just above that floor.
            try await pause(0.22)
        }
        return nil
    }

    private func recognizeText(
        in image: CGImage,
        level: VNRequestTextRecognitionLevel = .accurate
    ) throws -> [OCRItem] {
        try visionQueue.sync {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = level
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.006
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return OCRItem(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    x: box.minX,
                    y: 1 - box.maxY,
                    width: box.width,
                    height: box.height
                )
            }
        }
    }

    private func bestTextMatch(_ target: String, in items: [OCRItem]) -> OCRItem? {
        let needle = normalize(target)
        return items
            .filter { item in
                let value = normalize(item.text)
                if value.contains(needle) { return true }
                // OCR sometimes splits a phrase, and Beli rewords labels, so a piece
                // of the target counts -- the bottom "Search" tab has been standing
                // in for the reworded search box this whole time. But not a tiny
                // piece: a 1-3 character fragment (an avatar's "K", a stray "20" or
                // "3") is a substring of almost any phrase, and used to be accepted
                // as the target. The notes step "found" its placeholder in a
                // friend's initial, and a date search tapped "3" as if it were
                // "August 30, 2026".
                return value.count >= 4 && needle.contains(value)
            }
            .max { first, second in
                let firstExact = normalize(first.text) == needle ? 1 : 0
                let secondExact = normalize(second.text) == needle ? 1 : 0
                if firstExact != secondExact { return firstExact < secondExact }
                return first.confidence < second.confidence
            }
    }

    private var phoneProcessID: pid_t {
        capture.window.owningApplication?.processID ?? 0
    }

    // Screen capture reads the phone window's own surface, so OCR and photo
    // matching work fine while another app covers it -- but clicks, scrolls and
    // keystrokes go to whatever is actually on top (a click lands in the
    // covering app, and typed text is typed into it). NSRunningApplication's
    // activate() is only a request, and macOS ignores it from a background
    // process while another app is frontmost, so the phone just stayed behind
    // whatever was last clicked. Setting AXFrontmost -- what System Events does
    // when the workspace is tiled -- raises it for real.
    private func activatePhoneWindow() {
        let pid = phoneProcessID
        guard pid != 0 else { return }
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    }

    // Owner of the frontmost real window on screen, read straight from the
    // window server so it can't be stale. Tiny or transparent helper windows
    // are skipped; they can't be what's covering the phone.
    private func frontmostWindowOwner() -> (pid: pid_t, name: String)? {
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        for window in windows {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 80, bounds.height >= 80,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            return (pid, window[kCGWindowOwnerName as String] as? String ?? "another app")
        }
        return nil
    }

    // Raises the phone and confirms it is on top before any input is sent.
    // Throws instead of acting on the wrong window, since a stray click or
    // keystroke in another app does real damage and a clear error doesn't.
    private func ensurePhoneInFront() throws {
        var coveredBy = "another app"
        for _ in 0..<20 {
            guard let owner = frontmostWindowOwner() else { return }
            if owner.pid == phoneProcessID { return }
            coveredBy = owner.name
            activatePhoneWindow()
            usleep(150_000)
        }
        throw AutomationFailure.message(
            "iPhone Mirroring is behind \(coveredBy), so this step was stopped instead of clicking into it. "
                + "Bring iPhone Mirroring to the front and retry."
        )
    }

    // SCWindow.frame is a snapshot from when capture started, but the workspace
    // tiler (or the user) can still be moving the window around then, and every
    // click is aimed from this frame. Read the current bounds each time.
    private func liveWindowFrame() -> CGRect {
        guard let info = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow],
                capture.window.windowID
              ) as? [[String: Any]],
              let boundsDictionary = info.first?[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
              frame.width > 0, frame.height > 0
        else { return capture.window.frame }
        return frame
    }

    private func click(_ normalizedPoint: CGPoint) throws {
        try ensurePhoneInFront()
        let frame = liveWindowFrame()
        if !reportedWindowMove,
           abs(frame.minX - capture.window.frame.minX) > 2 || abs(frame.minY - capture.window.frame.minY) > 2 {
            reportedWindowMove = true
            emit(
                type: "diagnostic",
                step: nil,
                message: "phone window moved after capture started: \(capture.window.frame) -> \(frame)"
            )
        }
        let point = CGPoint(
            x: frame.minX + normalizedPoint.x * frame.width,
            y: frame.minY + normalizedPoint.y * frame.height
        )
        // Put the real cursor on the target before pressing. iPhone Mirroring turns
        // the pointer into touches, and a press posted at a position the cursor
        // never visited doesn't reliably land there -- the cursor stayed wherever
        // it was and the tap missed (seen live: the + button was "tapped" with the
        // cursor nowhere near it). The scroll code already moves the cursor first.
        CGWarpMouseCursorPosition(point)
        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        usleep(90_000)
        let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(55_000)
        up?.post(tap: .cghidEventTap)
    }

    private func clickThroughScreenshot(_ normalizedPoint: CGPoint) async throws {
        try await pause(0.25)
        try click(normalizedPoint)
        // Kept well above the other settle pauses -- too short a gap risks the
        // OS reading these two taps as one double-click gesture instead of two
        // independent ones.
        try await pause(0.9)
        try click(normalizedPoint)
    }

    private func clickDetectedTarget(_ normalizedPoint: CGPoint) async throws {
        try click(normalizedPoint)
        try await pause(0.22)
    }

    private func scrollDown() throws {
        try ensurePhoneInFront()
        let point = globalPoint(CGPoint(x: 0.5, y: 0.62))
        CGWarpMouseCursorPosition(point)
        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        usleep(70_000)
        for _ in 0..<2 {
            CGEvent(
                scrollWheelEvent2Source: eventSource,
                units: .pixel,
                wheelCount: 1,
                wheel1: -320,
                wheel2: 0,
                wheel3: 0
            )?.post(tap: .cghidEventTap)
            usleep(45_000)
        }
    }

    private func scrollPhotoUpload(up: Bool = false) throws {
        try ensurePhoneInFront()
        let point = globalPoint(CGPoint(x: 0.5, y: 0.7))
        CGWarpMouseCursorPosition(point)
        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        usleep(70_000)
        CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 1,
            wheel1: up ? 260 : -260,
            wheel2: 0,
            wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    private func globalPoint(_ normalizedPoint: CGPoint) -> CGPoint {
        let frame = liveWindowFrame()
        return CGPoint(
            x: frame.minX + normalizedPoint.x * frame.width,
            y: frame.minY + normalizedPoint.y * frame.height
        )
    }

    private func typeText(_ text: String) throws {
        // Keystrokes go to whatever app is frontmost, not to a window under the
        // cursor, so this matters more here than for clicks.
        try ensurePhoneInFront()
        let phoneName = capture.window.owningApplication?.applicationName ?? "iPhone Mirroring"
        let characterDelays = text.map { _ in
            String(Int.random(in: 30...50))
        }.joined(separator: ",")
        let typing = Process()
        typing.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        typing.arguments = [
            "-e",
            "on run argv",
            "-e",
            "set inputText to item 1 of argv",
            "-e",
            "set delayText to item 2 of argv",
            "-e",
            "set phoneName to item 3 of argv",
            "-e",
            "set previousDelimiters to AppleScript's text item delimiters",
            "-e",
            "set AppleScript's text item delimiters to \",\"",
            "-e",
            "set characterDelays to text items of delayText",
            "-e",
            "set AppleScript's text item delimiters to previousDelimiters",
            "-e",
            "set characterIndex to 1",
            "-e",
            "tell application \"System Events\"",
            "-e",
            "set frontmost of process phoneName to true",
            "-e",
            "delay 0.15",
            "-e",
            "repeat with currentCharacter in characters of inputText",
            "-e",
            "if (characterIndex mod 6) is 1 then",
            "-e",
            "if (name of first application process whose frontmost is true) is not phoneName then error \"FOCUS_LOST\"",
            "-e",
            "end if",
            "-e",
            "keystroke (currentCharacter as text)",
            "-e",
            "delay (((item characterIndex of characterDelays) as integer) / 1000.0)",
            "-e",
            "set characterIndex to characterIndex + 1",
            "-e",
            "end repeat",
            "-e",
            "end tell",
            "-e",
            "end run",
            "--",
            text,
            characterDelays,
            phoneName,
        ]
        typing.standardOutput = FileHandle.nullDevice
        let typingErrors = Pipe()
        typing.standardError = typingErrors
        try typing.run()
        typing.waitUntilExit()
        guard typing.terminationStatus == 0 else {
            // The script re-checks the frontmost app as it types and stops the
            // moment it isn't the phone, rather than finishing the text into
            // whatever the user clicked on.
            let detail = String(data: typingErrors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if detail.contains("FOCUS_LOST") {
                throw AutomationFailure.message(
                    "\(phoneName) lost focus while typing, so typing stopped instead of going into another app. "
                        + "Leave it in front until the run finishes, then retry."
                )
            }
            throw AutomationFailure.message("macOS could not type into iPhone Mirroring.")
        }
        usleep(200_000)
    }

    private static func findTealCircle(in image: CGImage) -> CGPoint? {
        guard let pixels = rgbaPixels(image) else { return nil }
        let width = image.width
        let height = image.height
        let radius = Double(width) * 0.034
        var best: (x: Int, y: Int, score: Int)?

        func isTeal(x: Int, y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            let offset = (y * width + x) * 4
            let red = Int(pixels[offset])
            let green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2])
            // Beli's teal is DARK (about 37, 76, 87). Without the red ceiling any
            // pale blue passed -- the East River on the restaurant page's map scored
            // full marks, and since the scan stops at the first near-perfect ring it
            // beat the real button, which sits lower. The click then went to the
            // water (live: 0.838, 0.368 instead of the button at 0.803, 0.400).
            return green > red + 12 && blue > red + 12 && green > 65 && blue > 65 && red < 130
        }

        // The title/rating row (and thus the +/bookmark row below it) shifts down when a
        // restaurant name wraps to two lines or extra badges appear above it, so this band
        // has to be wide enough to cover that variance rather than one restaurant's layout.
        let yStride = stride(
            from: Int(Double(height) * 0.28),
            to: Int(Double(height) * 0.58),
            by: 2
        )
        let xStride = stride(
            from: Int(Double(width) * 0.72),
            to: Int(Double(width) * 0.84),
            by: 2
        )

        search: for y in yStride {
            for x in xStride {
                var score = 0
                for sample in 0..<40 {
                    let angle = Double(sample) / 40 * .pi * 2
                    let sampleX = x + Int(cos(angle) * radius)
                    let sampleY = y + Int(sin(angle) * radius)
                    if isTeal(x: sampleX, y: sampleY) { score += 1 }
                }
                if best == nil || score > best!.score {
                    best = (x, y, score)
                }
                // Near-perfect ring match: stop scanning downward immediately so a wider
                // band can't skip past the +/bookmark row onto the teal score rings below it.
                if score >= 34 { break search }
            }
        }

        guard let best, best.score >= 8 else { return nil }
        return CGPoint(
            x: Double(best.x) / Double(width),
            y: Double(best.y) / Double(height)
        )
    }

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func start(_ step: String) {
        emit(type: "progress", step: step, message: nil)
    }

    private func finish(_ step: String) {
        emit(type: "finished", step: step, message: nil)
    }

    private func emit(type: String, step: String?, message: String?) {
        var payload: [String: String] = ["type": type]
        if let step { payload["step"] = step }
        if let message { payload["message"] = message }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }

    private func normalize(_ string: String) -> String {
        string
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> Double {
        hypot(first.x - second.x, first.y - second.y)
    }

    private static func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    private static func centerSquare(_ image: CGImage) -> CGImage {
        let side = min(image.width, image.height)
        let cropRect = CGRect(
            x: (image.width - side) / 2,
            y: (image.height - side) / 2,
            width: side,
            height: side
        )
        return image.cropping(to: cropRect) ?? image
    }

    // Vision's built-in perceptual-similarity embedding. Unlike a hand-rolled
    // pixel/color hash, this is trained to recognize the same photo across
    // the compression and cropping differences between our saved copy and
    // iOS's own picker thumbnail, so genuine matches and near-misses land
    // much further apart than the old hash's ~0.34-0.37 near-miss band.
    private static func featurePrint(_ image: CGImage) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let result = request.results?.first as? VNFeaturePrintObservation else {
            throw AutomationFailure.message("A photo could not be analyzed.")
        }
        return result
    }

    private static func featurePrintDistance(
        _ first: VNFeaturePrintObservation,
        _ second: VNFeaturePrintObservation
    ) throws -> Float {
        var distance: Float = 0
        try first.computeDistance(&distance, to: second)
        return distance
    }

    private func imageFeature(_ image: CGImage) -> [Float] {
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        let side = min(image.width, image.height)
        let cropRect = CGRect(
            x: (image.width - side) / 2,
            y: (image.height - side) / 2,
            width: side,
            height: side
        )
        guard let crop = image.cropping(to: cropRect) else { return [] }
        context.interpolationQuality = .medium
        context.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))

        var result: [Float] = []
        result.reserveCapacity(size * size * 3)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            result.append(Float(pixels[offset]) / 255)
            result.append(Float(pixels[offset + 1]) / 255)
            result.append(Float(pixels[offset + 2]) / 255)
        }
        return result
    }

    private func featureDistance(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count == second.count, !first.isEmpty else { return 1 }
        var total: Float = 0
        for index in first.indices {
            let delta = first[index] - second[index]
            total += delta * delta
        }
        return sqrt(total / Float(first.count))
    }

    private static func loadImage(_ path: String) -> CGImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    private static let months = Calendar.current.monthSymbols
    private static let stepOrder = [
        "open_beli",
        "find_restaurant",
        "start_rating",
        "choose_category",
        "add_rating",
        "add_notes",
        "set_visit_date",
        "add_photos",
        "add_photo_descriptions",
        "finish_in_beli",
    ]
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    // Matches the system photo picker's natural-language date search, e.g.
    // "August 9, 2026" (confirmed live).
    private static let searchDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()
}

// Groups OCR items from a Beli "My Lists" screen into (name, score) rows.
// Vision returns each visual line as one OCR item, and Beli numbers every row
// ("1. Kaiten Sushi Ginza Onodera"), so titles are found via that numbering
// prefix rather than fuzzy y-clustering (an earlier attempt at bucket-averaging
// nearby lines "chained" the title and the price/cuisine line below it together
// -- calibrated against a real screenshot via `--ratings-debug`).
// A restaurant whose score is locked (Beli hides it until 10+ ratings in that
// category) has no nearby numeric item and is skipped rather than guessed at.
//
// (Tried also capturing the city line, keyed as "name (city)", to disambiguate
// chain restaurants with multiple rated locations -- reverted: the city is
// the 2nd line below the title only when every expected line is present, and
// on the last card of a screen with no next title to bound it, unrelated UI
// text like "View Map"/"Search" bled in instead. Turned out unnecessary
// anyway -- Beli's duel/comparison screen shows the opponent's score
// directly, so duel-matching doesn't need to look up this dictionary at all.)
private func groupRatingsRows(_ items: [OCRItem]) -> [(name: String, score: Double)] {
    let titlePrefix = "^\\d{1,3}\\.\\s+"
    let scoreRowTolerance = 0.015

    let titles = items.filter { $0.text.range(of: titlePrefix, options: .regularExpression) != nil }
    let scores = items.compactMap { item -> (item: OCRItem, value: Double)? in
        guard item.text.range(of: "^\\d{1,2}\\.\\d{1,2}$", options: .regularExpression) != nil,
              let value = Double(item.text), (0...10).contains(value) else { return nil }
        return (item, value)
    }

    return titles.compactMap { title -> (name: String, score: Double)? in
        let nearby = scores
            .filter { abs($0.item.center.y - title.center.y) < scoreRowTolerance }
            .sorted { abs($0.item.center.y - title.center.y) < abs($1.item.center.y - title.center.y) }
        guard let score = nearby.first else { return nil }

        let name = title.text
            .replacingOccurrences(of: titlePrefix, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return (name: name, score: score.value)
    }
}

private func normalizeRatingName(_ string: String) -> String {
    string
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// Extracts a trailing "<bullet> <score>" from a duel card's city line, e.g.
// "New York, NY • 4.7" -> 4.7. Beli's own bullet character OCRs
// inconsistently, so this matches any short separator before the number.
private func extractTrailingScore(from text: String) -> Double? {
    guard let regex = try? NSRegularExpression(pattern: "\\S\\s*(\\d{1,2}\\.\\d{1,2})\\s*$"),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let captureRange = Range(match.range(at: 1), in: text)
    else { return nil }
    return Double(text[captureRange])
}

// Detects a Beli "Which do you prefer?" duel screen and identifies the
// opponent (whichever "City, ST" line has a trailing score) and its side.
// Outer optional: no duel screen present at all. Inner opponentScore
// optional: a duel is showing but the opponent's score couldn't be read
// (e.g. OCR noise) -- the caller falls back to Beli's own "Too tough" button
// rather than guessing. Free function (not a BeliAutomation method) so it
// can be calibrated against a saved screenshot via `--duel-debug`.
private func parseDuelScreen(
    _ items: [OCRItem]
) -> (opponentScore: Double?, opponentOnRight: Bool, opponentLineY: Double)? {
    guard items.contains(where: {
        normalizeRatingName($0.text).contains(normalizeRatingName("which do you prefer"))
    }) else {
        return nil
    }

    let cityLines = items.filter {
        $0.text.range(of: ",\\s*[A-Z]{2}\\b", options: .regularExpression) != nil
    }
    guard let opponentLine = cityLines.first(where: { extractTrailingScore(from: $0.text) != nil }) else {
        return (opponentScore: nil, opponentOnRight: false, opponentLineY: 0.5)
    }

    return (
        opponentScore: extractTrailingScore(from: opponentLine.text),
        opponentOnRight: opponentLine.center.x > 0.5,
        opponentLineY: Double(opponentLine.center.y)
    )
}

// A ScreenCaptureKit STREAM (continuous capture), unlike PhoneScreenshot's
// one-off SCScreenshotManager.captureImage calls. Confirmed on-device: Beli
// detects discrete screenshots and responds with its own share-sheet nudge
// (the same thing happens when manually screenshotting the phone), but does
// NOT react to screen recording. Pulling still frames from a running stream
// avoids ever taking an actual "screenshot" of the phone.
private actor FrameBox {
    private var latestImage: CGImage?
    private var waiters: [CheckedContinuation<CGImage, Error>] = []

    func setLatest(_ image: CGImage) {
        latestImage = image
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume(returning: image)
        }
    }

    func image() async throws -> CGImage {
        if let latestImage { return latestImage }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private final class StreamingPhoneScreenshot: NSObject, SCStreamOutput {
    let window: SCWindow
    private let stream: SCStream
    private let frameBox = FrameBox()
    private let ciContext = CIContext()

    private init(window: SCWindow, stream: SCStream) {
        self.window = window
        self.stream = stream
        super.init()
    }

    static func start() async throws -> StreamingPhoneScreenshot {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let phoneWindow = content.windows.first(where: { window in
            let appName = window.owningApplication?.applicationName.lowercased() ?? ""
            return appName.contains("iphone mirroring")
        }) else {
            throw AutomationFailure.message("iPhone Mirroring is not open.")
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(phoneWindow.frame.width * scale))
        configuration.height = max(1, Int(phoneWindow.frame.height * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        configuration.queueDepth = 3

        let filter = SCContentFilter(desktopIndependentWindow: phoneWindow)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let capture = StreamingPhoneScreenshot(window: phoneWindow, stream: stream)
        try stream.addStreamOutput(
            capture,
            type: .screen,
            sampleHandlerQueue: DispatchQueue(label: "auto-beli.ratings-export.stream")
        )
        try await stream.startCapture()
        return capture
    }

    func stop() async {
        try? await stream.stopCapture()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let box = frameBox
        Task { await box.setLatest(cgImage) }
    }

    func image() async throws -> CGImage {
        try await frameBox.image()
    }
}

// Drives a live export of the user's own Beli ratings list into a name->score
// dictionary. Assumes the phone is ALREADY showing that list (the user navigates
// there manually before starting the export) so this never has to guess Beli's
// tab/navigation labels -- it only scrolls, reads, and dedupes from wherever the
// screen currently is, stopping once scrolling produces no more new rows.
private final class RatingsExporter {
    private let capture: StreamingPhoneScreenshot
    private let visionQueue = DispatchQueue(label: "auto-beli.ratings-export.vision")
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    init() async throws {
        capture = try await StreamingPhoneScreenshot.start()
    }

    private func recognizeText(in image: CGImage) throws -> [OCRItem] {
        try visionQueue.sync {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.006
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return OCRItem(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    x: box.minX,
                    y: 1 - box.maxY,
                    width: box.width,
                    height: box.height
                )
            }
        }
    }

    private func activatePhoneWindow() {
        guard let app = NSRunningApplication(
            processIdentifier: capture.window.owningApplication?.processID ?? 0
        ) else { return }
        app.activate(options: [])
    }

    // A click-drag swipe (tried as an alternative to scroll-wheel events,
    // since a double scroll-wheel tick was observed to open Beli's share
    // sheet) did not register as a scroll at all, even with generous manual
    // pacing. Falls back to scroll-wheel with a SINGLE tick per call --
    // the double-tick (two ticks 45ms apart) is the specific thing under
    // suspicion for being misread as some other gesture.
    private func scrollDown() {
        // Deliberately does NOT re-activate the window here -- export()
        // activates it once at the start, and repeatedly reactivating an
        // already-frontmost app on every scroll (18+ times a run) is under
        // suspicion for destabilizing something that opens Beli's share sheet.
        let point = CGPoint(
            x: capture.window.frame.minX + 0.5 * capture.window.frame.width,
            y: capture.window.frame.minY + 0.62 * capture.window.frame.height
        )
        CGWarpMouseCursorPosition(point)
        CGEvent(
            mouseEventSource: eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
        usleep(70_000)
        CGEvent(
            scrollWheelEvent2Source: eventSource,
            units: .pixel,
            wheelCount: 1,
            wheel1: -320,
            wheel2: 0,
            wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    private func imageFeature(_ image: CGImage) -> [Float] {
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        let side = min(image.width, image.height)
        let cropRect = CGRect(
            x: (image.width - side) / 2,
            y: (image.height - side) / 2,
            width: side,
            height: side
        )
        guard let crop = image.cropping(to: cropRect) else { return [] }
        context.interpolationQuality = .medium
        context.draw(crop, in: CGRect(x: 0, y: 0, width: size, height: size))
        var result: [Float] = []
        result.reserveCapacity(size * size * 3)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            result.append(Float(pixels[offset]) / 255)
            result.append(Float(pixels[offset + 1]) / 255)
            result.append(Float(pixels[offset + 2]) / 255)
        }
        return result
    }

    private func featureDistance(_ first: [Float], _ second: [Float]) -> Float {
        guard first.count == second.count, !first.isEmpty else { return 1 }
        var total: Float = 0
        for index in first.indices {
            let delta = first[index] - second[index]
            total += delta * delta
        }
        return sqrt(total / Float(first.count))
    }

    private func emit(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }

    private func writeOutput(_ ratings: [String: Double], to path: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: ratings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path))
    }

    func export(to outputPath: String) async throws -> Int {
        do {
            let count = try await runExport(to: outputPath)
            await capture.stop()
            return count
        } catch {
            await capture.stop()
            throw error
        }
    }

    private func runExport(to outputPath: String) async throws -> Int {
        activatePhoneWindow()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        var ratings: [String: Double] = [:]
        var seenNormalizedNames: Set<String> = []
        var previousFeature: [Float]?
        var unchangedScreens = 0
        var scrolls = 0

        while unchangedScreens < 2 && scrolls < 400 {
            let image = try await capture.image()
            let items = try recognizeText(in: image)
            let before = ratings.count
            for row in groupRatingsRows(items) {
                let key = normalizeRatingName(row.name)
                guard !key.isEmpty, seenNormalizedNames.insert(key).inserted else { continue }
                ratings[row.name] = row.score
            }
            if ratings.count != before {
                try writeOutput(ratings, to: outputPath)
                emit(["type": "diagnostic", "message": "Found \(ratings.count) ratings so far"])
            }

            // Beli shows an explicit "Looking for more restaurants to rank?"
            // empty state at the true end of the list -- stop immediately
            // instead of waiting for image-stagnation to confirm it, which
            // wastes several extra scrolls past the real end.
            let reachedEndOfList = items.contains {
                normalizeRatingName($0.text).contains("looking for more restaurants")
            }
            if reachedEndOfList {
                emit(["type": "diagnostic", "message": "Reached the end of the list"])
                break
            }

            let feature = imageFeature(image)
            if let previousFeature, featureDistance(previousFeature, feature) < 0.006 {
                unchangedScreens += 1
            } else {
                unchangedScreens = 0
            }
            previousFeature = feature

            if unchangedScreens < 2 {
                scrollDown()
                try await Task.sleep(nanoseconds: 550_000_000)
                scrolls += 1
            }
        }

        try writeOutput(ratings, to: outputPath)
        return ratings.count
    }
}

private func exportRatings(to outputPath: String) async {
    do {
        let exporter = try await RatingsExporter()
        let count = try await exporter.export(to: outputPath)
        print("{\"type\":\"complete\",\"count\":\(count)}")
        fflush(stdout)
    } catch {
        let message = error.localizedDescription
        if let data = try? JSONSerialization.data(withJSONObject: ["type": "error", "message": message]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
        fputs("\(message)\n", stderr)
        exit(1)
    }
}

private func runRatingsDebugFixture(path: String) throws {
    guard let image = BeliAutomation.loadFixtureImage(path) else {
        throw AutomationFailure.message("The fixture image could not be read.")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.006
    try VNImageRequestHandler(cgImage: image).perform([request])
    let items = (request.results ?? []).compactMap { observation -> OCRItem? in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        return OCRItem(
            text: candidate.string,
            confidence: candidate.confidence,
            x: box.minX,
            y: 1 - box.maxY,
            width: box.width,
            height: box.height
        )
    }
    let rows = groupRatingsRows(items)
    for row in rows {
        print("\(row.score)\t\(row.name)")
    }
    fputs("(\(rows.count) rows parsed from \(items.count) OCR items)\n", stderr)
}

private func runOCRFixture(path: String) throws {
    guard let image = BeliAutomation.loadFixtureImage(path) else {
        throw AutomationFailure.message("The fixture image could not be read.")
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.minimumTextHeight = 0.006
    try VNImageRequestHandler(cgImage: image).perform([request])
    let items = (request.results ?? []).compactMap { observation -> OCRItem? in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        return OCRItem(
            text: candidate.string,
            confidence: candidate.confidence,
            x: box.minX,
            y: 1 - box.maxY,
            width: box.width,
            height: box.height
        )
    }
    let data = try JSONEncoder().encode(items)
    print(String(decoding: data, as: UTF8.self))
}

// macOS grants Accessibility and Screen Recording to the app that launched
// this process, not to this binary -- normally the terminal running
// `pnpm dev`, but whichever app it is, that's the row to allow. Naming the
// binary instead sends people hunting for a row that was never in the list,
// so walk up to the owning .app and name that.
private func launchingAppName() -> String? {
    var pid = getppid()
    // The outermost .app wins, not the first one found: a host app can run
    // this by way of its own nested helper bundles, and it's the top-level
    // app that System Settings lists and that the permission is granted to.
    var outermost: String?

    // Bounded so a parent cycle or an unexpectedly deep tree can't spin here.
    for _ in 0..<16 {
        guard pid > 1 else { break }

        var pathBuffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            let path = String(cString: pathBuffer)
            // ".../Foo.app/Contents/MacOS/Foo" -> "Foo"
            if let range = path.range(of: ".app/Contents/") {
                let bundlePath = String(path[path.startIndex..<range.lowerBound])
                let name = (bundlePath as NSString).lastPathComponent
                if !name.isEmpty { outermost = name }
            }
        }

        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { break }

        let parent = info.kp_eproc.e_ppid
        guard parent != pid else { break }
        pid = parent
    }

    return outermost
}

private func permissionMessage(for pane: String) -> String {
    let app = launchingAppName() ?? "the app you ran pnpm dev from"
    return "Allow \(app) in System Settings → Privacy & Security → \(pane), "
        + "then restart it and try again."
}

private func requireAutomationPermissions() throws {
    let accessibilityOptions = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
    ] as CFDictionary
    guard AXIsProcessTrustedWithOptions(accessibilityOptions) else {
        throw AutomationFailure.message(permissionMessage(for: "Accessibility"))
    }
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
        throw AutomationFailure.message(
            permissionMessage(for: "Screen & System Audio Recording")
        )
    }
}

private extension BeliAutomation {
    static func loadFixtureImage(_ path: String) -> CGImage? {
        loadImage(path)
    }

    static func tealFixturePoint(_ image: CGImage) -> CGPoint? {
        findTealCircle(in: image)
    }

    static func gridFixtureDescription(_ image: CGImage) -> String? {
        guard let separators = photoGridSeparators(in: image) else { return nil }
        return "columns=\(separators.columns.map(String.init).joined(separator: ",")) rows=\(separators.rows.map(String.init).joined(separator: ","))"
    }

    static func matchFixtureDescription(screen: CGImage, target: CGImage) throws -> String {
        let targetSignature = try featurePrint(centerSquare(target))
        let distances = try gridCells(in: screen).enumerated().map { index, cell in
            let cellSignature = try featurePrint(cell.image)
            let distance = try featurePrintDistance(targetSignature, cellSignature)
            return (index, distance)
        }.sorted { $0.1 < $1.1 }
        return distances.prefix(5).map {
            "\($0.0):\(String(format: "%.3f", $0.1))"
        }.joined(separator: " ")
    }
}

@main
private struct Main {
    static func main() async {
        do {
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--ocr" {
                try runOCRFixture(path: CommandLine.arguments[2])
                return
            }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--ratings-debug" {
                try runRatingsDebugFixture(path: CommandLine.arguments[2])
                return
            }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--duel-debug" {
                guard let image = BeliAutomation.loadFixtureImage(CommandLine.arguments[2]) else {
                    throw AutomationFailure.message("The fixture image could not be read.")
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.minimumTextHeight = 0.006
                try VNImageRequestHandler(cgImage: image).perform([request])
                let items = (request.results ?? []).compactMap { observation -> OCRItem? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    let box = observation.boundingBox
                    return OCRItem(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        x: box.minX,
                        y: 1 - box.maxY,
                        width: box.width,
                        height: box.height
                    )
                }
                guard let duel = parseDuelScreen(items) else {
                    print("no duel screen detected")
                    return
                }
                if let score = duel.opponentScore {
                    print("duel detected: opponent score \(score), on \(duel.opponentOnRight ? "right" : "left") side, y=\(duel.opponentLineY)")
                } else {
                    print("duel detected, but could not read opponent score")
                }
                return
            }
            if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--scroll-debug" {
                try requireAutomationPermissions()
                let capture = try await StreamingPhoneScreenshot.start()
                let eventSource = CGEventSource(stateID: .hidSystemState)
                let frame = capture.window.frame

                print("[1/6] activating iPhone Mirroring window in 2s...")
                fflush(stdout)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                if let app = NSRunningApplication(
                    processIdentifier: capture.window.owningApplication?.processID ?? 0
                ) {
                    app.activate(options: [])
                }

                print("[2/6] activated. Grabbing a frame from the capture STREAM (not a one-off screenshot) in 2s...")
                fflush(stdout)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                _ = try await capture.image()

                let point = CGPoint(x: frame.minX + 0.5 * frame.width, y: frame.minY + 0.62 * frame.height)
                print("[3/6] frame grabbed -- check nothing changed on screen. Warping cursor to \(point.x), \(point.y) in 2s...")
                fflush(stdout)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                CGWarpMouseCursorPosition(point)

                print("[4/6] cursor warped -- look at where it is now. Posting mouseMoved in 2s...")
                fflush(stdout)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                CGEvent(
                    mouseEventSource: eventSource,
                    mouseType: .mouseMoved,
                    mouseCursorPosition: point,
                    mouseButton: .left
                )?.post(tap: .cghidEventTap)

                print("[5/6] mouseMoved posted -- check for any visible change. Posting a SINGLE scroll tick in 2s...")
                fflush(stdout)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                CGEvent(
                    scrollWheelEvent2Source: eventSource,
                    units: .pixel,
                    wheelCount: 1,
                    wheel1: -320,
                    wheel2: 0,
                    wheel3: 0
                )?.post(tap: .cghidEventTap)

                print("[6/6] done -- check what happened on the phone screen.")
                fflush(stdout)
                await capture.stop()
                return
            }
            if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--window-debug" {
                try requireAutomationPermissions()
                let capture = try await PhoneScreenshot()
                let frame = capture.window.frame
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                print("frame.minX=\(frame.minX) frame.minY=\(frame.minY) frame.width=\(frame.width) frame.height=\(frame.height) backingScaleFactor=\(scale)")
                let scrollPoint = CGPoint(
                    x: frame.minX + 0.5 * frame.width,
                    y: frame.minY + 0.62 * frame.height
                )
                print("computed scroll point (global): \(scrollPoint.x), \(scrollPoint.y)")
                for screen in NSScreen.screens {
                    print("NSScreen frame: \(screen.frame) visibleFrame: \(screen.visibleFrame)")
                }
                return
            }
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--tap-debug",
               let x = Double(CommandLine.arguments[2]), let y = Double(CommandLine.arguments[3]) {
                try requireAutomationPermissions()
                let capture = try await PhoneScreenshot()
                let frame = capture.window.frame
                let point = CGPoint(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height)
                print("Warping cursor to fraction (\(x), \(y)) -> global point \(point.x), \(point.y) in 2s...")
                fflush(stdout)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                CGWarpMouseCursorPosition(point)
                print("Cursor warped -- look at the phone screen now. Not clicking.")
                fflush(stdout)
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return
            }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--export-ratings" {
                try requireAutomationPermissions()
                await exportRatings(to: CommandLine.arguments[2])
                return
            }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--teal" {
                guard let image = BeliAutomation.loadFixtureImage(CommandLine.arguments[2]),
                      let point = BeliAutomation.tealFixturePoint(image) else {
                    throw AutomationFailure.message("No teal circle was found.")
                }
                print("\(point.x),\(point.y)")
                return
            }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--grid" {
                guard let image = BeliAutomation.loadFixtureImage(CommandLine.arguments[2]),
                      let description = BeliAutomation.gridFixtureDescription(image) else {
                    throw AutomationFailure.message("No photo grid was found.")
                }
                print(description)
                return
            }
            if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--match" {
                guard let screen = BeliAutomation.loadFixtureImage(CommandLine.arguments[2]),
                      let target = BeliAutomation.loadFixtureImage(CommandLine.arguments[3]) else {
                    throw AutomationFailure.message("A match fixture could not be read.")
                }
                print(try BeliAutomation.matchFixtureDescription(screen: screen, target: target))
                return
            }
            guard [3, 4, 5].contains(CommandLine.arguments.count),
                  CommandLine.arguments[1] == "--config" else {
                throw AutomationFailure.message(
                    "Usage: beli-automation --config <config.json> [--start-step <step> | --skip-photos | --continue-photos]"
                )
            }
            let startStep: String
            if CommandLine.arguments.count == 4 {
                guard ["--skip-photos", "--continue-photos"].contains(CommandLine.arguments[3]) else {
                    throw AutomationFailure.message("The recovery arguments are invalid.")
                }
                startStep = CommandLine.arguments[3] == "--skip-photos"
                    ? "skip_photos"
                    : "continue_photos"
            } else if CommandLine.arguments.count == 5 {
                guard CommandLine.arguments[3] == "--start-step" else {
                    throw AutomationFailure.message("The retry arguments are invalid.")
                }
                startStep = CommandLine.arguments[4]
            } else {
                startStep = "open_beli"
            }
            try requireAutomationPermissions()
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let configuration = try JSONDecoder().decode(AutomationConfiguration.self, from: data)
            let automation = try await BeliAutomation(
                configuration: configuration,
                startStep: startStep
            )
            try await automation.run()
            await automation.cleanup()
        } catch {
            let message = error.localizedDescription
            var payload = [
                "type": "error",
                "message": message,
            ]
            if let failure = error as? AutomationFailure,
               let code = failure.recoveryCode {
                payload["code"] = code
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let line = String(data: data, encoding: .utf8) {
                print(line)
                fflush(stdout)
            }
            fputs("\(message)\n", stderr)
            exit(1)
        }
    }
}
