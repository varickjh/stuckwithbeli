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

    init(configuration: AutomationConfiguration, startStep: String) async throws {
        self.configuration = configuration
        self.startStep = startStep
        capture = try await StreamingPhoneScreenshot.start()
    }

    fileprivate func cleanup() async {
        await capture.stop()
    }

    func run() async throws {
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
        let search = try await waitForText("search a restaurant", timeout: 30)
        try await clickDetectedTarget(search.center)
        try await pause(1.1)
        try typeText("\(configuration.restaurantName) \(configuration.address)")

        let currentLocation = try await waitForText("current location", timeout: 20)
        let prefix = String(configuration.restaurantName.prefix(10))
        let result = try await waitForText(prefix, timeout: 45) { item in
            item.center.y > currentLocation.center.y + 0.025
        }
        // Tap the restaurant NAME (not the row's own "+"/bookmark icons,
        // which are a different action -- confirmed live) to open its
        // profile page, where start_rating finds the teal rating button.
        // A single tap silently failed to register here too (same class of
        // issue found elsewhere in this flow) -- double-tap instead.
        try await clickThroughScreenshot(result.center)
        try await pause(1.5)
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
                try await pause(0.9)
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
            try await pause(0.9)
        }

        if duelCount >= 60 {
            throw AutomationFailure.message("Too many comparison rounds -- please finish ranking manually.")
        }
    }

    private func startingRating() async throws {
        start("start_rating")
        let image = try await capture.image()
        guard let plusPoint = Self.findTealCircle(in: image) else {
            throw AutomationFailure.message("The teal rating button could not be found.")
        }
        try await clickThroughScreenshot(plusPoint)
        try await pause(1)
        finish("start_rating")
    }

    private func choosingCategory() async throws {
        start("choose_category")
        let categoryRow = try await waitForText("add to my list of", timeout: 20)
        try await clickDetectedTarget(
            CGPoint(x: 0.57, y: categoryRow.center.y)
        )
        let title = try await waitForText("choose a category", timeout: 20)
        let categoryLabel: String
        switch configuration.category {
        case "Restaurant": categoryLabel = "restaurants"
        case "Bar": categoryLabel = "bars"
        case "Coffee/Tea": categoryLabel = "coffee & tea"
        case "Bakery": categoryLabel = "bakeries"
        case "Dessert/Ice Cream": categoryLabel = "ice cream & dessert"
        default: categoryLabel = "restaurants"
        }
        let category = try await waitForText(categoryLabel, timeout: 15) {
            $0.center.y > title.center.y
        }
        try await clickDetectedTarget(category.center)
        finish("choose_category")
    }

    private func addingNotes() async throws {
        start("add_notes")
        if !configuration.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let addNotes = try await waitForText("add notes", timeout: 20)
            try await clickDetectedTarget(addNotes.center)
            let textArea = try await waitForText("tips, tricks", timeout: 20)
            // A single tap silently failed to focus small targets elsewhere
            // in this flow (confirmed live) -- use the same double-tap
            // workaround already established for the teal button.
            try await clickThroughScreenshot(textArea.center)
            try typeText(configuration.description)
            // Verify the placeholder actually disappeared (i.e. the field
            // received the text) before tapping Done -- a focus click that
            // silently failed would otherwise leave the note empty.
            if try await findText("tips, tricks", timeout: 2) != nil {
                throw AutomationFailure.message("The notes field did not receive the typed text.")
            }
            let done = try await waitForText("done", timeout: 15) { $0.center.y < 0.18 }
            // A fixed double-tap still wasn't reliably dismissing this sheet
            // (confirmed live) -- retry tapping Done until the sheet is
            // actually confirmed closed, rather than guessing a tap count.
            var closed = false
            for _ in 0..<5 {
                try await clickDetectedTarget(done.center)
                try await pause(0.6)
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

        var visibleMonth = try await readVisibleMonth(timeout: 20)
        let calendar = Calendar(identifier: .gregorian)
        let targetComponents = calendar.dateComponents([.year, .month], from: targetDate)
        var movements = 0

        while visibleMonth.year != targetComponents.year || visibleMonth.month != targetComponents.month {
            guard movements < 120 else {
                throw AutomationFailure.message("The visit month is too far from the displayed calendar.")
            }
            let currentIndex = visibleMonth.year * 12 + visibleMonth.month
            let targetIndex = (targetComponents.year ?? 0) * 12 + (targetComponents.month ?? 0)
            let goForward = targetIndex > currentIndex
            try await clickDetectedTarget(
                CGPoint(x: goForward ? 0.938 : 0.887, y: visibleMonth.y)
            )
            try await pause(0.45)
            visibleMonth = try await readVisibleMonth(timeout: 8)
            movements += 1
        }

        let day = calendar.component(.day, from: targetDate)
        let dayItem = try await waitForDay(day, date: targetDate, monthHeaderY: visibleMonth.y)
        try await clickDetectedTarget(dayItem.center)
        let done = try await waitForText("done", timeout: 15) { $0.center.y < 0.18 }
        try await clickDetectedTarget(done.center)
        finish("set_visit_date")
    }

    private func findingPhotos() async throws {
        start("add_photos")
        let addPhotos = try await waitForText("add photos", timeout: 20)
        try await clickDetectedTarget(addPhotos.center)
        try await pause(1.0)

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
                // The search icon is a TOGGLE (tap again closes it) -- unlike
                // the idempotent buttons elsewhere, a blind double-tap here
                // re-closes it (confirmed live). Single-tap, then verify it
                // actually opened before proceeding, retrying only if it
                // didn't.
                var searchOpened = false
                for _ in 0..<3 {
                    try await clickDetectedTarget(CGPoint(x: 0.86, y: 0.94))
                    try await pause(0.5)
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
                if let suggestion = try await findText(dateQuery, timeout: 5, predicate: { $0.center.y < 0.9 }) {
                    try await clickDetectedTarget(suggestion.center)
                    try await pause(0.6)
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

        click(CGPoint(x: 0.898, y: 0.124))
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
            click(CGPoint(x: 0.898, y: 0.124))
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
        try await addPhotoDescriptions(descriptions)
        let save = try await waitForText("save", timeout: 35) { $0.center.y < 0.18 }
        try await clickThroughScreenshot(save.center)
        finish("add_photo_descriptions")
    }

    private func addPhotoDescriptions(_ descriptions: [String]) async throws {
        _ = try await waitForText("photo upload", timeout: 20) { $0.center.y < 0.2 }
        guard !descriptions.isEmpty else {
            throw AutomationFailure.message("No added photos were found to describe.")
        }

        var prompt: OCRItem?
        var previousScreenFeature: [Float]?
        var unchangedScreens = 0
        var scrolls = 0

        while prompt == nil && scrolls < 40 {
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
            scrollPhotoUpload()
            try await pause(0.55)
            scrolls += 1
        }

        guard let prompt else {
            throw AutomationFailure.message("No added photos were found to describe.")
        }
        try await clickDetectedTarget(prompt.center)

        for (index, description) in descriptions.enumerated() {
            _ = try await waitForText("description", timeout: 12) {
                $0.center.y < 0.2
            }
            try await pause(0.6)
            try typeText(description)

            let isLastDescription = index == descriptions.count - 1
            let button = try await waitForText(
                isLastDescription ? "done" : "next",
                timeout: 12
            ) {
                $0.center.y < 0.2
            }
            try await clickDetectedTarget(button.center)
            emit(
                type: "diagnostic",
                step: "add_photo_descriptions",
                message: "added photo description \(index + 1)"
            )
        }

        _ = try await waitForText("photo upload", timeout: 20) {
            $0.center.y < 0.2
        }
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
                try await pause(5)
                if sharePageIsOpen {
                    try await clickDetectedTarget(CGPoint(x: 0.085, y: 0.15))
                    let feed = try await waitForText("feed", timeout: 20) {
                        $0.center.y > 0.8
                    }
                    try await clickDetectedTarget(feed.center)
                } else {
                    let search = try await waitForText("search", timeout: 20) {
                        $0.center.y > 0.8
                    }
                    try await clickDetectedTarget(search.center)
                }
                _ = try await waitForText("search a restaurant", timeout: 20)
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
            try await pause(0.8)
        }
        throw AutomationFailure.message("Timed out while waiting for Beli's share page.")
    }

    private func skipPhotos() async throws {
        start("add_photos")
        let pickerClosePoint = CGPoint(x: 0.107, y: 0.144)
        try await clickDetectedTarget(pickerClosePoint)
        try await pause(0.8)
        try await clickDetectedTarget(pickerClosePoint)
        try await pause(1)
        finish("add_photos")
        start("add_photo_descriptions")
        finish("add_photo_descriptions")
    }

    private func selectPhotos(_ targetImages: [CGImage]) async throws -> [Int] {
        let targetSignatures = try targetImages.map {
            try Self.pixelSignature(Self.centerSquare($0))
        }
        var remaining = Set(targetSignatures.indices)
        var previousGridFeature: [Float]?
        var unchangedPages = 0
        var page = 0
        var selectedOrder: [Int] = []

        while !remaining.isEmpty && page < 10 {
            let image = try await capture.image()
            savePhotoDebugImage(image)
            let cells = Self.gridCells(in: image)
            let cellSignatures = try cells.map { try Self.pixelSignature($0.image) }
            var candidates: [(target: Int, cell: Int, distance: Float)] = []

            for targetIndex in remaining {
                for (cellIndex, cellSignature) in cellSignatures.enumerated() {
                    let distance = Self.pixelSignatureDistance(
                        targetSignatures[targetIndex],
                        cellSignature
                    )
                    candidates.append((targetIndex, cellIndex, distance))
                }
            }
            candidates.sort { $0.distance < $1.distance }
            let bestDistance = candidates.first.map { String(format: "%.3f", $0.distance) } ?? "none"
            emit(
                type: "diagnostic",
                step: "add_photos",
                message: "photo page \(page): \(cells.count) cells, best distance \(bestDistance)"
            )

            // 0.24 was tuned for the old grid-cell cropping; with the new
            // fixed-column cropping the observed best distances for genuine
            // matches sit around 0.24-0.35 (confirmed live), so 0.24 was
            // rejecting real matches outright.
            if let candidate = candidates.first(where: { candidate in
                guard candidate.distance < 0.36 else { return false }
                let secondBest = candidates.first {
                    $0.target == candidate.target && $0.cell != candidate.cell
                }?.distance ?? .greatestFiniteMagnitude
                return candidate.distance + 0.035 < secondBest || candidate.distance < 0.13
            }) {
                try await clickDetectedTarget(cells[candidate.cell].point)
                remaining.remove(candidate.target)
                selectedOrder.append(candidate.target)
                try saveSelectedPhotoOrder(selectedOrder)
                try await pause(0.3)
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
            scrollDown()
            try await pause(0.65)
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

        func rowVariance(_ y: Int) -> Double {
            var minLuminance = 1.0
            var maxLuminance = 0.0
            for x in stride(from: 0, to: width, by: 4) {
                let value = luminance(x: x, y: y)
                minLuminance = min(minLuminance, value)
                maxLuminance = max(maxLuminance, value)
            }
            return maxLuminance - minLuminance
        }

        // Starts past 0.2 to avoid the colorful "Private Access to Photos"
        // permission banner icon being mistaken for photo-grid content
        // (confirmed live) -- costs at most one missed top row if that
        // banner isn't showing, which is a safe tradeoff.
        let searchStart = Int(Double(height) * 0.32)
        let searchEnd = Int(Double(height) * 0.7)
        var gridTop: Int?
        var y = searchStart
        while y < searchEnd {
            if rowVariance(y) > 0.35 {
                gridTop = y
                break
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

    private func waitForDay(
        _ day: Int,
        date: Date,
        monthHeaderY: Double
    ) async throws -> OCRItem {
        let calendar = Calendar(identifier: .gregorian)
        let weekday = calendar.component(.weekday, from: date) - 1
        let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth) - 1
        let row = (firstWeekday + day - 1) / 7
        let expected = CGPoint(
            x: 0.119 + Double(weekday) * 0.127,
            y: monthHeaderY + 0.082 + Double(row) * 0.05
        )

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let items = try recognizeText(in: await capture.image())
            let candidates = items.filter {
                normalize($0.text) == String(day) &&
                    $0.center.y > monthHeaderY + 0.035 && $0.center.y < 0.72
            }
            if let closest = candidates.min(by: {
                distance($0.center, expected) < distance($1.center, expected)
            }) {
                return closest
            }
            try await pause(0.35)
        }
        throw AutomationFailure.message("The visit day could not be found in Beli's calendar.")
    }

    private func readVisibleMonth(timeout: TimeInterval) async throws -> (year: Int, month: Int, y: Double) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let items = try recognizeText(in: await capture.image())
            for item in items where item.center.y > 0.12 && item.center.y < 0.34 {
                let words = item.text
                    .replacingOccurrences(of: ",", with: " ")
                    .split(whereSeparator: { $0.isWhitespace })
                guard let monthWord = words.first,
                      let month = Self.months.firstIndex(where: {
                          $0.caseInsensitiveCompare(String(monthWord)) == .orderedSame
                      }),
                      let yearWord = words.first(where: { $0.count == 4 }),
                      let year = Int(yearWord) else { continue }
                return (year, month + 1, item.center.y)
            }
            try await pause(0.35)
        }
        throw AutomationFailure.message("Beli's visible calendar month could not be read.")
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
            try await pause(0.35)
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
                return value.contains(needle) || needle.contains(value)
            }
            .max { first, second in
                let firstExact = normalize(first.text) == needle ? 1 : 0
                let secondExact = normalize(second.text) == needle ? 1 : 0
                if firstExact != secondExact { return firstExact < secondExact }
                return first.confidence < second.confidence
            }
    }

    private func activatePhoneWindow() {
        guard let app = NSRunningApplication(processIdentifier: capture.window.owningApplication?.processID ?? 0) else {
            return
        }
        app.activate(options: [])
    }

    private func click(_ normalizedPoint: CGPoint) {
        activatePhoneWindow()
        let point = CGPoint(
            x: capture.window.frame.minX + normalizedPoint.x * capture.window.frame.width,
            y: capture.window.frame.minY + normalizedPoint.y * capture.window.frame.height
        )
        let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        usleep(55_000)
        up?.post(tap: .cghidEventTap)
    }

    private func clickThroughScreenshot(_ normalizedPoint: CGPoint) async throws {
        try await pause(0.25)
        click(normalizedPoint)
        try await pause(1)
        click(normalizedPoint)
    }

    private func clickDetectedTarget(_ normalizedPoint: CGPoint) async throws {
        click(normalizedPoint)
        try await pause(0.35)
    }

    private func scrollDown() {
        activatePhoneWindow()
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

    private func scrollPhotoUpload() {
        activatePhoneWindow()
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
            wheel1: -260,
            wheel2: 0,
            wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    private func globalPoint(_ normalizedPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: capture.window.frame.minX + normalizedPoint.x * capture.window.frame.width,
            y: capture.window.frame.minY + normalizedPoint.y * capture.window.frame.height
        )
    }

    private func typeText(_ text: String) throws {
        activatePhoneWindow()
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
            "repeat with currentCharacter in characters of inputText",
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
        ]
        typing.standardOutput = FileHandle.nullDevice
        typing.standardError = FileHandle.nullDevice
        try typing.run()
        typing.waitUntilExit()
        guard typing.terminationStatus == 0 else {
            throw AutomationFailure.message("macOS could not type into iPhone Mirroring.")
        }
        usleep(500_000)
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
            return green > red + 12 && blue > red + 12 && green > 65 && blue > 65
        }

        for y in stride(
            from: Int(Double(height) * 0.36),
            to: Int(Double(height) * 0.47),
            by: 2
        ) {
            for x in stride(
                from: Int(Double(width) * 0.72),
                to: Int(Double(width) * 0.84),
                by: 2
            ) {
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

    private struct PixelSignature {
        let differenceHash: [UInt64]
        let colors: [UInt8]
    }

    private static func pixelSignature(_ image: CGImage) throws -> PixelSignature {
        let width = 17
        let height = 16
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AutomationFailure.message("A photo could not be analyzed.")
        }
        context.interpolationQuality = .high
        context.draw(
            centerSquare(image),
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )

        var hash = [UInt64](repeating: 0, count: 4)
        var colors: [UInt8] = []
        colors.reserveCapacity(8 * 8 * 3)
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let first = (y * width + x) * 4
                let second = first + 4
                let firstLuminance = Int(pixels[first]) * 54 +
                    Int(pixels[first + 1]) * 183 +
                    Int(pixels[first + 2]) * 19
                let secondLuminance = Int(pixels[second]) * 54 +
                    Int(pixels[second + 1]) * 183 +
                    Int(pixels[second + 2]) * 19
                let bit = y * (width - 1) + x
                if firstLuminance < secondLuminance {
                    hash[bit / 64] |= UInt64(1) << UInt64(bit % 64)
                }
            }
        }

        for y in stride(from: 1, to: height, by: 2) {
            for x in stride(from: 1, to: width - 1, by: 2) {
                let offset = (y * width + x) * 4
                colors.append(pixels[offset])
                colors.append(pixels[offset + 1])
                colors.append(pixels[offset + 2])
            }
        }
        return PixelSignature(differenceHash: hash, colors: colors)
    }

    private static func pixelSignatureDistance(
        _ first: PixelSignature,
        _ second: PixelSignature
    ) -> Float {
        let differentBits = zip(first.differenceHash, second.differenceHash)
            .reduce(0) { total, pair in
                total + (pair.0 ^ pair.1).nonzeroBitCount
            }
        let hashDistance = Float(differentBits) / 256
        let colorDifference = zip(first.colors, second.colors).reduce(0) { total, pair in
            total + abs(Int(pair.0) - Int(pair.1))
        }
        let colorDistance = Float(colorDifference) /
            Float(max(1, first.colors.count * 255))
        return hashDistance * 0.7 + colorDistance * 0.3
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

private func requireAutomationPermissions() throws {
    let accessibilityOptions = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
    ] as CFDictionary
    guard AXIsProcessTrustedWithOptions(accessibilityOptions) else {
        throw AutomationFailure.message(
            "Allow Auto Beli in System Settings → Privacy & Security → Accessibility, then try again."
        )
    }
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
        throw AutomationFailure.message(
            "Allow Auto Beli in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
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
        let targetSignature = try pixelSignature(centerSquare(target))
        let distances = try gridCells(in: screen).enumerated().map { index, cell in
            let cellSignature = try pixelSignature(cell.image)
            let distance = pixelSignatureDistance(targetSignature, cellSignature)
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
