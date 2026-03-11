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
    @StateObject private var viewModel = ScheduleViewModel()
    @StateObject private var accentColorManager = AccentColorManager.shared
    
    @State private var selectedTMDBResult: TMDBSearchResult?
    @State private var showingMediaDetail = false
    @State private var showNoTMDBAlert = false
    @State private var noTMDBAlertTitle = ""
    @State private var loadingItemId: Int?
    
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
            LunaTheme.shared.backgroundBase.ignoresSafeArea()
            
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
            NavigationLink(
                destination: Group {
                    if let result = selectedTMDBResult {
                        MediaDetailView(searchResult: result)
                    }
                },
                isActive: $showingMediaDetail
            ) {
                EmptyView()
            }
            .hidden()
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
            VStack(alignment: .leading, spacing: 20) {
                // Time zone toggle section
                timeZoneToggleSection
                
                // Schedule days
                ForEach(viewModel.dayBuckets) { bucket in
                    daySection(bucket: bucket)
                }
            }
            .padding(.top)
            .padding(.bottom, 100)
        }
    }
    
    private var timeZoneToggleSection: some View {
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
            // Day header
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
            scheduleItemContent(item: item)
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
            // Cover image
            if let coverURL = item.coverImage, let url = URL(string: coverURL) {
                KFImage(url)
                    .resizable()
                    .placeholder {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                    }
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60 * iPadScaleSmall, height: 85 * iPadScaleSmall)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 60 * iPadScaleSmall, height: 85 * iPadScaleSmall)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            
            // Info
            VStack(alignment: .leading, spacing: 4) {
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
    
    private func formattedDay(_ date: Date) -> String {
        let calendar = Calendar.current
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

