import SwiftUI
import Combine
import Kingfisher

struct ScheduleView: View {
    @AppStorage("showLocalScheduleTime") private var showLocalScheduleTime = true
    @AppStorage("defaultScheduleMode") private var defaultScheduleModeRaw = ScheduleMode.anime.rawValue
    @StateObject private var viewModel: ScheduleViewModel
    @StateObject private var accentColorManager = AccentColorManager.shared
    
    @State private var selectedTMDBResult: TMDBSearchResult?
    @State private var showingMediaDetail = false
    @State private var showNoTMDBAlert = false
    @State private var noTMDBAlertTitle = ""
    @State private var loadingItemId: String?
    @State private var selectedScheduleDate: Date?
    @State private var selectedScheduleMode: ScheduleMode
    
    private let isActive: Bool
    private let dayChangeTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()
    private var scheduleLoadTaskID: String {
        "\(isActive ? "active" : "inactive")-\(selectedScheduleMode.rawValue)"
    }

    init(isActive: Bool = true) {
        self.isActive = isActive
        let savedMode = UserDefaults.standard.string(forKey: "defaultScheduleMode")
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
        .navigationTitle("Schedule")
        .task(id: scheduleLoadTaskID) {
            guard isActive else { return }
            guard viewModel.scheduleEntries.isEmpty || viewModel.loadedScheduleMode != selectedScheduleMode else { return }
            await viewModel.loadSchedule(mode: selectedScheduleMode, localTimeZone: showLocalScheduleTime)
        }
        .refreshable {
            await viewModel.loadSchedule(mode: selectedScheduleMode, localTimeZone: showLocalScheduleTime, forceRefresh: true)
        }
        .onChange(of: selectedScheduleMode) { _ in
            selectedScheduleDate = nil
        }
        .onChange(of: isActive) { active in
            guard active else { return }
            let defaultMode = ScheduleMode.sanitized(defaultScheduleModeRaw)
            if selectedScheduleMode != defaultMode {
                selectedScheduleMode = defaultMode
            }
        }
        .onChange(of: showLocalScheduleTime) { newValue in
            viewModel.regroupBuckets(localTimeZone: newValue)
        }
        .onReceive(dayChangeTimer) { _ in
            Task {
                await viewModel.handleDayChangeIfNeeded(mode: selectedScheduleMode, localTimeZone: showLocalScheduleTime)
            }
        }
        .background(
            Group {
                if #available(iOS 16.0, *) {
                    Color.clear
                        .navigationDestination(isPresented: $showingMediaDetail) {
                            if let result = selectedTMDBResult {
                                MediaDetailView(searchResult: result)
                            }
                        }
                } else {
                    NavigationLink(
                        isActive: $showingMediaDetail,
                        destination: {
                            if let result = selectedTMDBResult {
                                MediaDetailView(searchResult: result)
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
    }
    
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
            message: "No \(selectedScheduleMode.displayName.lowercased()) episodes scheduled in the next week."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var mainScheduleView: some View {
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
    }

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

            Picker("Schedule", selection: $selectedScheduleMode) {
                ForEach(ScheduleMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
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
            .frame(width: 150)
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

                Text("\(bucket.items.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(selected ? .black.opacity(0.65) : .white.opacity(0.5))
            }
            .foregroundColor(selected ? .black : .white)
            .frame(width: 64, height: 80)
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
        .buttonStyle(.card)
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

                    Text("\(bucket.items.count) airing")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)

                if bucket.items.isEmpty {
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
                        ForEach(bucket.items) { item in
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
        Button {
            guard loadingItemId == nil else { return }
            loadingItemId = item.id
            Task {
                let result = await viewModel.lookupTMDBResult(for: item)
                await MainActor.run {
                    loadingItemId = nil
                    if let result = result {
                        selectedTMDBResult = result
                        showingMediaDetail = true
                    } else {
                        noTMDBAlertTitle = item.title
                        showNoTMDBAlert = true
                    }
                }
            }
        } label: {
            compactScheduleItemContent(item: item)
        }
#if os(tvOS)
        .buttonStyle(.card)
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
        .animation(.easeInOut(duration: 0.2), value: loadingItemId)
        .disabled(loadingItemId != nil)
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
                }
                .foregroundColor(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white.opacity(0.12)))

                if let countdown = countdownLabel(for: item) {
                    Text(countdown)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: EclipseRadius.card)
    }

    @ViewBuilder
    private func schedulePoster(urlString: String?) -> some View {
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
        .frame(width: 58 * iPadScaleSmall, height: 84 * iPadScaleSmall)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Helpers

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
