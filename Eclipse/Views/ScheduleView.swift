//
//  ScheduleView.swift
//  Eclipse
//
//  Created by Soupy-dev
//

import SwiftUI
import Combine
import Kingfisher

struct ScheduleView: View {
    @AppStorage("showLocalScheduleTime") private var showLocalScheduleTime = true
    @AppStorage("defaultScheduleMode") private var defaultScheduleModeRaw = ScheduleMode.anime.rawValue
    @AppStorage(ScheduleWindow.storageKey) private var scheduleWindowDays = ScheduleWindow.defaultValue.rawValue
    @StateObject private var viewModel: ScheduleViewModel
    @StateObject private var accentColorManager = AccentColorManager.shared

    @ObservedObject private var contentFilter = TMDBContentFilter.shared
#if !os(tvOS)
    @StateObject private var notificationManager = LocalNotificationManager.shared
    @Environment(\.eclipseWindowSceneSessionIdentifier) private var windowSceneSessionIdentifier
    @Environment(\.scenePhase) private var scenePhase
#endif

    @State private var selectedTMDBResult: TMDBSearchResult?
    @State private var showingMediaDetail = false
    @State private var showNoTMDBAlert = false
    @State private var noTMDBAlertTitle = ""
    @State private var loadingItemId: String?

    @State private var kidsBlockedScheduleIds: Set<Int> = []

    @State private var resolvedKidsScheduleIds: Set<Int> = []

    @State private var kidsScheduleFilterGeneration = 0

    private func visibleToProfile(_ entries: [ScheduleEntry]) -> [ScheduleEntry] {
        guard ProfileManager.shared.isKidsModeActive else { return entries }
        return entries.filter { entry in

            guard let tmdbId = entry.tmdbId else { return false }

            guard resolvedKidsScheduleIds.contains(tmdbId) else { return false }
            return !kidsBlockedScheduleIds.contains(tmdbId)
        }
    }

    private func refreshKidsScheduleFilter(_ entries: [ScheduleEntry]) {
        kidsScheduleFilterGeneration &+= 1
        let generation = kidsScheduleFilterGeneration
        guard ProfileManager.shared.isKidsModeActive else {
            kidsBlockedScheduleIds = []
            resolvedKidsScheduleIds = []
            return
        }

        let titlesById: [Int: String] = entries.reduce(into: [:]) { titles, entry in
            guard let tmdbId = entry.tmdbId else { return }
            let variants = [entry.title, entry.englishTitle, entry.romajiTitle, entry.nativeTitle]
                .compactMap { $0 }
                .joined(separator: " ")
            titles[tmdbId, default: ""] += variants + " "
        }
        let ids = Set(titlesById.keys)
        Task { @MainActor in

            await TMDBMaturityRatingStore.shared.resolve(ids.map { (isMovie: false, id: $0) })

            guard generation == kidsScheduleFilterGeneration else { return }
            kidsBlockedScheduleIds = Set(
                ids.filter { id in
                    guard TMDBMaturityRatingStore.shared.isAllowedForKids(isMovie: false, id: id) else {
                        return true
                    }
                    guard TMDBContentFilter.kidsTextHeuristicsAllow(title: titlesById[id] ?? "") else {
                        return true
                    }

                    return TMDBMaturityRatingStore.shared.kidsDetailPolicyAllows(
                        isMovie: false,
                        id: id
                    ) != true
                }
            )
            resolvedKidsScheduleIds = ids
        }
    }
    @State private var selectedScheduleDate: Date?
    @State private var selectedScheduleMode: ScheduleMode
#if !os(tvOS)
    @State private var notificationNotice: LocalNotificationNotice?
    @State private var updatingNotificationEntryIDs = Set<String>()
    @State private var mediaDetailNotificationTarget: LocalNotificationNavigationTarget?
    @State private var isApplyingNotificationNavigation = false
#endif

    private let isActive: Bool
    private let dayChangeTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()
    private var scheduleWindow: ScheduleWindow {
        ScheduleWindow.sanitized(scheduleWindowDays)
    }
    private var scheduleLoadTaskID: String {
        "\(isActive ? "active" : "inactive")-\(selectedScheduleMode.rawValue)-\(scheduleWindow.rawValue)"
    }

    init(isActive: Bool = true) {
        self.isActive = isActive
        let savedMode = ProfileSettingsStore.active.string(forKey: "defaultScheduleMode")
        _selectedScheduleMode = State(initialValue: ScheduleMode.sanitized(savedMode))
        _viewModel = StateObject(wrappedValue: ScheduleViewModel.shared)
    }

    var body: some View {
#if os(tvOS)
        scheduleContent
#else
        if #available(iOS 16.0, *) {
            NavigationStack {
                scheduleContent
            }
        } else {
            NavigationView {
                scheduleContent
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
#endif
    }

    private var scheduleContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SettingsGradientBackground().ignoresSafeArea()

            mainScheduleView
        }
#if os(tvOS)

        .navigationTitle("")
#else
        .navigationTitle("Schedule")
#endif
        .task(id: scheduleLoadTaskID) {
            guard isActive else { return }
            guard viewModel.scheduleEntries.isEmpty
                    || viewModel.loadedScheduleMode != selectedScheduleMode
                    || viewModel.loadedScheduleDayCount != scheduleWindow.rawValue
                    || viewModel.errorMessage != nil else { return }
            await viewModel.loadSchedule(mode: selectedScheduleMode, localTimeZone: showLocalScheduleTime)
        }
        .refreshable {
            await viewModel.loadSchedule(mode: selectedScheduleMode, localTimeZone: showLocalScheduleTime, forceRefresh: true)
        }
        .onChangeComp(of: viewModel.scheduleEntriesRevision) { _, _ in
            refreshKidsScheduleFilter(viewModel.scheduleEntries)
        }

        .onAppear {
            refreshKidsScheduleFilter(viewModel.scheduleEntries)
        }
        .onChangeComp(of: contentFilter.isKidsProfileActive) { _, _ in
            refreshKidsScheduleFilter(viewModel.scheduleEntries)
        }
        .onChangeComp(of: contentFilter.maturityRatingRevision) { _, _ in
            refreshKidsScheduleFilter(viewModel.scheduleEntries)
        }

        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            refreshKidsScheduleFilter(viewModel.scheduleEntries)
        }
        .onChangeComp(of: selectedScheduleMode) { _, _ in
#if !os(tvOS)
            guard !isApplyingNotificationNavigation else { return }
#endif
            selectedScheduleDate = nil
        }
        .onChangeComp(of: scheduleWindowDays) { _, newValue in
            let sanitized = ScheduleWindow.sanitizedDays(newValue)
            if sanitized != newValue {
                scheduleWindowDays = sanitized
            }
            selectedScheduleDate = nil
        }
        .onChangeComp(of: isActive) { _, active in
            guard active else { return }
#if !os(tvOS)
            if scenePhase == .active,
               notificationManager.shouldHandlePendingNavigation(
                inSceneSessionIdentifier: windowSceneSessionIdentifier
            ) {
                Task { await applyPendingNotificationNavigationIfNeeded() }
                return
            }
#endif
            let defaultMode = ScheduleMode.sanitized(defaultScheduleModeRaw)
            if selectedScheduleMode != defaultMode {
                selectedScheduleMode = defaultMode
            }
        }
        .onChangeComp(of: showLocalScheduleTime) { _, newValue in
            viewModel.regroupBuckets(localTimeZone: newValue)
        }
        .onReceive(dayChangeTimer) { _ in
            guard isActive else { return }
            Task {
                await viewModel.handleDayChangeIfNeeded(mode: selectedScheduleMode, localTimeZone: showLocalScheduleTime)
            }
        }
#if !os(tvOS)
        .onAppear {
            guard isActive, scenePhase == .active else { return }
            Task { await applyPendingNotificationNavigationIfNeeded() }
        }
        .onChangeComp(of: windowSceneSessionIdentifier) { _, _ in
            guard isActive, scenePhase == .active else { return }
            Task { await applyPendingNotificationNavigationIfNeeded() }
        }
        .onChangeComp(of: scenePhase) { _, phase in
            guard isActive, phase == .active else { return }
            Task { await applyPendingNotificationNavigationIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openScheduleFromLocalNotification)) { _ in
            guard isActive, scenePhase == .active else { return }
            Task { await applyPendingNotificationNavigationIfNeeded() }
        }
#endif
        .background(
            Group {
                if #available(iOS 16.0, *) {
                    Color.clear
                        .navigationDestination(isPresented: $showingMediaDetail) {
                            if let result = selectedTMDBResult {
#if os(tvOS)
                                MediaDetailView(searchResult: result)
#else
                                MediaDetailView(
                                    searchResult: result,
                                    initialNotificationSelection: mediaDetailNotificationTarget.map(
                                        MediaDetailInitialNotificationSelection.init
                                    )
                                )
                                .id(mediaDetailNotificationTarget?.id ?? "schedule-detail-\(result.id)")
#endif
                            }
                        }
                } else {
                    NavigationLink(
                        isActive: $showingMediaDetail,
                        destination: {
                            if let result = selectedTMDBResult {
#if os(tvOS)
                                MediaDetailView(searchResult: result)
#else
                                MediaDetailView(
                                    searchResult: result,
                                    initialNotificationSelection: mediaDetailNotificationTarget.map(
                                        MediaDetailInitialNotificationSelection.init
                                    )
                                )
                                .id(mediaDetailNotificationTarget?.id ?? "schedule-detail-\(result.id)")
#endif
                            }
                        },
                        label: { EmptyView() }
                    )
                }
            }
        )
        .alert(isPresented: $showNoTMDBAlert) {
            Alert(
                title: Text("No TMDB Entry"),
                message: Text("\"\(noTMDBAlertTitle)\" does not have a TMDB entry and cannot be opened."),
                dismissButton: .default(Text("OK"))
            )
        }
#if !os(tvOS)
        .alert(item: $notificationNotice) { notice in
            if notice.offersSettings {
                return Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    primaryButton: .default(Text("Open Settings")) {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    },
                    secondaryButton: .cancel()
                )
            }
            return Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
#endif
    }

#if !os(tvOS)
    @MainActor
    private func applyPendingNotificationNavigationIfNeeded() async {
        guard isActive, scenePhase == .active, !isApplyingNotificationNavigation,
              let target = notificationManager.takePendingNavigationTarget(
                forSceneSessionIdentifier: windowSceneSessionIdentifier
              ) else { return }

        isApplyingNotificationNavigation = true
        defer {
            isApplyingNotificationNavigation = false
            if scenePhase == .active,
               notificationManager.shouldHandlePendingNavigation(
                inSceneSessionIdentifier: windowSceneSessionIdentifier
            ) {
                Task { await applyPendingNotificationNavigationIfNeeded() }
            }
        }

        let targetMode: ScheduleMode?
        switch target.source {
        case .anime?: targetMode = .anime
        case .western?: targetMode = .western
        case nil: targetMode = nil
        }

        if let targetMode, selectedScheduleMode != targetMode {
            selectedScheduleMode = targetMode
            await Task.yield()
        }
        if let airingAt = target.airingAt {
            selectedScheduleDate = scheduleCalendar.startOfDay(for: airingAt)
        }

        if let tmdbID = target.tmdbID,
           tmdbID > 0,
           target.tmdbMediaType != nil || target.source != .anime {
            presentNotificationMediaDetail(
                result: notificationSearchResult(
                    tmdbID: tmdbID,
                    mediaType: target.tmdbMediaType ?? .tv,
                    title: target.mediaTitle
                ),
                target: target
            )
            return
        }

        guard let targetMode else { return }
        await viewModel.loadSchedule(mode: targetMode, localTimeZone: showLocalScheduleTime)
        let targetSource: ScheduleSource = targetMode == .anime ? .anime : .western
        let snapshot = await viewModel.notificationScheduleSnapshot(
            dayCount: scheduleWindow.rawValue,
            requiredSources: [targetSource]
        )
        guard let entry = bestScheduleEntry(for: target, entries: snapshot.entries) else { return }

        if let result = await viewModel.lookupTMDBResult(for: entry) {
            presentNotificationMediaDetail(result: result, target: target)
        }
    }

    @MainActor
    private func presentNotificationMediaDetail(
        result: TMDBSearchResult,
        target: LocalNotificationNavigationTarget
    ) {
        selectedTMDBResult = result
        mediaDetailNotificationTarget = target
        if !showingMediaDetail {
            showingMediaDetail = true
        }
    }

    private func notificationSearchResult(
        tmdbID: Int,
        mediaType: LocalNotificationTMDBMediaType,
        title: String
    ) -> TMDBSearchResult {
        TMDBSearchResult(
            id: tmdbID,
            mediaType: mediaType.rawValue,
            title: mediaType == .movie && !title.isEmpty ? title : nil,
            name: mediaType == .tv && !title.isEmpty ? title : nil,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            firstAirDate: nil,
            voteAverage: nil,
            popularity: 0,
            adult: nil,
            genreIds: nil
        )
    }

    private func bestScheduleEntry(
        for target: LocalNotificationNavigationTarget,
        entries: [ScheduleEntry]
    ) -> ScheduleEntry? {
        let expectedSource: ScheduleSource?
        switch target.source {
        case .anime?: expectedSource = .anime
        case .western?: expectedSource = .western
        case nil: expectedSource = nil
        }

        let normalizedTargetTitle = normalizedNotificationTitle(target.mediaTitle)
        let candidates = entries.filter { entry in
            if let expectedSource, entry.source != expectedSource { return false }
            if let sourceMediaID = target.sourceMediaID,
               sourceMediaID != entry.sourceMediaId { return false }
            if let episodeNumber = target.episodeNumber,
               episodeNumber != entry.episode { return false }
            if let seasonNumber = target.seasonNumber,
               let entrySeason = entry.season,
               seasonNumber != entrySeason { return false }
            if target.sourceMediaID == nil, !normalizedTargetTitle.isEmpty {
                let entryTitles = [entry.title, entry.englishTitle, entry.romajiTitle]
                    .compactMap { $0 }
                    .map(normalizedNotificationTitle)
                if !entryTitles.contains(normalizedTargetTitle) { return false }
            }
            return true
        }

        return candidates.min { lhs, rhs in
            guard let targetDate = target.airingAt else { return lhs.airingAt < rhs.airingAt }
            return abs(lhs.airingAt.timeIntervalSince(targetDate))
                < abs(rhs.airingAt.timeIntervalSince(targetDate))
        }
    }

    private func normalizedNotificationTitle(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "", options: .regularExpression)
    }
#endif

    private var loadingView: some View {
        VStack(spacing: 16) {
            EclipseLoadingIndicator()
                .scaleEffect(1.2)
            Text("Loading \(selectedScheduleMode.displayName.lowercased()) schedule...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        EclipseEmptyState(
            icon: "exclamationmark.triangle",
            title: "Couldn't Load Schedule",
            message: message,
            actionTitle: "Retry",
            action: {
                Task {
                    await viewModel.loadSchedule(mode: selectedScheduleMode, localTimeZone: showLocalScheduleTime, forceRefresh: true)
                }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        EclipseEmptyState(
            icon: "calendar",
            title: "No Upcoming Episodes",
            message: "No \(selectedScheduleMode.displayName.lowercased()) episodes scheduled in the next \(scheduleWindow.rawValue) days."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var mainScheduleView: some View {
#if os(tvOS)
        tvScheduleView
#else
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                scheduleModePickerSection

                timeZoneToggleSection
                if viewModel.isLoading {
                    loadingView
                        .frame(minHeight: 360)
                } else if let errorMessage = viewModel.errorMessage {
                    errorView(errorMessage)
                        .frame(minHeight: 360)
                } else if viewModel.dayBuckets.allSatisfy({ $0.items.isEmpty }) {
                    emptyStateView
                        .frame(minHeight: 360)
                } else {
                    dayPickerSection
                    selectedDaySection
                }
            }
            .padding(.top)
            .padding(.bottom, 100)
        }
#endif
    }

#if os(tvOS)

    private var tvScheduleView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                tvScheduleHeader

                if viewModel.isLoading {
                    loadingView
                        .frame(minHeight: 520)
                } else if let errorMessage = viewModel.errorMessage {
                    errorView(errorMessage)
                        .frame(minHeight: 520)
                } else if viewModel.dayBuckets.allSatisfy({ visibleToProfile($0.items).isEmpty }) {
                    emptyStateView
                        .frame(minHeight: 520)
                } else {
                    tvDayPickerSection
                    tvSelectedDaySection
                }
            }
            .padding(.horizontal, 74)
            .padding(.top, 10)
            .padding(.bottom, 90)
        }
        .scrollClipDisabled()
    }

    private var tvScheduleHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text("Schedule")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("See what’s airing next")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.62))
            }

            HStack(spacing: 20) {
                HStack(spacing: 20) {
                    ForEach(ScheduleMode.allCases) { mode in
                        Button {
                            selectedScheduleMode = mode
                        } label: {
                            Text(mode.displayName)
                                .font(.system(size: 27, weight: .semibold))
                                .foregroundColor(selectedScheduleMode == mode ? .black : .white)
                                .frame(width: 176)
                                .frame(height: 62)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(
                                            selectedScheduleMode == mode
                                                ? accentColorManager.currentAccentColor
                                                : Color.white.opacity(0.10)
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                                )
                        }
                        .buttonStyle(TVMediaCardButtonStyle())
                        .accessibilityIdentifier("schedule.mode.\(mode.rawValue)")
                    }
                }

                Spacer(minLength: 30)

                Label(
                    showLocalScheduleTime ? "Times shown locally" : "Times shown in UTC",
                    systemImage: "clock"
                )
                .font(.headline)
                .foregroundColor(.white.opacity(0.72))

                HStack(spacing: 14) {
                    tvTimeZoneButton(title: "Local", usesLocalTime: true)
                    tvTimeZoneButton(title: "UTC", usesLocalTime: false)
                }

                tvRefreshButton
            }

            .padding(.vertical, 14)
            .focusSection()
        }
    }

    private var tvRefreshButton: some View {
        Button {
            guard !viewModel.isLoading else { return }
            Task {
                await viewModel.loadSchedule(mode: selectedScheduleMode, localTimeZone: showLocalScheduleTime, forceRefresh: true)
            }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
                .font(.headline.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(TVMediaCardButtonStyle())
        .accessibilityIdentifier("schedule.refresh")
    }

    private var tvDayPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("Choose a day")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.white)

                Text("\(scheduleWindow.rawValue)-day window")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.55))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 18) {
                    ForEach(viewModel.dayBuckets) { bucket in
                        tvDayChip(bucket)
                    }
                }

                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
            .scrollClipDisabled()
            .focusSection()
            .padding(.horizontal, -18)
        }
    }

    private func tvTimeZoneButton(title: String, usesLocalTime: Bool) -> some View {
        let selected = showLocalScheduleTime == usesLocalTime
        return Button {
            showLocalScheduleTime = usesLocalTime
        } label: {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundColor(selected ? .black : .white)
                .frame(width: 104, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(selected ? accentColorManager.currentAccentColor : Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(TVMediaCardButtonStyle())
        .accessibilityIdentifier("schedule.timezone.\(usesLocalTime ? "local" : "utc")")
    }

    private func tvDayChip(_ bucket: DayBucket) -> some View {
        let selected = selectedBucket.map {
            scheduleCalendar.isDate($0.date, inSameDayAs: bucket.date)
        } ?? false
        let isToday = scheduleCalendar.isDate(bucket.date, inSameDayAs: Date())
        let count = visibleToProfile(bucket.items).count

        return Button {
            selectedScheduleDate = bucket.date
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(shortDay(bucket.date))
                        .font(.system(size: 23, weight: .semibold))

                    Spacer(minLength: 4)

                    Text(dayNumber(bucket.date))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                }

                Text(count == 1 ? "1 airing" : "\(count) airing")
                    .font(.system(size: 22, weight: .medium))
                    .opacity(0.72)
            }
            .foregroundColor(selected ? .black : .white)
            .padding(.horizontal, 18)
            .frame(width: 212, height: 104)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selected ? accentColorManager.currentAccentColor : Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isToday && !selected
                            ? accentColorManager.currentAccentColor.opacity(0.85)
                            : Color.white.opacity(0.12),
                        lineWidth: isToday && !selected ? 3 : 1
                    )
            )
        }
        .buttonStyle(TVMediaCardButtonStyle())
        .accessibilityIdentifier("schedule.day.\(Int(bucket.date.timeIntervalSince1970))")
    }

    private var tvSelectedDaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let bucket = selectedBucket {
                let items = visibleToProfile(bucket.items)

                HStack(alignment: .firstTextBaseline) {
                    Text(formattedDay(bucket.date))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text(items.count == 1 ? "1 episode" : "\(items.count) episodes")
                        .font(.title3.weight(.medium))
                        .foregroundColor(.white.opacity(0.52))

                    Spacer()
                }

                if items.isEmpty {
                    Text("No episodes scheduled")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                        .background(EclipseTheme.shared.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 30) {
                            ForEach(items) { item in
                                tvScheduleItemCard(item: item)
                            }
                        }

                        .padding(.horizontal, 22)
                        .padding(.vertical, 24)
                    }
                    .scrollClipDisabled()
                    .focusSection()
                    .padding(.horizontal, -22)
                }
            }
        }
    }

    private func tvScheduleItemCard(item: ScheduleEntry) -> some View {
        Button {
            openScheduleItem(item)
        } label: {
            tvScheduleItemContent(item: item)
        }
        .buttonStyle(TVMediaCardButtonStyle())
        .opacity(loadingItemId == item.id ? 0.55 : 1)
        .overlay {
            if loadingItemId == item.id {
                EclipseLoadingIndicator()
                    .tint(.white)
            }
        }
        .accessibilityIdentifier("schedule.episode.\(item.id)")
    }

    private func tvScheduleItemContent(item: ScheduleEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            tvScheduleArtwork(item: item)

            Text(item.title)
                .font(.title3.weight(.semibold))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(width: 240, alignment: .leading)
                .frame(minHeight: 58, alignment: .topLeading)

            tvScheduleMetadata(item: item)
        }
        .padding(12)
        .background(tvScheduleCardBackground)
        .overlay(tvScheduleCardBorder)
    }

    private func tvScheduleArtwork(item: ScheduleEntry) -> some View {
        let timeIcon = item.isStreamingRelease ? "play.circle.fill" : "clock.fill"
        let timeLabel = formattedTime(for: item)

        return ZStack(alignment: .bottomLeading) {
            schedulePoster(
                urlString: item.coverImage,
                width: 240,
                height: 342,
                cornerRadius: 18
            )

            LinearGradient(
                colors: [.clear, .black.opacity(0.82)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(width: 240, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Label(timeLabel, systemImage: timeIcon)
                .font(.headline.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
        }
    }

    private func tvScheduleMetadata(item: ScheduleEntry) -> some View {
        HStack(spacing: 8) {
            formatTypeBadge(for: item)

            Text(episodeOnlyLabel(for: item))
                .font(.body.weight(.medium))
                .foregroundColor(.white.opacity(0.72))

            Spacer(minLength: 4)

            if let countdown = countdownLabel(for: item) {
                Text(countdown)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(accentColorManager.currentAccentColor)
            }
        }
        .frame(width: 240)
    }

    private var tvScheduleCardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Color.white.opacity(0.07))
    }

    private var tvScheduleCardBorder: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
    }
#endif

    private var selectedBucket: DayBucket? {
        let calendar = scheduleCalendar
        if let selectedScheduleDate,
           let bucket = viewModel.dayBuckets.first(where: { calendar.isDate($0.date, inSameDayAs: selectedScheduleDate) }) {
            return bucket
        }
        return viewModel.dayBuckets.first(where: { !$0.items.isEmpty }) ?? viewModel.dayBuckets.first
    }

    private var scheduleModePickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Schedule")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

#if os(tvOS)
            HStack(spacing: 12) {
                ForEach(ScheduleMode.allCases) { mode in
                    Button {
                        selectedScheduleMode = mode
                    } label: {
                        Text(mode.displayName)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(
                                        selectedScheduleMode == mode
                                            ? accentColorManager.currentAccentColor.opacity(0.8)
                                            : Color.white.opacity(0.07)
                                    )
                            )
                    }
                    .buttonStyle(TVMediaCardButtonStyle())
                }
            }
#else
            Picker("Schedule", selection: $selectedScheduleMode) {
                ForEach(ScheduleMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
#endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(EclipseTheme.shared.cardBackground)
        .cornerRadius(10)
        .padding(.horizontal)
    }

    private var timeZoneToggleSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.headline)
                .foregroundColor(accentColorManager.currentAccentColor)
                .frame(width: 28, height: 28)

            Text(showLocalScheduleTime ? "Local time" : "UTC")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)

            Spacer()

            Picker("Timezone", selection: $showLocalScheduleTime) {
                Text("Local").tag(true)
                Text("UTC").tag(false)
            }
            .pickerStyle(.segmented)
#if os(tvOS)
            .frame(width: 280)
#else
            .frame(width: 150)
#endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(EclipseTheme.shared.cardBackground)
        .cornerRadius(10)
        .padding(.horizontal)
    }

    private var dayPickerSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.dayBuckets) { bucket in
                    dayChip(bucket)
                }
            }
            .padding(.horizontal)
        }
    }

    private func dayChip(_ bucket: DayBucket) -> some View {
        let selected = selectedBucket.map { scheduleCalendar.isDate($0.date, inSameDayAs: bucket.date) } ?? false
        let isToday = scheduleCalendar.isDate(bucket.date, inSameDayAs: Date())

        return Button {
            selectedScheduleDate = bucket.date
        } label: {
            VStack(spacing: 4) {
                Text(shortDay(bucket.date))
                    .font(.caption.weight(.semibold))

                Text(dayNumber(bucket.date))
                    .font(.system(size: 20, weight: .bold))

                Text("\(visibleToProfile(bucket.items).count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(selected ? .black.opacity(0.65) : .white.opacity(0.5))
            }
            .foregroundColor(selected ? .black : .white)
#if os(tvOS)
            .frame(width: 112, height: 96)
#else
            .frame(width: 64, height: 80)
#endif
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? accentColorManager.currentAccentColor : Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isToday && !selected ? accentColorManager.currentAccentColor.opacity(0.6) : Color.white.opacity(0.08),
                        lineWidth: 1
                    )
            )
        }
#if os(tvOS)
        .buttonStyle(TVMediaCardButtonStyle())
#else
        .buttonStyle(.plain)
#endif
    }

    private var selectedDaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let bucket = selectedBucket {
                HStack {
                    Text(formattedDay(bucket.date))
                        .font(.title3.weight(.bold))
                        .foregroundColor(.white)

                    Spacer()

                    Text("\(visibleToProfile(bucket.items).count) airing")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                if visibleToProfile(bucket.items).isEmpty {
                    Text("No episodes scheduled")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(EclipseTheme.shared.cardBackground)
                        .cornerRadius(10)
                        .padding(.horizontal)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(visibleToProfile(bucket.items)) { item in
                            scheduleItemCard(item: item)
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                EmptyView()
            }
        }
    }

    private func scheduleItemCard(item: ScheduleEntry) -> some View {
        HStack(spacing: 4) {
            Button {
                openScheduleItem(item)
            } label: {
                compactScheduleItemContent(item: item)
            }
#if os(tvOS)
            .buttonStyle(TVMediaCardButtonStyle())
#else
            .buttonStyle(.plain)
#endif
            .opacity(loadingItemId == item.id ? 0.6 : 1.0)
            .overlay {
                if loadingItemId == item.id {
                    EclipseLoadingIndicator()
                        .tint(.white)
                }
            }
            .disabled(loadingItemId != nil)

#if !os(tvOS)
            scheduleNotificationButton(for: item)
#endif
        }
        .padding(12)
        .glassCard(cornerRadius: EclipseRadius.card)
        .animation(.easeInOut(duration: 0.2), value: loadingItemId)
    }

    private func openScheduleItem(_ item: ScheduleEntry) {
        guard loadingItemId == nil else { return }
#if !os(tvOS)
        mediaDetailNotificationTarget = nil
#endif
        loadingItemId = item.id
        Task {
            let result = await viewModel.lookupTMDBResult(for: item)
            await MainActor.run {
                loadingItemId = nil
                if let result {
                    selectedTMDBResult = result
                    showingMediaDetail = true
                } else {
                    noTMDBAlertTitle = item.title
                    showNoTMDBAlert = true
                }
            }
        }
    }

    private func compactScheduleItemContent(item: ScheduleEntry) -> some View {
        HStack(spacing: 12) {
            schedulePoster(urlString: item.coverImage)

            VStack(alignment: .leading, spacing: 7) {
                Text(item.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    formatTypeBadge(for: item)
                    Text(episodeOnlyLabel(for: item))
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: item.isStreamingRelease ? "play.circle.fill" : "clock")
                        .font(.system(size: 11, weight: .semibold))
                    Text(formattedTime(for: item))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .fixedSize(horizontal: true, vertical: false)

                if let countdown = countdownLabel(for: item) {
                    Text(countdown)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

#if !os(tvOS)
    @ViewBuilder
    private func scheduleNotificationButton(for item: ScheduleEntry) -> some View {
        let state = notificationManager.episodeState(for: item)
        if state != .unavailable {
            Button {
                guard updatingNotificationEntryIDs.insert(item.id).inserted else { return }
                Task {
                    let result = await notificationManager.toggleEpisodeReminder(for: item)
                    notificationNotice = LocalNotificationNotice.from(result)
                    updatingNotificationEntryIDs.remove(item.id)
                    if result == .enabled,
                       notificationManager.episodeState(for: item) == .explicit,
                       item.tmdbId == nil {
                        Task(priority: .utility) {
                            guard let resolved = await viewModel.lookupTMDBResult(for: item) else { return }
                            await notificationManager.enrichEpisodeReminderTMDBIdentity(
                                for: item,
                                result: resolved
                            )
                        }
                    }
                }
            } label: {
                ZStack {
                    if updatingNotificationEntryIDs.contains(item.id) {
                        ProgressView()
                            .tint(notificationColor(for: state))
                    } else {
                        Image(systemName: notificationIcon(for: state))
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(notificationColor(for: state))
                    }
                }
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.07), in: Circle())
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(updatingNotificationEntryIDs.contains(item.id))
            .accessibilityLabel(notificationAccessibilityLabel(for: item, state: state))
            .accessibilityHint(state == .followed ? "Mutes this episode without unfollowing the show." : "Updates the local reminder for this episode.")
        }
    }

    private func notificationIcon(for state: LocalEpisodeNotificationState) -> String {
        switch state {
        case .explicit, .followed: return "bell.fill"
        case .muted: return "bell.slash"
        case .off, .unavailable: return "bell"
        }
    }

    private func notificationColor(for state: LocalEpisodeNotificationState) -> Color {
        switch state {
        case .explicit, .followed: return accentColorManager.currentAccentColor
        case .muted: return .white.opacity(0.38)
        case .off, .unavailable: return .white.opacity(0.70)
        }
    }

    private func notificationAccessibilityLabel(
        for item: ScheduleEntry,
        state: LocalEpisodeNotificationState
    ) -> String {
        let episode = item.episode > 0 ? "episode \(item.episode)" : "this episode"
        switch state {
        case .explicit: return "Remove reminder for \(episode) of \(item.title)"
        case .followed: return "Mute \(episode) of \(item.title)"
        case .muted: return "Restore reminder for \(episode) of \(item.title)"
        case .off, .unavailable: return "Notify when \(episode) of \(item.title) airs"
        }
    }
#endif

    @ViewBuilder
    private func schedulePoster(
        urlString: String?,
        width: CGFloat = 58 * iPadScaleSmall,
        height: CGFloat = 84 * iPadScaleSmall,
        cornerRadius: CGFloat = 10
    ) -> some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                KFImage(url)
                    .resizable()
                    .placeholder {
                        Rectangle().fill(Color.white.opacity(0.08))
                    }
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .overlay(Image(systemName: "tv").foregroundColor(.white.opacity(0.4)))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func episodeOnlyLabel(for item: ScheduleEntry) -> String {
        if item.source != .anime {
            if let season = item.season, item.episode > 0 {
                return "S\(season) · Ep \(item.episode)"
            }
            return item.episode > 0 ? "Ep \(item.episode)" : "New episode"
        }
        return item.episode > 0 ? "Ep \(item.episode)" : "New"
    }

    @ViewBuilder
    private func formatTypeBadge(for item: ScheduleEntry) -> some View {
        if item.source == .anime,
           let raw = item.format?.uppercased(),
           ["MOVIE", "OVA", "ONA", "SPECIAL", "MUSIC"].contains(raw) {
            let label: String = {
                switch raw {
                case "MOVIE": return "Movie"
                case "OVA": return "OVA"
                case "ONA": return "ONA"
                case "SPECIAL": return "Special"
                case "MUSIC": return "Music"
                default: return raw.capitalized
                }
            }()
            EclipseStatusBadge(text: label, tint: formatTint(raw))
        }
    }

    private func formatTint(_ raw: String) -> Color {
        switch raw {
        case "MOVIE": return Color(red: 0.85, green: 0.42, blue: 0.22)
        case "OVA", "ONA": return Color(red: 0.38, green: 0.50, blue: 0.86)
        case "SPECIAL": return Color(red: 0.68, green: 0.40, blue: 0.80)
        case "MUSIC": return Color(red: 0.20, green: 0.70, blue: 0.58)
        default: return .gray
        }
    }

    private func countdownLabel(for item: ScheduleEntry) -> String? {
        guard item.hasKnownAiringTime else { return nil }
        let interval = item.airingAt.timeIntervalSinceNow
        if interval <= 0 { return "Aired" }
        let hours = Int(interval / 3600)
        if hours < 1 {
            let minutes = max(1, Int(interval / 60))
            return "in \(minutes)m"
        }
        if hours < 24 { return "in \(hours)h" }
        return "in \(hours / 24)d"
    }

    private var scheduleCalendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = showLocalScheduleTime ? .current : TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func shortDay(_ date: Date) -> String {
        let calendar = scheduleCalendar
        let today = calendar.startOfDay(for: Date())
        let compareDate = calendar.startOfDay(for: date)
        if compareDate == today {
            return "Today"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), compareDate == tomorrow {
            return "Tmrw"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    private func dayNumber(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        formatter.timeZone = scheduleCalendar.timeZone
        return formatter.string(from: date)
    }

    private func formattedDay(_ date: Date) -> String {
        let calendar = scheduleCalendar
        let today = calendar.startOfDay(for: Date())
        let compareDate = calendar.startOfDay(for: date)

        if compareDate == today {
            return "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), compareDate == tomorrow {
            return "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMM d"
            formatter.timeZone = showLocalScheduleTime ? .current : TimeZone(secondsFromGMT: 0)
            return formatter.string(from: date)
        }
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        formatter.timeZone = showLocalScheduleTime ? .current : TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func formattedTime(for item: ScheduleEntry) -> String {
        if item.hasKnownAiringTime {
            return formattedTime(item.airingAt)
        }
        if item.isStreamingRelease {
            return "Streaming"
        }
        return "Time TBA"
    }
}
