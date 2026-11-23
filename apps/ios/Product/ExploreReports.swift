import CoreLocation
import Foundation
import Observation
import SwiftUI
import TrailMeshMaps
import TrailMeshReports

/// The field UI and the developer tools share a protected identity but keep separate report stores.
actor ProductReportStorage {
    static let shared = ProductReportStorage()
    enum Store: String, Sendable {
        case field = "field-reports.sqlite"
        // Preserve the existing development sample store and its acceptance evidence.
        case diagnostics = "reports.sqlite"
    }

    private var opening: [Store: Task<ReportRepository, Error>] = [:]
    private var signing: Task<ReportIdentity, Error>?

    func repository(_ store: Store = .field) async throws -> ReportRepository {
        if let task = opening[store] { return try await task.value }
        let task = Task.detached {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
                .appendingPathComponent("TrailMeshReports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            return try await ReportRepository.open(path: directory.appendingPathComponent(store.rawValue).path)
        }
        opening[store] = task
        do { return try await task.value }
        catch { opening[store] = nil; throw error }
    }

    func identity() async throws -> ReportIdentity {
        if let signing { return try await signing.value }
        let task = Task.detached {
            let keychain = KeychainIdentityStore(service: "org.trailmesh.ios.report-identity.v1", account: "signing")
            let identity: ReportIdentity
            do { identity = try ReportIdentity.load(store: keychain) }
            catch IdentityError.missing {
                guard !UserDefaults.standard.bool(forKey: "reportIdentityEstablished") else { throw IdentityError.missing }
                identity = try ReportIdentity.create(store: keychain)
            }
            UserDefaults.standard.set(true, forKey: "reportIdentityEstablished")
            return identity
        }
        signing = task
        do { return try await task.value }
        catch { signing = nil; throw error }
    }
}

@MainActor
@Observable
final class ExploreReports {
    private(set) var entries: [StoredReport] = []
    private var mapEntries: [StoredReport] = []
    private var markerRegion: String?
    private var markerRequestID: UUID?
    private(set) var hasMore = false
    private(set) var loading = false
    private(set) var error: String?
    private(set) var appendFailed = false
    private var cursor: ReportPageCursor?
    private var requestID: UUID?

    #if TRAILMESH_DEVELOPMENT && targetEnvironment(simulator)
    func capture(loading: Bool = false, error: String? = nil, hasMore: Bool = false) {
        self.loading = loading
        self.error = error
        self.hasMore = hasMore
    }
    #endif

    func mapReports(in manifest: RegionManifest, at date: Date) -> [StoredReport] {
        guard markerRegion == manifest.key else { return [] }
        return mapEntries.filter { Self.current($0, at: date) }
    }

    func discardExpiredMarkers(at date: Date) -> Bool {
        guard mapEntries.contains(where: { !Self.current($0, at: date) }) else { return false }
        mapEntries.removeAll { !Self.current($0, at: date) }
        return true
    }

    func refreshMapReports(in manifest: RegionManifest) async {
        let id = UUID()
        markerRequestID = id
        if markerRegion != manifest.key {
            markerRegion = manifest.key
            mapEntries = []
        }
        do {
            let repository = try await ProductReportStorage.shared.repository()
            let bounds = Self.reportBounds(in: manifest)
            let markers = try await repository.currentMapReports(bounds: bounds, clock: { Self.now() })
            guard markerRequestID == id, !Task.isCancelled else { return }
            mapEntries = markers
        } catch {
            guard markerRequestID == id, !Task.isCancelled else { return }
            mapEntries = []
        }
    }

    private static func reportBounds(in manifest: RegionManifest) -> ReportBounds {
        let bounds = manifest.boundsE7
        return ReportBounds(south: bounds[1], north: bounds[3], west: bounds[0], east: bounds[2])
    }

    func page(in manifest: RegionManifest, more: Bool = false) async {
        if more, loading || !hasMore { return }
        let id = UUID()
        requestID = id
        loading = true
        error = nil
        appendFailed = false
        defer { if requestID == id { loading = false } }
        do {
            let repository = try await ProductReportStorage.shared.repository()
            let queryBounds = Self.reportBounds(in: manifest)
            var next = more ? cursor : nil
            var batch: [StoredReport] = []
            var remaining = false
            // Scan only a few independently verified transactions per request.
            for _ in 0..<4 {
                try Task.checkCancellation()
                guard requestID == id else { return }
                let page = try await repository.reportPage(clock: { Self.now() }, bounds: queryBounds,
                                                           includeExpired: true, after: next, limit: 32)
                next = page.nextCursor
                remaining = page.hasMore
                batch += page.reports
                if !remaining || (more ? !batch.isEmpty : batch.contains(where: { Self.current($0) })) { break }
            }
            try Task.checkCancellation()
            guard requestID == id else { return }
            cursor = next
            hasMore = remaining
            if more {
                let knownIDs = Set(entries.map(\.bundleID))
                entries += batch.filter { !knownIDs.contains($0.bundleID) }
            } else {
                entries = batch
            }
        } catch is CancellationError {
            return
        } catch {
            guard requestID == id else { return }
            appendFailed = more
            self.error = more ? "Couldn’t load more reports." : "Reports couldn’t open. Check your device clock and try again."
            if !more {
                entries = []
                cursor = nil
                hasMore = false
            }
        }
    }

    func save(_ draft: ReportDraft) async throws {
        let repository = try await ProductReportStorage.shared.repository()
        let identity = try await ProductReportStorage.shared.identity()
        let outcome = try await repository.author(draft, identity: identity, clock: { Self.now() })
        switch outcome {
        case .stored: break
        case .rejected(.quota): throw SaveFailure.storageLimit
        default: throw SaveFailure.invalid
        }
    }

    enum SaveFailure: Error { case invalid, storageLimit }

    enum Maintenance {
        case recoverClock, removeExpired

        var title: String {
            switch self {
            case .recoverClock: "Recover after a clock change"
            case .removeExpired: "Remove expired reports"
            }
        }

        var confirmation: String {
            switch self {
            case .recoverClock:
                "Confirm your device date and time are correct. This archives all saved reports on this phone and removes them from current results and sharing."
            case .removeExpired:
                "Confirm your device date and time are correct. This permanently removes expired report history that is eligible for cleanup."
            }
        }

        var failure: String {
            switch self {
            case .recoverClock:
                "Clock recovery couldn’t finish. Check that your device time has been corrected backward."
            case .removeExpired:
                "Cleanup couldn’t finish. Check the device clock and try again."
            }
        }

        func outcome(_ count: Int) -> String {
            switch self {
            case .recoverClock: "Clock recovered. Earlier reports are in archived history."
            case .removeExpired: count == 0 ? "No expired reports were removed." : "Expired report history removed."
            }
        }
    }

    func performConfirmedMaintenance(_ action: Maintenance) async throws -> Int {
        let repository = try await ProductReportStorage.shared.repository()
        let count: Int
        switch action {
        case .recoverClock:
            count = try await repository.recoverClockAfterUserConfirmation(clock: { Self.now() })
        case .removeExpired:
            count = try await repository.reclaimExpiredReportsAfterUserConfirmation(clock: { Self.now() })
        }
        requestID = nil
        markerRequestID = nil
        loading = false
        mapEntries = []
        entries = []
        cursor = nil
        hasMore = false
        appendFailed = false
        error = nil
        return count
    }

    nonisolated static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    nonisolated static func current(_ report: StoredReport, at date: Date = .now) -> Bool {
        !report.isExpired && !report.isQuarantined && report.effectiveExpiresAt > Int64(date.timeIntervalSince1970 * 1_000)
    }
}

@MainActor
@Observable
final class ExploreReportDraft {
    struct Position {
        let point: MapPoint
        let accuracy: Int64
        let isGPS: Bool
    }

    var category: ReportCategory = .trail {
        didSet { if category != oldValue { status = category.statuses[0] } }
    }
    var status = ReportCategory.trail.statuses[0]
    var note = ""
    var position: Position?
    var publicConsent = false

    var canSave: Bool {
        position != nil && publicConsent && note.unicodeScalars.count <= 500 && note.utf8.count <= 2048
    }

    func submission() -> (draft: ReportDraft, point: MapPoint)? {
        guard canSave, let position else { return nil }
        let timestamp = ExploreReports.now()
        return (ReportDraft(category: category.rawValue, status: status,
            observedAt: timestamp, latitude: position.point.latE7, longitude: position.point.lonE7,
            accuracy: position.accuracy, note: note, expiresAt: timestamp + 24 * 60 * 60 * 1_000, maxHops: 4),
            position.point)
    }
}

enum ReportCategory: String, CaseIterable, Identifiable {
    case water, obstruction, trail, weather, campsite, hut, crowding, note
    var id: Self { self }
    var title: String {
        switch self {
        case .water: "Water"
        case .obstruction: "Obstruction"
        case .trail: "Trail condition"
        case .weather: "Weather"
        case .campsite: "Campsite"
        case .hut: "Hut"
        case .crowding: "Crowding"
        case .note: "Trail note"
        }
    }
    var statuses: [String] {
        switch self {
        case .water: ["flowing", "low", "dry", "unknown"]
        case .obstruction: ["clear", "partial", "blocked", "unknown"]
        case .trail: ["good", "muddy", "icy", "damaged", "blocked", "unknown"]
        case .weather: ["clear", "rain", "snow", "storm", "fog", "unknown"]
        case .campsite: ["available", "occupied", "closed", "unknown"]
        case .hut: ["open", "closed", "unknown"]
        case .crowding: ["quiet", "moderate", "busy", "unknown"]
        case .note: ["observed", "unknown"]
        }
    }

    static func title(for report: StoredReport) -> String {
        ReportCategory(rawValue: report.category)?.title ?? "Trail report"
    }
}

struct ExploreReportsList: View {
    let entries: ExploreReports
    let manifest: RegionManifest
    let compose: () -> Void
    let onMap: (StoredReport) -> Void
    let refreshMarkers: () -> Void

    @Environment(\.dismiss) private var dismiss
    #if TRAILMESH_DEVELOPMENT && targetEnvironment(simulator)
    @State private var expired = ["reports-expired-empty", "reports-expired"].contains(ScreenCapture.name ?? "")
    #else
    @State private var expired = false
    #endif

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List {
                    Picker("Reports", selection: $expired) {
                        Text("Recent").tag(false)
                        Text("Expired").tag(true)
                    }
                    .pickerStyle(.segmented)
                    let matching = entries.entries.filter { ExploreReports.current($0, at: context.date) != expired }
                    if let error = entries.error {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try again") {
                            Task { await entries.page(in: manifest, more: entries.appendFailed) }
                        }
                    } else if matching.isEmpty, !entries.loading {
                        Text(entries.hasMore ? "More reports are available to check."
                             : (expired ? "No expired reports in this view." : "No recent reports in this view."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(matching, id: \.bundleID) { report in
                        NavigationLink {
                            ExploreReportDetails(report: report, onMap: { onMap(report) })
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ReportCategory.title(for: report)).foregroundStyle(.primary)
                                    Text(report.status.capitalized).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(ExploreReportDetails.date(report.observedAt), style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                    if entries.loading { ProgressView("Loading reports…") }
                    if entries.hasMore, !entries.loading, !entries.appendFailed {
                        Button("Load more reports") { Task { await entries.page(in: manifest, more: true) } }
                    }
                    ExploreReportStorageActions(reports: entries) {
                        refreshMarkers()
                        await entries.page(in: manifest)
                    }
                }
                .refreshable { await entries.page(in: manifest) }
            }
            .navigationTitle("Trail reports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("New report", action: compose) }
            }
        }
    }

}

private struct ExploreReportStorageActions: View {
    let reports: ExploreReports
    let didChange: () async -> Void
    @State private var action: ExploreReports.Maintenance?
    @State private var showingConfirmation = false
    @State private var working = false
    @State private var notice: String?

    var body: some View {
        Section("Report storage") {
            Button("Recover after a clock change") { confirm(.recoverClock) }
                .disabled(working)
            Button("Remove expired reports") { confirm(.removeExpired) }
                .disabled(working)
            if working { ProgressView("Updating report storage…") }
            if let notice { Text(notice).foregroundStyle(.secondary) }
        }
        #if TRAILMESH_DEVELOPMENT && targetEnvironment(simulator)
        .onAppear {
            if ScreenCapture.name == "reports-clock-confirmation" { confirm(.recoverClock) }
            if ScreenCapture.name == "reports-cleanup-confirmation" { confirm(.removeExpired) }
        }
        #endif
        .confirmationDialog(action?.title ?? "Report storage", isPresented: $showingConfirmation,
                            titleVisibility: .visible, presenting: action) { selected in
            Button("Confirm", role: .destructive) {
                working = true
                notice = nil
                Task {
                    defer { working = false }
                    do {
                        let count = try await reports.performConfirmedMaintenance(selected)
                        await didChange()
                        notice = selected.outcome(count)
                    } catch {
                        notice = selected.failure
                    }
                }
            }
        } message: { selected in
            Text(selected.confirmation)
        }
    }

    private func confirm(_ selected: ExploreReports.Maintenance) {
        action = selected
        showingConfirmation = true
    }
}

struct ExploreReportDetails: View {
    let report: StoredReport
    var onMap: (() -> Void)?

    var body: some View {
        List {
            Section {
                Text(report.status.capitalized).font(.headline)
                if !report.note.isEmpty { Text(report.note) }
                if let onMap {
                    Button("Show on map", action: onMap).frame(minHeight: 44)
                }
            }
            Section("Timing") {
                if report.isQuarantined {
                    Text("Archived after a device clock correction.")
                } else if !ExploreReports.current(report) {
                    Text("This report has expired.")
                }
                LabeledContent("Observed", value: Self.date(report.observedAt).formatted())
                LabeledContent("Saved here", value: Self.date(report.admittedAt).formatted())
                LabeledContent("Expires", value: Self.date(report.effectiveExpiresAt).formatted())
                if report.effectiveExpiresAt != report.expiresAt {
                    LabeledContent("Signed expiry", value: Self.date(report.expiresAt).formatted())
                }
            }
            Section("Location and source") {
                LabeledContent("Reported accuracy", value: "\(report.accuracy.formatted()) m")
                Text("Signature checked. The trail conditions come from the reporter.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(ReportCategory.title(for: report))
        .navigationBarTitleDisplayMode(.inline)
    }

    static func date(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1_000)
    }
}

struct ExploreReportComposer: View {
    @Bindable var form: ExploreReportDraft
    let reports: ExploreReports
    let location: ExploreLocation
    let manifest: RegionManifest
    let pickPin: () -> Void
    let saved: (MapPoint) -> Void
    let refreshMarkers: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var waitingForLocation = false
    @State private var saving = false
    @State private var storageNeedsAttention = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Observation") {
                    Picker("Category", selection: $form.category) {
                        ForEach(ReportCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    Picker("Status", selection: $form.status) {
                        ForEach(form.category.statuses, id: \.self) { Text($0.capitalized) }
                    }
                    TextField("Notes (optional)", text: $form.note, axis: .vertical)
                        .lineLimit(2...5)
                    if form.note.unicodeScalars.count > 500 || form.note.utf8.count > 2048 {
                        Text("Shorten the note to 500 characters or fewer. Some characters use more space.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Report location") {
                    if let position = form.position {
                        LabeledContent(position.isGPS ? "Current location" : "Map pin",
                                       value: "About \(position.accuracy) m")
                    }
                    Button("Use current location", action: requestLocation)
                    Button("Choose on map", action: pickPin)
                    if waitingForLocation { ProgressView("Getting your location…") }
                    if let error { Text(error).foregroundStyle(.secondary) }
                }
                Section {
                    Toggle("I understand this report is public", isOn: $form.publicConsent)
                } footer: {
                    Text("Other hikers may receive this report and its location. It expires after 24 hours.")
                }
                Section {
                    Button(saving ? "Saving…" : "Save report", action: save)
                        .disabled(saving || waitingForLocation || !form.canSave)
                }
                if storageNeedsAttention {
                    ExploreReportStorageActions(reports: reports) {
                        error = nil
                        refreshMarkers()
                    }
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .navigationTitle("New report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            }
            #if TRAILMESH_DEVELOPMENT && targetEnvironment(simulator)
            .onAppear {
                switch ScreenCapture.name {
                case "report-location-pending": waitingForLocation = true
                case "report-location-denied": error = "Location access is off. Choose a point on the map."
                case "report-location-unavailable": error = "Couldn’t get a precise location. Try again or choose on the map."
                case "report-saving": saving = true
                case "report-storage-error":
                    error = "Report storage needs attention. Try again after checking the clock."
                    storageNeedsAttention = true
                default: break
                }
            }
            #endif
            .onDisappear {
                location.cancelFix(for: .composer)
            }
            .onChange(of: location.fix) { _, _ in
                if waitingForLocation, !saving, location.recentFix != nil { applyLocation() }
            }
            .onChange(of: location.issue) { _, issue in
                if waitingForLocation, let issue {
                    waitingForLocation = false
                    error = issue == .denied ? "Location access is off. Choose a point on the map." : "Couldn’t get a precise location. Try again or choose on the map."
                }
            }
        }
    }

    private func requestLocation() {
        error = nil
        if location.recentFix != nil { applyLocation() }
        else {
            waitingForLocation = true
            location.requestFix(for: .composer)
            if let issue = location.issue {
                waitingForLocation = false
                error = issue == .denied ? "Location access is off. Choose a point on the map." : "Couldn’t get your location."
            }
        }
    }

    private func applyLocation() {
        waitingForLocation = false
        guard let fix = location.recentFix, let point = MapPoint(coordinate: fix.coordinate) else {
            error = "Couldn’t get a precise location. Choose a point on the map."
            return
        }
        guard manifest.contains(point) else {
            error = "Your location is outside the downloaded map."
            return
        }
        form.position = .init(point: point, accuracy: Int64(ceil(fix.horizontalAccuracy)), isGPS: true)
    }

    private func save() {
        guard !saving, !waitingForLocation, let submission = form.submission() else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await reports.save(submission.draft)
                saved(submission.point)
            } catch ExploreReports.SaveFailure.storageLimit {
                storageNeedsAttention = true
                error = "Report storage is full. This report hasn’t been saved."
            } catch ReportStoreError.clock {
                storageNeedsAttention = true
                error = "Check your device date and time, then recover the report clock below."
            } catch {
                self.error = "The report couldn’t be saved. Check your device clock and try again."
            }
        }
    }
}
