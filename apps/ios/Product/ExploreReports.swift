import CoreLocation
import Foundation
import Observation
import SwiftUI
import TrailMeshMaps
import TrailMeshReports

/// The map UI and the existing diagnostics use one repository and signing identity.
actor ProductReportStorage {
    static let shared = ProductReportStorage()
    private var opening: Task<ReportRepository, Error>?
    private var signing: Task<ReportIdentity, Error>?

    func repository() async throws -> ReportRepository {
        if let opening { return try await opening.value }
        let task = Task.detached {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
                .appendingPathComponent("TrailMeshReports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            return try await ReportRepository.open(path: directory.appendingPathComponent("reports.sqlite").path)
        }
        opening = task
        do { return try await task.value }
        catch { opening = nil; throw error }
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
    private(set) var hasMore = false
    private(set) var loading = false
    private(set) var error: String?
    private var cursor: ReportPageCursor?
    private var requestID: UUID?

    func page(in manifest: RegionManifest, more: Bool = false) async {
        if more, loading || !hasMore { return }
        let id = UUID()
        requestID = id
        loading = true
        error = nil
        defer { if requestID == id { loading = false } }
        do {
            let repository = try await ProductReportStorage.shared.repository()
            let bounds = manifest.boundsE7
            let page = try await repository.reportPage(clock: { Self.now() }, bounds: ReportBounds(
                south: bounds[1], north: bounds[3], west: bounds[0], east: bounds[2]
            ), includeExpired: true, after: more ? cursor : nil, limit: 32)
            try Task.checkCancellation()
            guard requestID == id else { return }
            cursor = page.nextCursor
            hasMore = page.hasMore
            if more {
                let knownIDs = Set(entries.map(\.bundleID))
                entries += page.reports.filter { !knownIDs.contains($0.bundleID) }
            } else {
                entries = page.reports
            }
        } catch is CancellationError {
            return
        } catch {
            guard requestID == id else { return }
            self.error = "Reports couldn’t open. Check your device clock and try again."
            entries = []
            cursor = nil
            hasMore = false
        }
    }

    func save(_ form: ExploreReportDraft) async throws {
        let repository = try await ProductReportStorage.shared.repository()
        let identity = try await ProductReportStorage.shared.identity()
        guard let position = form.position, form.canSave else { throw SaveFailure.invalid }
        let timestamp = Self.now()
        let draft = ReportDraft(category: form.category.rawValue, status: form.status,
            observedAt: timestamp, latitude: position.point.latE7, longitude: position.point.lonE7,
            accuracy: position.accuracy, note: form.note, expiresAt: timestamp + 24 * 60 * 60 * 1_000, maxHops: 4)
        let outcome = try await repository.author(draft, identity: identity, clock: { Self.now() })
        switch outcome {
        case .stored: break
        case .rejected(.quota): throw SaveFailure.storageLimit
        default: throw SaveFailure.invalid
        }
    }

    enum SaveFailure: Error { case invalid, storageLimit }

    nonisolated static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    nonisolated static func current(_ report: StoredReport, at date: Date = .now) -> Bool {
        !report.isExpired && !report.isQuarantined && report.expiresAt > Int64(date.timeIntervalSince1970 * 1_000)
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

    @Environment(\.dismiss) private var dismiss
    @State private var expired = false

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
                        Button("Try again") { refresh() }
                    } else if matching.isEmpty, !entries.loading {
                        Text(expired ? "No expired reports in this view." : "No recent reports in this view.")
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
                    if entries.hasMore, !entries.loading {
                        Button("Load more reports") { Task { await entries.page(in: manifest, more: true) } }
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

    private func refresh() {
        Task { await entries.page(in: manifest) }
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
                LabeledContent("Expires", value: Self.date(report.expiresAt).formatted())
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
    let saved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var waitingForLocation = false
    @State private var saving = false
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
                        .disabled(saving || !form.canSave)
                }
            }
            .disabled(saving)
            .interactiveDismissDisabled(saving)
            .navigationTitle("New report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            }
            .onChange(of: location.fix) { _, _ in
                if waitingForLocation { applyLocation() }
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
            location.requestFix()
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
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await reports.save(form)
                saved()
            } catch ExploreReports.SaveFailure.storageLimit {
                error = "Report storage is full. This report hasn’t been saved."
            } catch {
                error = "The report couldn’t be saved. Check your device clock and try again."
            }
        }
    }
}
