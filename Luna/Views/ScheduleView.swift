//
//  ScheduleView.swift
//  Luna
//
//  Created by Soupy-dev
//

import SwiftUI
import Combine
import Kingfisher

struct ScheduleView: View {
    @AppStorage("showLocalScheduleTime") private var showLocalScheduleTime = true
    @AppStorage("useClassicScheduleUI") private var useClassicScheduleUI = false
    @StateObject private var viewModel = ScheduleViewModel()
    @StateObject private var accentColorManager = AccentColorManager.shared
    
    @State private var selectedTMDBResult: TMDBSearchResult?
    @State private var showingMediaDetail = false
    @State private var showNoTMDBAlert = false
    @State private var noTMDBAlertTitle = ""
    @State private var loadingItemId: Int?
    @State private var scrollOffset: CGFloat = 0
    @State private var selectedScheduleDate: Date?
    
    private let dayChangeTimer = Timer.publish(every: 300, on: .main, in: .common).autoconnect()
    
    var body: some View {
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
    }
    
    private var scheduleContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SettingsGradientBackground(scrollOffset: scrollOffset).ignoresSafeArea()
            
            if viewModel.isLoading {
                loadingView
            } else if let errorMessage = viewModel.errorMessage {
                errorView(errorMessage)
            } else if viewModel.dayBuckets.isEmpty {
                emptyStateView
            } else {
                mainScheduleView
            }
        }
        .navigationTitle("Schedule")
        .task {
            if viewModel.scheduleEntries.isEmpty {
                await viewModel.loadSchedule(localTimeZone: showLocalScheduleTime)
            }
        }
        .refreshable {
            await viewModel.loadSchedule(localTimeZone: showLocalScheduleTime)
        }
        .onChange(of: showLocalScheduleTime) { newValue in
            viewModel.regroupBuckets(localTimeZone: newValue)
        }
        .onReceive(dayChangeTimer) { _ in
            Task { await viewModel.handleDayChangeIfNeeded(localTimeZone: showLocalScheduleTime) }
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
            ProgressView()
                .scaleEffect(1.2)
            Text("Loading schedule...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 50))
                .foregroundColor(.orange)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            Button("Retry") {
                Task { await viewModel.loadSchedule(localTimeZone: showLocalScheduleTime) }
            }
            .buttonStyle(.bordered)
            .tint(accentColorManager.currentAccentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "calendar")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            Text("No Upcoming Episodes")
                .font(.title2)
                .fontWeight(.bold)
            Text("No episodes scheduled in the next week.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var mainScheduleView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if useClassicScheduleUI {
                    classicTimeZoneToggleSection

                    ForEach(viewModel.dayBuckets) { bucket in
                        daySection(bucket: bucket)
                    }
                } else {
                    timeZoneToggleSection
                    dayPickerSection
                    selectedDaySection
                }
            }
            .padding(.top)
            .padding(.bottom, 100)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: -geo.frame(in: .named("scheduleScroll")).origin.y
                    )
                }
            )
        }
        .coordinateSpace(name: "scheduleScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
    }

    private var selectedBucket: DayBucket? {
        let calendar = scheduleCalendar
        if let selectedScheduleDate,
           let bucket = viewModel.dayBuckets.first(where: { calendar.isDate($0.date, inSameDayAs: selectedScheduleDate) }) {
            return bucket
        }
        return viewModel.dayBuckets.first(where: { !$0.items.isEmpty }) ?? viewModel.dayBuckets.first
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
        .background(LunaTheme.shared.cardBackground)
        .cornerRadius(10)
        .padding(.horizontal)
    }

    private var classicTimeZoneToggleSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Timezone")
                    .font(.headline)
                Text("Times are shown in \(showLocalScheduleTime ? "your local time" : "UTC")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("Local time", isOn: $showLocalScheduleTime)
                .labelsHidden()
                .tint(accentColorManager.currentAccentColor)
        }
        .padding()
        .background(LunaTheme.shared.cardBackground)
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private func daySection(bucket: DayBucket) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(formattedDay(bucket.date))
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            if bucket.items.isEmpty {
                Text("No episodes scheduled")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 12) {
                    ForEach(bucket.items) { item in
                        scheduleItemCard(item: item)
                    }
                }
                .padding(.horizontal)
            }
        }
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

        return Button {
            selectedScheduleDate = bucket.date
        } label: {
            VStack(spacing: 3) {
                Text(shortDay(bucket.date))
                    .font(.caption.weight(.semibold))

                Text(dayNumber(bucket.date))
                    .font(.headline.weight(.bold))

                Text("\(bucket.items.count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(selected ? .black.opacity(0.7) : .secondary)
            }
            .foregroundColor(selected ? .black : .white)
            .frame(width: 62, height: 72)
            .background(selected ? accentColorManager.currentAccentColor : LunaTheme.shared.cardBackground)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
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
                        .background(LunaTheme.shared.cardBackground)
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
    
    private func scheduleItemCard(item: AniListAiringScheduleEntry) -> some View {
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
            if useClassicScheduleUI {
                scheduleItemContent(item: item)
            } else {
                compactScheduleItemContent(item: item)
            }
        }
        .buttonStyle(.plain)
        .opacity(loadingItemId == item.id ? 0.6 : 1.0)
        .overlay {
            if loadingItemId == item.id {
                ProgressView()
                    .tint(.white)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: loadingItemId)
        .disabled(loadingItemId != nil)
    }
    
    private func scheduleItemContent(item: AniListAiringScheduleEntry) -> some View {
        HStack(spacing: 12) {
            if let coverURL = item.coverImage, let url = URL(string: coverURL) {
                KFImage(url)
                    .resizable()
                    .placeholder {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                    }
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 54 * iPadScaleSmall, height: 76 * iPadScaleSmall)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 54 * iPadScaleSmall, height: 76 * iPadScaleSmall)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    Text(formatLabel(for: item))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary)
                    
                    Label(formattedTime(item.airingAt), systemImage: "clock")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
        .padding()
        .background(LunaTheme.shared.cardBackground)
        .cornerRadius(16)
    }

    private func compactScheduleItemContent(item: AniListAiringScheduleEntry) -> some View {
        HStack(spacing: 12) {
            schedulePoster(urlString: item.coverImage)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(2)

                Text(formatLabel(for: item))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            Text(formattedTime(item.airingAt))
                .font(.caption.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.12))
                .cornerRadius(8)
        }
        .padding(10)
        .background(LunaTheme.shared.cardBackground)
        .cornerRadius(10)
    }

    @ViewBuilder
    private func schedulePoster(urlString: String?) -> some View {
        if let urlString, let url = URL(string: urlString) {
            KFImage(url)
                .resizable()
                .placeholder {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 54 * iPadScaleSmall, height: 76 * iPadScaleSmall)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 54 * iPadScaleSmall, height: 76 * iPadScaleSmall)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
    
    // MARK: - Helpers
    
    private func formatLabel(for item: AniListAiringScheduleEntry) -> String {
        switch item.format?.uppercased() {
        case "MOVIE":
            return "Movie"
        case "OVA":
            return "OVA"
        case "ONA":
            return "ONA Ep. \(item.episode)"
        case "SPECIAL":
            return "Special"
        case "MUSIC":
            return "Music"
        default:
            return "Ep. \(item.episode)"
        }
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
}

