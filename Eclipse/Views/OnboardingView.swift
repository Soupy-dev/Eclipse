import SwiftUI

enum OnboardingState {
    static let completedKey = "eclipseOnboardingCompletedV1"
    static let appHubNoticeSeenKey = "eclipseAppHubNoticeSeenV1"

    private static let priorHistoryKeys: Set<String> = [
        "enabledCatalogs",
        "accentColor",
        "selectedAppearance",
        "searchHistory",
        "externalPlayer",
        "inAppPlayer",
        "hideSplashScreen",
        "showKanzen"
    ]

    private static let priorHistoryKeyPrefixes = [
        "appearance",
        "atmosphere",
        "eclipse",
        "githubRelease",
        "kanzen",
        "mpv",
        "nuvio",
        "player",
        "reader",
        "Reader.",
        "services",
        "skyStream",
        "stremio",
        "subtitles_"
    ]

    static func bootstrapIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: completedKey) == nil else { return }
        defaults.set(installHasPriorHistory(defaults), forKey: completedKey)
    }

    private static func installHasPriorHistory(_ defaults: UserDefaults) -> Bool {
        let domain = defaults.persistentDomain(
            forName: Bundle.main.bundleIdentifier ?? "app.Eclipse"
        ) ?? [:]
        let hasAppWrittenKey = domain.keys.contains { key in
            priorHistoryKeys.contains(key)
                || priorHistoryKeyPrefixes.contains(where: key.hasPrefix)
        }
        if hasAppWrittenKey { return true }

        return FileManager.default.fileExists(atPath: ServiceStoreScope.sharedStoreURL.path)
    }
}

struct OnboardingView: View {
    let onFinished: () -> Void

    private enum Step: Hashable {
        case welcome
        case hub
        case restore
        case sources
        case profile
        case chooseProfile
    }

#if os(tvOS)
    private enum TVFocus: Hashable {
        case primary
        case skip
    }

    @FocusState private var tvFocus: TVFocus?
#endif

    @StateObject private var accentColorManager = AccentColorManager.shared
    @StateObject private var profileManager = ProfileManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var step = 0
    @State private var name = ""
    @State private var avatarColorHex = ProfileAvatar.defaultColorHex
    @State private var entered = false
    @State private var accentLineWidth: CGFloat = 0

#if !os(tvOS)
    @State private var showCloudRestore = false
    @State private var profilesBeforeRestore: [Profile] = []
    @State private var didRestoreFromCloud = false
    @State private var pendingProfileUnlock: Profile?
#endif

    private let baseSteps: [Step]

    init(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        let isKidsProfile = ProfileManager.shared.activeProfile?.isKidsProfile == true
#if os(tvOS)
        self.baseSteps = isKidsProfile
            ? [.welcome, .sources]
            : [.welcome, .sources, .profile]
#else
        let offersCloudRestore = !isKidsProfile && ExperimentalFeatureState.isEnabledAtLaunch
        self.baseSteps = isKidsProfile
            ? [.welcome, .hub, .sources]
            : (offersCloudRestore
                ? [.welcome, .hub, .restore, .sources, .profile]
                : [.welcome, .hub, .sources, .profile])
#endif
    }

    private var steps: [Step] {
#if os(tvOS)
        return baseSteps
#else
        guard didRestoreFromCloud else { return baseSteps }
        guard profileManager.profiles.count > 1 else {
            return baseSteps.filter { $0 != .profile }
        }
        return baseSteps.map { $0 == .profile ? .chooseProfile : $0 }
#endif
    }

    private var accent: Color { accentColorManager.currentAccentColor }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentStep: Step {
        steps.indices.contains(step) ? steps[step] : .welcome
    }

    private var isLastStep: Bool { step >= steps.count - 1 }

    private var primaryTitle: String {
        if currentStep == .profile { return "Save Profile" }
        return isLastStep ? "Done" : "Continue"
    }

    private var primaryEnabled: Bool {
        currentStep != .profile || !trimmedName.isEmpty
    }

    private var horizontalPadding: CGFloat { isTvOS ? 60 : 20 }

    private var ctaRadius: CGFloat { isTvOS ? 26 : (isIPad ? 20 : 17) }

    private var ornamentScale: CGFloat { isTvOS ? 1.6 : iPadScaleSmall }

    private var accentRuleTrack: CGFloat { SplashMotion.accentRuleWidth * ornamentScale }

    private var accentRuleHeight: CGFloat { isTvOS ? 3 : SplashMotion.accentRuleHeight }

    private var dotScale: CGFloat { isTvOS ? 1.8 : iPadScaleSmall }

    private var staggerEnabled: Bool {
#if os(tvOS)
        return false
#else
        return !reduceMotion
#endif
    }

    private var wordmarkShimmer: Bool {
#if os(iOS)
        return !reduceMotion
#else
        return false
#endif
    }

    private var contentOpacity: Double {
#if os(iOS)
        return entered ? 1 : 0
#else
        return 1
#endif
    }

    private var contentScale: CGFloat {
#if os(iOS)
        return entered ? 1 : 1.04
#else
        return 1
#endif
    }

    var body: some View {
        ZStack {
            SettingsGradientBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 22) {
                        stepContent
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }

                footer
            }
            .opacity(contentOpacity)
            .scaleEffect(contentScale)
            .onAppear { playEntrance() }
        }
        .preferredColorScheme(.dark)
#if os(tvOS)
        .onAppear { tvFocus = .primary }
#else
        .accessibilityAddTraits(.isModal)
        .sheet(isPresented: $showCloudRestore, onDismiss: reconcileRestoreOutcome) {
            NavigationView {
                ExperimentalCloudSyncView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button("Done") { showCloudRestore = false }
                        }
                    }
            }
            .navigationViewStyle(.stack)
            .preferredColorScheme(.dark)
        }
        .sheet(item: $pendingProfileUnlock) { profile in
            ProfilePINEntryView(mode: .unlock(profile)) { success in
                if success {
                    profileManager.switchProfile(to: profile.id)
                }
            }
        }
#endif
    }

    private var header: some View {
        HStack {
            Button("Skip") { finish() }
                .foregroundColor(.white.opacity(0.7))
#if os(tvOS)
                .buttonStyle(.card)
#else
                .buttonStyle(.plain)
#endif

            Spacer()

            HStack(spacing: 8 * dotScale) {
                ForEach(steps.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? accent : Color.white.opacity(0.16))
                        .frame(
                            width: (index == step ? 26 : 8) * dotScale,
                            height: 8 * dotScale
                        )
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of \(steps.count)")

            Spacer()

            Text("Skip")
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 18)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button {
                advance()
            } label: {
                Text(primaryTitle)
                    .font(.system(size: isTvOS ? 34 : (isIPad ? 25 : 22), weight: .bold))
                    .foregroundColor(primaryEnabled ? .black : .white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: isTvOS ? 80 : (isIPad ? 58 : 52))
                    .background(
                        RoundedRectangle(cornerRadius: ctaRadius, style: .continuous)
                            .fill(primaryEnabled ? Color.white.opacity(0.72) : Color.white.opacity(0.16))
                            .background(
                                RoundedRectangle(cornerRadius: ctaRadius, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                    .opacity(0.72)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ctaRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.32), lineWidth: 1)
                    )
            }
#if os(tvOS)
            .buttonStyle(.card)
            .focused($tvFocus, equals: .primary)
#else
            .buttonStyle(.plain)
#endif
            .disabled(!primaryEnabled)

            if currentStep == .profile {
                Button("Skip") { finish() }
                    .foregroundColor(.white.opacity(0.6))
#if os(tvOS)
                    .buttonStyle(.card)
                    .focused($tvFocus, equals: .skip)
                    .onAppear { if !primaryEnabled { tvFocus = .skip } }
#else
                    .buttonStyle(.plain)
#endif
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            welcomeStep.transition(.opacity)
        case .hub:
            hubStep.transition(.opacity)
        case .restore:
            restoreStep.transition(.opacity)
        case .sources:
            sourcesStep.transition(.opacity)
        case .profile:
            profileStep.transition(.opacity)
        case .chooseProfile:
            chooseProfileStep.transition(.opacity)
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 28) {
            SplashReveal(index: 0, enabled: staggerEnabled) {
                VStack(spacing: 12) {
                    SplashWordmark(text: "Eclipse", shimmer: wordmarkShimmer)

                    SplashAccentRule(
                        trackWidth: accentRuleTrack,
                        height: accentRuleHeight,
                        fillWidth: accentLineWidth
                    )

                    Text("A player and a catalog.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
            }

            SplashReveal(index: 1, enabled: staggerEnabled) {
                GlassSection {
                    VStack(spacing: 0) {
                        bulletRow("sparkles", .cyan, "Browsing works with no setup")
                        GlassDivider()
                        bulletRow("exclamationmark.triangle.fill", .orange, "Playback needs a source you add")
                        GlassDivider()
                        bulletRow("icloud", .blue, "Cloud sync starts off")
                    }
                }
            }

            SplashReveal(index: 2, enabled: staggerEnabled) {
                GlassSectionFooter("Eclipse will never have ads, telemetry, or any paid features. Logs stay on your device; there is no Eclipse server to send them to. It helps greatly if you can support it in Settings › Support.")
            }

            SplashReveal(index: 3, enabled: staggerEnabled) {
                GlassSection {
                    VStack(spacing: 0) {
                        legalRow(
                            "doc.text.fill",
                            .blue,
                            "Terms of Use (EULA)",
                            supportTermsOfUseURL
                        )

                        GlassDivider()

                        legalRow(
                            "hand.raised.fill",
                            .teal,
                            "Privacy Policy",
                            supportPrivacyPolicyURL
                        )
                    }
                }
            }
        }
        .onAppear { revealAccentRule() }
    }

    @ViewBuilder
    private var hubStep: some View {
#if !os(tvOS)
        VStack(spacing: 22) {
            SplashReveal(index: 0, enabled: staggerEnabled) {
                VStack(spacing: 6) {
                    Text("Settings and Reader Mode")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)

                    Text("Tap the handle on the edge of the screen.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
            }

            SplashReveal(index: 1, enabled: staggerEnabled) {
                AppHubOnboardingDiagram(accent: accent)
            }

            SplashReveal(index: 2, enabled: staggerEnabled) {
                GlassSection {
                    VStack(spacing: 0) {
                        bulletRow("book.fill", .orange, "Switch to Reader Mode")
                        GlassDivider()
                        bulletRow("gear", .gray, "Settings")
                    }
                }
            }

            SplashReveal(index: 3, enabled: staggerEnabled) {
                GlassSectionFooter("Reader Mode has no handle. A play button in its header brings you back. Drag the handle to move it up or down.")
            }
        }
#endif
    }

    @ViewBuilder
    private var restoreStep: some View {
#if !os(tvOS)
        VStack(spacing: 22) {
            SplashReveal(index: 0, enabled: staggerEnabled) {
                VStack(spacing: 6) {
                    Text("Already use Eclipse?")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)

                    Text("Connect a cloud provider and pick up where you left off.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
            }

            SplashReveal(index: 1, enabled: staggerEnabled) {
                GlassSection {
                    Button {
                        profilesBeforeRestore = profileManager.profiles
                        showCloudRestore = true
                    } label: {
                        GlassDetailRow(
                            icon: "icloud",
                            iconColor: .blue,
                            title: "Connect a Cloud Provider",
                            subtitle: "iCloud, Google Drive, or OneDrive"
                        ) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            SplashReveal(index: 2, enabled: staggerEnabled) {
                GlassSectionFooter("New to Eclipse? Just continue — a provider can be connected any time in Settings › Cloud Sync.")
            }
        }
#endif
    }

    private var sourcesStep: some View {
        VStack(spacing: 22) {
            SplashReveal(index: 0, enabled: staggerEnabled) {
                VStack(spacing: 6) {
                    Text("Add a source")
                        .font(.system(size: isTvOS ? 40 : 28, weight: isTvOS ? .bold : .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)

                    Text("Eclipse ships with none. Playback needs one you add.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
            }

#if !os(tvOS)
            SplashReveal(index: 1, enabled: staggerEnabled) {
                SourcesOnboardingDiagram(accent: accent)
            }
#endif

            SplashReveal(index: 2, enabled: staggerEnabled) {
                GlassSection {
                    VStack(spacing: 0) {
                        bulletRow("1.circle.fill", .indigo, "Open Settings › Services")
                        GlassDivider()
                        bulletRow("2.circle.fill", .purple, "Tap + to add a source")
                        GlassDivider()
                        bulletRow("3.circle.fill", .teal, "Switch it on")
                    }
                }
            }

            SplashReveal(index: 3, enabled: staggerEnabled) {
                GlassSectionFooter("The add screen lists every source format this build accepts. Browsing and catalogs keep working without one.")
            }
        }
    }

    private var profileStep: some View {
        VStack(spacing: 22) {
            SplashReveal(index: 0, enabled: staggerEnabled) {
                VStack(spacing: 6) {
                    Text("Create your profile")
                        .font(.system(size: isTvOS ? 40 : 28, weight: isTvOS ? .bold : .semibold))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.7)

                    Text("Name it now, or skip and keep the default.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
            }

            SplashReveal(index: 1, enabled: staggerEnabled) {
                ProfileAvatarView(profile: previewProfile, size: 92)
            }

            GlassSection(header: "Name") {
                TextField("Your name", text: $name)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }

            GlassSection(header: "Color") {
                colorGrid
            }

            GlassSectionFooter("More profiles, kids mode, PINs and photos live in Settings › Profiles.")
        }
    }

    @ViewBuilder
    private var chooseProfileStep: some View {
#if !os(tvOS)
        VStack(spacing: 22) {
            SplashReveal(index: 0, enabled: staggerEnabled) {
                VStack(spacing: 6) {
                    Text("Which profile is yours?")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)

                    Text("Your profiles came back with your data. Pick the one to open Eclipse with.")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
            }

            SplashReveal(index: 1, enabled: staggerEnabled) {
                GlassSection {
                    VStack(spacing: 0) {
                        ForEach(Array(profileManager.profiles.enumerated()), id: \.element.id) { index, profile in
                            Button {
                                activate(profile)
                            } label: {
                                profileChoiceRow(profile)
                            }
                            .buttonStyle(.plain)

                            if index < profileManager.profiles.count - 1 {
                                GlassDivider()
                            }
                        }
                    }
                }
            }

            SplashReveal(index: 2, enabled: staggerEnabled) {
                GlassSectionFooter("Switch profiles any time in Settings › Profiles. A profile with a PIN always asks to unlock.")
            }
        }
#endif
    }

#if !os(tvOS)
    private func profileChoiceRow(_ profile: Profile) -> some View {
        let isActive = profile.id == profileManager.activeProfileID
        return HStack(spacing: 14) {
            ProfileAvatarView(profile: profile, size: 40, showsLockBadge: profile.isLocked)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body)
                    .foregroundColor(.white)
                    .lineLimit(1)

                if profile.isKidsProfile {
                    Text("Kids profile")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            Spacer(minLength: 0)

            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundColor(isActive ? accent : .white.opacity(0.24))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
#endif

    @ViewBuilder
    private func legalRow(
        _ icon: String,
        _ color: Color,
        _ title: String,
        _ url: URL
    ) -> some View {
#if os(tvOS)
        GlassDetailRow(
            icon: icon,
            iconColor: color,
            title: title,
            subtitle: url.absoluteString
        ) {
            EmptyView()
        }
#else
        Link(destination: url) {
            GlassDetailRow(icon: icon, iconColor: color, title: title) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
#endif
    }

    private func bulletRow(
        _ icon: String,
        _ color: Color,
        _ title: String,
        _ subtitle: String? = nil
    ) -> some View {
        GlassDetailRow(icon: icon, iconColor: color, title: title, subtitle: subtitle) {
            EmptyView()
        }
    }

    private var previewProfile: Profile {
        Profile(
            id: ProfileManager.defaultProfileID,
            name: trimmedName.isEmpty ? "Me" : trimmedName,
            avatarSymbol: ProfileAvatar.defaultSymbol,
            avatarColorHex: avatarColorHex
        )
    }

    private var colorGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 56), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(ProfileAvatar.colorHexes, id: \.self) { hex in
                Button {
                    avatarColorHex = hex
                } label: {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(ProfileAvatar.color(fromHex: hex))
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(
                                    avatarColorHex == hex ? Color.white : Color.white.opacity(0.14),
                                    lineWidth: avatarColorHex == hex ? 2.5 : 1
                                )
                        )
                        .scaleEffect(avatarColorHex == hex ? 1.05 : 1)
                }
#if os(tvOS)
                .buttonStyle(.card)
#else
                .buttonStyle(.plain)
#endif
                .accessibilityLabel("Avatar color \(hex)")
            }
        }
        .padding(14)
    }

    private func playEntrance() {
#if os(iOS)
        guard !entered else { return }
        guard !reduceMotion else {
            entered = true
            return
        }
        withAnimation(SplashMotion.markSettle) { entered = true }
#endif
    }

    private func revealAccentRule() {
        guard accentLineWidth < accentRuleTrack else { return }
        guard !reduceMotion else {
            accentLineWidth = accentRuleTrack
            return
        }
        withAnimation(SplashMotion.titleReveal.delay(SplashMotion.titleRevealDelay)) {
            accentLineWidth = accentRuleTrack
        }
    }

    private func advance() {
        guard !isLastStep else {
            if currentStep == .profile {
                saveProfile()
            }
            finish()
            return
        }

        if reduceMotion {
            step += 1
        } else {
            withAnimation(.easeInOut(duration: 0.28)) {
                step += 1
            }
        }
    }

#if !os(tvOS)
    private func reconcileRestoreOutcome() {
        didRestoreFromCloud = profileManager.profiles != profilesBeforeRestore
    }

    private func activate(_ profile: Profile) {
        guard profile.id != profileManager.activeProfileID else { return }
        if profile.isLocked {
            pendingProfileUnlock = profile
        } else {
            profileManager.switchProfile(to: profile.id)
        }
    }
#endif

    private func saveProfile() {
#if !os(tvOS)
        guard !didRestoreFromCloud else { return }
#endif
        guard !trimmedName.isEmpty else { return }
        let manager = ProfileManager.shared

        if manager.profiles.count == 1,
           var placeholder = manager.profiles.first,
           placeholder.id == ProfileManager.defaultProfileID {
            placeholder.name = trimmedName
            placeholder.avatarColorHex = avatarColorHex
            manager.updateProfile(placeholder)
        } else if let created = manager.createProfile(
            name: trimmedName,
            avatarColorHex: avatarColorHex
        ) {
            manager.switchProfile(to: created.id)
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: OnboardingState.completedKey)
        UserDefaults.standard.set(true, forKey: OnboardingState.appHubNoticeSeenKey)
        onFinished()
    }
}

#if !os(tvOS)
struct AppHubUpdateNoticeView: View {
    let onFinished: () -> Void

    @StateObject private var accentColorManager = AccentColorManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var entered = false

    private var accent: Color { accentColorManager.currentAccentColor }

    private var staggerEnabled: Bool { !reduceMotion }

    private var ctaRadius: CGFloat { isIPad ? 20 : 17 }

    var body: some View {
        ZStack {
            SettingsGradientBackground().ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 22) {
                        SplashReveal(index: 0, enabled: staggerEnabled) {
                            VStack(spacing: 6) {
                                Text("Welcome back")
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .minimumScaleFactor(0.7)

                                Text("Settings moved somewhere easier to reach. Tap the handle on the edge of the screen.")
                                    .font(.footnote)
                                    .foregroundColor(.white.opacity(0.6))
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 24)
                            }
                        }

                        SplashReveal(index: 1, enabled: staggerEnabled) {
                            AppHubOnboardingDiagram(accent: accent)
                        }

                        SplashReveal(index: 2, enabled: staggerEnabled) {
                            GlassSection {
                                VStack(spacing: 0) {
                                    GlassDetailRow(
                                        icon: "book.fill",
                                        iconColor: .orange,
                                        title: "Switch to Reader Mode"
                                    ) {
                                        EmptyView()
                                    }

                                    GlassDivider()

                                    GlassDetailRow(
                                        icon: "gear",
                                        iconColor: .gray,
                                        title: "Settings"
                                    ) {
                                        EmptyView()
                                    }
                                }
                            }
                        }

                        SplashReveal(index: 3, enabled: staggerEnabled) {
                            GlassSectionFooter("Reader Mode has no handle. A play button in its header brings you back. Drag the handle to move it up or down. Nothing else changed — your library, history and sources are where you left them.")
                        }
                    }
                    .padding(.top, 28)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }

                Button {
                    finish()
                } label: {
                    Text("Got it")
                        .font(.system(size: isIPad ? 25 : 22, weight: .bold))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: isIPad ? 58 : 52)
                        .background(
                            RoundedRectangle(cornerRadius: ctaRadius, style: .continuous)
                                .fill(Color.white.opacity(0.72))
                                .background(
                                    RoundedRectangle(cornerRadius: ctaRadius, style: .continuous)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.72)
                                )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: ctaRadius, style: .continuous)
                                .stroke(Color.white.opacity(0.32), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .opacity(entered ? 1 : 0)
            .scaleEffect(entered ? 1 : 1.04)
            .onAppear { playEntrance() }
        }
        .preferredColorScheme(.dark)
        .accessibilityAddTraits(.isModal)
    }

    private func playEntrance() {
        guard !entered else { return }
        guard !reduceMotion else {
            entered = true
            return
        }
        withAnimation(SplashMotion.markSettle) { entered = true }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: OnboardingState.appHubNoticeSeenKey)
        onFinished()
    }
}

private struct SourcesOnboardingDiagram: View {
    let accent: Color

    @Environment(\.layoutDirection) private var layoutDirection
    @ScaledMetric(relativeTo: .body) private var scaledWidth: CGFloat = 210

    private var frameWidth: CGFloat { min(max(scaledWidth, 200), 280) }

    private var frameHeight: CGFloat { frameWidth * 0.86 }

    private var cornerRadius: CGFloat { frameWidth * 0.09 }

    private var addGlyphDiameter: CGFloat { frameWidth * 0.13 }

    private var addGlyphCenter: CGPoint {
        let inset = frameWidth * 0.17
        return CGPoint(
            x: layoutDirection == .rightToLeft ? inset : frameWidth - inset,
            y: frameHeight * 0.14
        )
    }

    private var outline: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            outline.fill(Color.white.opacity(0.05))
            screen
        }
        .frame(width: frameWidth, height: frameHeight)
        .clipShape(outline)
        .overlay { outline.strokeBorder(Color.white.opacity(0.22), lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Illustration. The Services screen, with a plus button in the top corner that adds a source.")
    }

    private var screen: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.3)

            VStack(alignment: .leading, spacing: frameHeight * 0.05) {
                Capsule()
                    .fill(Color.white.opacity(0.24))
                    .frame(width: frameWidth * 0.34, height: frameHeight * 0.035)
                    .padding(.top, frameHeight * 0.1)
                    .padding(.bottom, frameHeight * 0.07)

                ForEach(0..<3, id: \.self) { index in
                    sourcePlaceholderRow(isEnabled: index == 0)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, frameWidth * 0.08)
            .padding(.bottom, frameHeight * 0.06)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.4), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: addGlyphDiameter
                    )
                )
                .frame(width: addGlyphDiameter * 2.2, height: addGlyphDiameter * 2.2)
                .position(addGlyphCenter)

            Circle()
                .strokeBorder(accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: addGlyphDiameter * 1.5, height: addGlyphDiameter * 1.5)
                .position(addGlyphCenter)

            Image(systemName: "plus")
                .font(.system(size: addGlyphDiameter * 0.72, weight: .bold))
                .foregroundColor(.white)
                .position(addGlyphCenter)
        }
    }

    private func sourcePlaceholderRow(isEnabled: Bool) -> some View {
        HStack(spacing: frameWidth * 0.05) {
            RoundedRectangle(cornerRadius: frameWidth * 0.025, style: .continuous)
                .fill(Color.white.opacity(0.16))
                .frame(width: frameWidth * 0.11, height: frameWidth * 0.11)

            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(height: frameHeight * 0.03)

            Capsule()
                .fill(isEnabled ? accent.opacity(0.8) : Color.white.opacity(0.12))
                .frame(width: frameWidth * 0.14, height: frameHeight * 0.042)
        }
    }
}

private struct AppHubOnboardingDiagram: View {
    let accent: Color

    @Environment(\.layoutDirection) private var layoutDirection
    @ScaledMetric(relativeTo: .body) private var scaledWidth: CGFloat = 140

    private static let referenceWidth: CGFloat = 402
    private static let referenceHeight: CGFloat = 874
    private static let referenceTopInset: CGFloat = 62
    private static let legibilityBoost: CGFloat = 1.9

    private var frameWidth: CGFloat { min(max(scaledWidth, 140), 200) }

    private var frameHeight: CGFloat {
        frameWidth * Self.referenceHeight / Self.referenceWidth
    }

    private var deviceScale: CGFloat { frameHeight / Self.referenceHeight }

    private var ornamentScale: CGFloat { deviceScale * Self.legibilityBoost }

    private var cornerRadius: CGFloat { frameWidth * 0.17 }

    private var handleY: CGFloat {
        let topInset = frameHeight * Self.referenceTopInset / Self.referenceHeight
        let lower = min(topInset + AppHubMetrics.trackTopInset * deviceScale, frameHeight / 2)
        let upper = max(frameHeight - AppHubMetrics.trackBottomInset * deviceScale, frameHeight / 2)
        return lower + CGFloat(AppHubMetrics.defaultPosition) * (upper - lower)
    }

    private var handleWidth: CGFloat { AppHubMetrics.handleWidth * ornamentScale }
    private var handleHeight: CGFloat { AppHubMetrics.handleHeight * ornamentScale }
    private var handleOverhang: CGFloat { AppHubMetrics.handleOverhang * ornamentScale }
    private var hitWidth: CGFloat { AppHubMetrics.hitWidth * ornamentScale }
    private var hitHeight: CGFloat { AppHubMetrics.hitHeight * ornamentScale }
    private var buttonDiameter: CGFloat { AppHubMetrics.buttonDiameter * ornamentScale }

    private var inwardSign: CGFloat {
        layoutDirection == .rightToLeft ? 1 : -1
    }

    private var hubEdgeX: CGFloat {
        layoutDirection == .rightToLeft
            ? hitWidth / 2
            : frameWidth - hitWidth / 2
    }

    private var fanOffset: CGPoint {
        let radians = AppHubMetrics.fanStep / 2 * .pi / 180
        let radius = AppHubMetrics.fanRadius * ornamentScale
        return CGPoint(x: radius * CGFloat(cos(radians)), y: radius * CGFloat(sin(radians)))
    }

    private var outline: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            outline.fill(Color.white.opacity(0.05))
            screen
        }
        .frame(width: frameWidth, height: frameHeight)
        .clipShape(outline)
        .overlay { outline.strokeBorder(Color.white.opacity(0.22), lineWidth: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Illustration. A slim handle sits on the edge of the screen, a little above the middle. Tapping it opens Reader Mode and Settings.")
    }

    private var screen: some View {
        ZStack {
            Color.black.opacity(0.3)

            chromeHints

            Capsule()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.34), Color.clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: hitHeight * 0.7
                    )
                )
                .frame(width: hitWidth * 2, height: hitHeight * 1.5)
                .position(x: hubEdgeX, y: handleY)

            RoundedRectangle(cornerRadius: hitWidth / 2, style: .continuous)
                .strokeBorder(accent.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: hitWidth, height: hitHeight)
                .position(x: hubEdgeX, y: handleY)

            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: handleWidth, height: handleHeight)
                .offset(x: -inwardSign * handleOverhang)
                .frame(width: hitWidth, height: hitHeight, alignment: .trailing)
                .position(x: hubEdgeX, y: handleY)

            fanButton(symbol: "book.fill", dy: -fanOffset.y)
            fanButton(symbol: "gear", dy: fanOffset.y)
        }
    }

    private var chromeHints: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.14))
                .frame(width: frameWidth * 0.42, height: frameHeight * 0.018)
                .padding(.top, frameHeight * 0.055)

            Spacer(minLength: 0)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: frameHeight * 0.07)
        }
    }

    private func fanButton(symbol: String, dy: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.16))

            Circle()
                .strokeBorder(Color.white.opacity(0.34), lineWidth: 1)

            Image(systemName: symbol)
                .font(.system(size: buttonDiameter * 0.44, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: buttonDiameter, height: buttonDiameter)
        .position(x: hubEdgeX + inwardSign * fanOffset.x, y: handleY + dy)
    }
}
#endif
