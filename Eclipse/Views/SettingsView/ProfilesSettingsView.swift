import SwiftUI
#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(LocalAuthentication) && !os(tvOS)
import LocalAuthentication
#endif
#if canImport(UIKit)
import UIKit
#endif

extension Profile {
    var avatarColor: Color { ProfileAvatar.color(fromHex: avatarColorHex) }
}

extension ProfileAvatar {

    static func color(fromHex hex: String) -> Color {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
            return .blue
        }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }

    private static let symbolAvailabilityCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 64
        return cache
    }()

    static func renderableSymbolName(_ rawValue: String) -> String {
        let name = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != defaultSymbol else { return defaultSymbol }

        let key = name as NSString
        if let cached = symbolAvailabilityCache.object(forKey: key) {
            return cached.boolValue ? name : defaultSymbol
        }

#if canImport(UIKit)
        let exists = UIImage(systemName: name) != nil
#else
        let exists = symbols.contains(name)
#endif
        symbolAvailabilityCache.setObject(NSNumber(value: exists), forKey: key)
        return exists ? name : defaultSymbol
    }
}

struct ProfileAvatarView: View {
    let profile: Profile
    var size: CGFloat = 56
    var isSelected: Bool = false
    var selectionColor: Color = .white

    var showsLockBadge: Bool?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(profile.avatarColor.opacity(0.9))

            if let photo = profile.avatarPhotoData, let image = Self.image(from: photo) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: ProfileAvatar.renderableSymbolName(profile.avatarSymbol))
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(
                    isSelected ? selectionColor : Color.white.opacity(0.14),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        .overlay(alignment: .bottomTrailing) {
            if showsLockBadge ?? profile.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundColor(.white)
                    .padding(size * 0.09)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .offset(x: size * 0.06, y: size * 0.06)
            }
        }
    }

    private static func image(from data: Data) -> Image? {
#if canImport(UIKit)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
#else
        return nil
#endif
    }
}

enum ProfileAvatarPhotoEncoder {

    static let maximumDimension: CGFloat = 256

    static func encode(_ data: Data) -> Data? {
#if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let longestSide = max(image.size.width, image.size.height)
        let scale = longestSide > maximumDimension ? maximumDimension / longestSide : 1
        let targetSize = CGSize(
            width: max(1, image.size.width * scale),
            height: max(1, image.size.height * scale)
        )

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        for quality in stride(from: 0.8, through: 0.3, by: -0.1) {
            guard let encoded = resized.jpegData(compressionQuality: quality) else { continue }
            if encoded.count <= ProfileAvatar.maximumPhotoBytes { return encoded }
        }
        return nil
#else
        return nil
#endif
    }
}

#if canImport(LocalAuthentication) && !os(tvOS)
enum ProfileDeviceAuthenticator {

    static var biometricsAvailable: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static var biometricDisplayName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "Biometrics"
        }
    }

    static func authenticate(
        reason: String,
        completion: @escaping (Bool) -> Void
    ) {
        let context = LAContext()

        context.localizedFallbackTitle = ""
        let policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics
        guard context.canEvaluatePolicy(policy, error: nil) else {
            completion(false)
            return
        }
        context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }
}
#endif

struct ProfilePINPad: View {
    @Binding var digits: String
    var length: Int = ProfilePINHasher.pinLength
    var accent: Color

    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 16) {
                ForEach(0..<length, id: \.self) { index in
                    Circle()
                        .fill(index < digits.count ? accent : Color.white.opacity(0.16))
                        .frame(width: 15, height: 15)
                }
            }

            VStack(spacing: isTvOS ? 20 : 12) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: isTvOS ? 20 : 12) {
                        ForEach(1...3, id: \.self) { column in
                            key("\(row * 3 + column)")
                        }
                    }
                }
                HStack(spacing: isTvOS ? 20 : 12) {
                    Color.clear.frame(width: isTvOS ? 100 : 68, height: isTvOS ? 90 : 58)
                    key("0")
                    Button {
                        if !digits.isEmpty { digits.removeLast() }
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.system(size: isTvOS ? 30 : 20, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: isTvOS ? 100 : 68, height: isTvOS ? 90 : 58)
                    }

#if os(tvOS)
                    .buttonStyle(TVGlassRowButtonStyle())
#else
                    .buttonStyle(.plain)
#endif
                    .disabled(digits.isEmpty)
                }
            }
        }
    }

    private func key(_ value: String) -> some View {
        Button {
            guard digits.count < length else { return }
            digits.append(value)
        } label: {
            Text(value)
                .font(.system(size: isTvOS ? 40 : 24, weight: .medium, design: .rounded))
                .foregroundColor(.white)
                .frame(width: isTvOS ? 100 : 68, height: isTvOS ? 90 : 58)
#if !os(tvOS)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
#endif
        }
#if os(tvOS)
        .buttonStyle(TVGlassRowButtonStyle())
#else
        .buttonStyle(.plain)
#endif
    }
}

struct ProfilePINEntryView: View {
    enum Mode {

        case unlock(Profile)
        case set(Profile)

        case authorize(Profile)

        var profile: Profile {
            switch self {
            case .unlock(let profile), .set(let profile), .authorize(let profile): return profile
            }
        }

        var allowsBiometrics: Bool {
            if case .unlock = self { return true }
            return false
        }
    }

    let mode: Mode
    let onFinished: (Bool) -> Void

    @Environment(\.presentationMode) private var presentationMode
    @StateObject private var accentColorManager = AccentColorManager.shared
    @State private var digits = ""
    @State private var confirmDigits = ""
    @State private var isConfirming = false
    @State private var errorMessage: String?

    private var accent: Color { accentColorManager.currentAccentColor }

    private var title: String {
        switch mode {
        case .unlock, .authorize: return "Enter PIN"
        case .set: return isConfirming ? "Confirm PIN" : "Choose a PIN"
        }
    }

    private var subtitle: String {
        switch mode {
        case .unlock(let profile):
            return "\(profile.name) is locked."
        case .authorize(let profile):
            return "Enter \(profile.name)'s PIN to change how it is protected."
        case .set:
            return isConfirming
                ? "Enter the same PIN again."
                : "A \(ProfilePINHasher.pinLength)-digit PIN protects this profile on this device."
        }
    }

    private var activeBinding: Binding<String> {
        isConfirming ? $confirmDigits : $digits
    }

    var body: some View {
        VStack(spacing: 20) {
            ProfileAvatarView(profile: mode.profile, size: 72)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }

            ProfilePINPad(digits: activeBinding, accent: accent)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            unlockAlternatives

            Button("Cancel") {
                onFinished(false)
                presentationMode.wrappedValue.dismiss()
            }
            .foregroundColor(isTvOS ? nil : Color.white.opacity(0.6))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsGradientBackground().ignoresSafeArea())
        .onChangeComp(of: digits) { _, _ in evaluate() }
        .onChangeComp(of: confirmDigits) { _, _ in evaluate() }
        .onAppear { offerBiometricsIfPossible() }
    }

    @ViewBuilder
    private var unlockAlternatives: some View {
#if canImport(LocalAuthentication) && !os(tvOS)

        if case .unlock(let profile) = mode, ProfileDeviceAuthenticator.biometricsAvailable {
            Button {
                authenticate(profile: profile)
            } label: {
                Label(
                    "Unlock with \(ProfileDeviceAuthenticator.biometricDisplayName)",
                    systemImage: "faceid"
                )
                .font(.subheadline.weight(.medium))
                .foregroundColor(accent)
            }
            .buttonStyle(.plain)
        }
#else
        EmptyView()
#endif
    }

    private func offerBiometricsIfPossible() {
#if canImport(LocalAuthentication) && !os(tvOS)
        guard mode.allowsBiometrics,
              case .unlock(let profile) = mode,
              ProfileDeviceAuthenticator.biometricsAvailable else { return }
        authenticate(profile: profile)
#endif
    }

#if canImport(LocalAuthentication) && !os(tvOS)
    private func authenticate(profile: Profile) {
        ProfileDeviceAuthenticator.authenticate(
            reason: "Unlock the \(profile.name) profile"
        ) { success in
            guard success else { return }
            onFinished(true)
            presentationMode.wrappedValue.dismiss()
        }
    }
#endif

    private func evaluate() {

        if !digits.isEmpty || !confirmDigits.isEmpty {
            errorMessage = nil
        }
        switch mode {
        case .unlock(let profile), .authorize(let profile):
            guard digits.count == ProfilePINHasher.pinLength else { return }
            if ProfileManager.shared.verifyPIN(digits, for: profile.id) {
                onFinished(true)
                presentationMode.wrappedValue.dismiss()
            } else {
                digits = ""
                errorMessage = "Incorrect PIN."
            }
        case .set(let profile):
            if !isConfirming {
                guard digits.count == ProfilePINHasher.pinLength else { return }
                isConfirming = true
                return
            }
            guard confirmDigits.count == ProfilePINHasher.pinLength else { return }
            guard confirmDigits == digits else {
                digits = ""
                confirmDigits = ""
                isConfirming = false
                errorMessage = "Those PINs did not match."
                return
            }
            let didSet = ProfileManager.shared.setPIN(digits, for: profile.id)
            onFinished(didSet)
            presentationMode.wrappedValue.dismiss()
        }
    }
}

struct ProfilesSettingsView: View {
    @StateObject private var profileManager = ProfileManager.shared
    @StateObject private var accentColorManager = AccentColorManager.shared

    @State private var editingProfile: Profile?
    @State private var isCreatingProfile = false
    @State private var pendingUnlock: Profile?
    @State private var profilePendingDeletion: Profile?
    @State private var pendingAuthorization: ProfileAuthorizationRequest?
    @State private var authorizedRequest: ProfileAuthorizationRequest?
    @State private var sharesServices = ProfileSettingsStore.sharesServices

    private var accent: Color { accentColorManager.currentAccentColor }

    private var isAdministrable: Bool {
        profileManager.activeProfile?.isKidsProfile != true
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "Profiles") {
                    VStack(spacing: 0) {
                        ForEach(Array(profileManager.profiles.enumerated()), id: \.element.id) { index, profile in
                            profileRow(profile)
                            if index < profileManager.profiles.count - 1 {
                                GlassDivider()
                            }
                        }
                    }
                }

                if isAdministrable {
                GlassSection {
                    VStack(spacing: 0) {
                        Button {
                            isCreatingProfile = true
                        } label: {
                            GlassSettingsRow(
                                icon: "plus.circle.fill",
                                iconColor: accent,
                                title: "Add Profile"
                            ) {
                                Text("\(profileManager.profiles.count)/\(ProfileManager.maximumProfiles)")
                                    .font(.subheadline)
                                    .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.5))
                            }
                        }
#if os(tvOS)
                        .buttonStyle(.card)
#else
                        .buttonStyle(.plain)
#endif
                        .disabled(profileManager.profiles.count >= ProfileManager.maximumProfiles)
                        .opacity(profileManager.profiles.count >= ProfileManager.maximumProfiles ? 0.4 : 1)
                    }
                }
                } else {
                    Text("This is a kids profile, so it cannot add, edit, or remove profiles. Switch to a grown-up profile to make those changes.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }

                if profileManager.hasMultipleProfiles, isAdministrable {
                    GlassSection(header: "On Launch") {
                        ProfileToggleRow(
                            icon: "person.2.fill",
                            iconColor: accent,
                            title: "Ask on Launch",
                            accent: accent,
                            isOn: $profileManager.asksOnLaunch
                        )
                    }

                    Text(launchPromptFooter)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }

                if isAdministrable {
                    GlassSection(header: "Sharing") {
                        ProfileToggleRow(
                            icon: "shippingbox.fill",
                            iconColor: accent,
                            title: "Share Services",
                            accent: accent,
                            isOn: Binding(
                                get: { sharesServices },
                                set: { newValue in
                                    sharesServices = newValue
                                    ProfileSettingsStore.sharesServices = newValue
                                    ServiceStoreScope.activeProfileDidChange()
                                }
                            )
                        )
                    }

                    Text(sharesServices
                        ? "Every profile uses the same services, Stremio addons, plugins, and stream rules. Turn this off to give each profile its own — the current setup is copied across the first time a profile needs it, and they go their own way from there."
                        : "Each profile has its own services, addons, plugins, and stream rules. Turn this back on to put everyone on the shared set again.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }

                Text(profileScopeSummary)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Profiles")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(mode: .edit(profile))
        }
        .sheet(isPresented: $isCreatingProfile) {
            ProfileEditorView(mode: .create)
        }
        .sheet(item: $pendingUnlock) { profile in
            ProfilePINEntryView(mode: .unlock(profile)) { success in
                if success {
                    ProfileManager.shared.switchProfile(to: profile.id)
                }
            }
        }
        .sheet(item: $pendingAuthorization, onDismiss: {
            guard let request = authorizedRequest else { return }
            authorizedRequest = nil
            perform(request.action, on: request.profile)
        }) { request in
            ProfilePINEntryView(mode: .authorize(request.profile)) { success in
                guard success else { return }
                authorizedRequest = request
            }
        }
        .alert(item: $profilePendingDeletion) { profile in
            Alert(
                title: Text("Delete \(profile.name)?"),
                message: Text("This profile's watch progress, library, and ratings are removed from this device and from your synced accounts. Downloads are shared and stay put."),
                primaryButton: .destructive(Text("Delete")) {
                    ProfileManager.shared.deleteProfile(profile.id)
                },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: Profile) -> some View {
        let isActive = profile.id == profileManager.activeProfileID

        HStack(spacing: 14) {
            Button {
                activate(profile)
            } label: {
                HStack(spacing: 14) {
                    ProfileAvatarView(
                        profile: profile,
                        size: 44,
                        isSelected: isActive,
                        selectionColor: accent
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .font(.body.weight(isActive ? .semibold : .regular))
                            .foregroundColor(isTvOS ? Color.primary : Color.white)
                        Text(subtitle(for: profile, isActive: isActive))
                            .font(.caption)
                            .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.5))
                    }

                    Spacer(minLength: 0)

                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(accent)
                    }
                }
            }
#if os(tvOS)
            .buttonStyle(.card)
#else
            .buttonStyle(.plain)
#endif

            if isAdministrable {
                Button {
                    request(.edit, on: profile)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(isTvOS ? Color.primary : Color.white.opacity(0.55))
                        .frame(width: 34, height: 34)
                }
#if os(tvOS)
                .buttonStyle(.bordered)
#else
                .buttonStyle(.plain)
#endif

                let canDelete = profileManager.profiles.count > 1
                    && profile.id != ProfileManager.defaultProfileID
                Button {
                    request(.delete, on: profile)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(canDelete ? Color.red.opacity(0.85) : (isTvOS ? Color.secondary : Color.white.opacity(0.2)))
                        .frame(width: 34, height: 34)
                }
#if os(tvOS)
                .buttonStyle(.bordered)
#else
                .buttonStyle(.plain)
#endif

                .disabled(!canDelete)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, isTvOS ? 14 : 11)
    }

    private var launchPromptFooter: String {
        if profileManager.asksOnLaunch {
#if os(tvOS)
            return "Eclipse asks who's watching each time it starts. Turn this off to open straight into the profile you used last."
#else
            return "Eclipse asks who's watching — or who's reading — each time it starts. Turn this off to open straight into the profile you used last."
#endif
        }
        if profileManager.activeProfile?.isLocked == true {
            return "Eclipse opens straight into \(profileManager.activeProfile?.name ?? "your last profile"). Because that profile has a PIN, it still asks to unlock before letting you in."
        }
        return "Eclipse opens straight into the profile you used last. Switch profiles any time from here. A profile with a PIN always asks to unlock, even with this off."
    }

    private var profileScopeSummary: String {
#if os(tvOS)
        "Each profile keeps its own appearance, player, and language settings, plus its own watch progress, library, ratings, and tracker accounts. Diagnostics are shared across profiles on this Apple TV."
#else
        "Each profile keeps its own settings — appearance, player, reader, and language — plus its own watch progress, library, ratings, and tracker accounts. Downloads and diagnostics are shared across profiles on this device."
#endif
    }

    private func subtitle(for profile: Profile, isActive: Bool) -> String {
        var parts: [String] = []
        if isActive { parts.append("Active") }
        if profile.isKidsProfile { parts.append("Kids") }
        if profile.isLocked { parts.append("PIN") }
#if os(tvOS)
        return parts.isEmpty ? "Select to switch" : parts.joined(separator: " · ")
#else
        return parts.isEmpty ? "Tap to switch" : parts.joined(separator: " · ")
#endif
    }

    private func request(_ action: ProfileAuthorizationRequest.Action, on profile: Profile) {
        guard profile.isLocked else {
            perform(action, on: profile)
            return
        }
        pendingAuthorization = ProfileAuthorizationRequest(action: action, profile: profile)
    }

    private func perform(_ action: ProfileAuthorizationRequest.Action, on profile: Profile) {
        switch action {
        case .edit: editingProfile = profile
        case .delete: profilePendingDeletion = profile
        }
    }

    private func activate(_ profile: Profile) {
        guard profile.id != profileManager.activeProfileID else { return }
        if profile.isLocked {
            pendingUnlock = profile
        } else {
            ProfileManager.shared.switchProfile(to: profile.id)
        }
    }
}

struct ProfileAuthorizationRequest: Identifiable {
    enum Action {
        case edit
        case delete
    }

    let action: Action
    let profile: Profile

    var id: String {
        switch action {
        case .edit: return "edit-\(profile.id.uuidString)"
        case .delete: return "delete-\(profile.id.uuidString)"
        }
    }
}

private struct ProfileToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let accent: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [iconColor.opacity(0.82), Color.white.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                )

            Text(title)
                .font(.body.weight(.medium))
                .foregroundColor(.white)

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct ProfileEditorView: View {
    enum Mode {
        case create
        case edit(Profile)
    }

    let mode: Mode

    @Environment(\.presentationMode) private var presentationMode
    @StateObject private var accentColorManager = AccentColorManager.shared

    @State private var name: String = ""
    @State private var avatarSymbol: String = ProfileAvatar.defaultSymbol
    @State private var avatarColorHex: String = ProfileAvatar.defaultColorHex
    @State private var avatarPhotoData: Data?
    @State private var isKidsProfile = false
    @State private var isSettingPIN = false
    @State private var hasPIN = false

    private var accent: Color { accentColorManager.currentAccentColor }

    private var kidsProfileSymbol: String {
        if #available(iOS 16.0, tvOS 16.0, *) {
            return "figure.and.child.holdinghands"
        }
        return "person.2.fill"
    }

    private var existingProfile: Profile? {
        if case .edit(let profile) = mode { return profile }
        return nil
    }

    private var previewProfile: Profile {
        Profile(
            id: existingProfile?.id ?? ProfileManager.defaultProfileID,
            name: name.isEmpty ? "New Profile" : name,
            avatarSymbol: avatarSymbol,
            avatarColorHex: avatarColorHex,
            avatarPhotoData: avatarPhotoData,
            isKidsProfile: isKidsProfile
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {

                    HStack {
                        Button("Cancel") { presentationMode.wrappedValue.dismiss() }
                            .foregroundColor(isTvOS ? nil : Color.white.opacity(0.7))
                        Spacer()
                        Text(existingProfile == nil ? "New Profile" : "Edit Profile")
                            .font(.headline)
                            .foregroundColor(.white)
                        Spacer()
                        Button("Save") { save() }
                            .foregroundColor(
                                name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? .white.opacity(0.3)
                                    : accent
                            )
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                    ProfileAvatarView(profile: previewProfile, size: 96, showsLockBadge: hasPIN)
                        .padding(.top, 12)

                    GlassSection(header: "Name") {
                        TextField("Profile name", text: $name)
                            .textFieldStyle(.plain)
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }

                    photoSection

                    GlassSection(header: "Symbol") {
                        symbolGrid
                    }

                    GlassSection(header: "Color") {
                        colorGrid
                    }

                    GlassSection(header: "Options") {
                        VStack(spacing: 0) {
                            ProfileToggleRow(
                                icon: kidsProfileSymbol,
                                iconColor: .green,
                                title: "Kids Profile",
                                accent: accent,
                                isOn: $isKidsProfile
                            )
                            .disabled(!canBecomeKidsProfile)
                            .opacity(canBecomeKidsProfile ? 1 : 0.5)

                            if !canBecomeKidsProfile {
                                Text("At least one grown-up profile has to stay. Kids profiles can't add, edit, or delete profiles, so turning this one into a kids profile would leave nobody able to change it back.")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.bottom, 12)
                            }

                            GlassDivider()

                            if let profile = existingProfile {
                                pinRow(for: profile)
                            } else {
                                Text("A PIN can be set once the profile exists.")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.5))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                            }
                        }
                    }

                    if isKidsProfile {
                        Text("Kids profiles hide adult, horror, and other mature titles across home, search, and catalogs.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 32)
        }
        .background(SettingsGradientBackground().ignoresSafeArea())
        .onAppear(perform: loadInitialState)
        .sheet(isPresented: $isSettingPIN) {
            if let profile = existingProfile {
                ProfilePINEntryView(mode: .set(profile)) { success in
                    if success { hasPIN = true }
                }
            }
        }
    }

    @ViewBuilder
    private var photoSection: some View {
#if canImport(PhotosUI) && !os(tvOS)

        if #available(iOS 16.0, macCatalyst 16.0, *) {
            GlassSection(header: "Photo") {
                VStack(spacing: 0) {
                    ProfilePhotoPickerRow(
                        accent: accent,
                        hasPhoto: avatarPhotoData != nil,
                        onPicked: { data in avatarPhotoData = data }
                    )

                    if avatarPhotoData != nil {
                        GlassDivider()
                        Button {
                            avatarPhotoData = nil
                        } label: {
                            GlassSettingsRow(
                                icon: "arrow.uturn.backward",
                                iconColor: .orange,
                                title: "Use Symbol Instead"
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
#else
        EmptyView()
#endif
    }

    private var offeredSymbols: [String] {
        guard !ProfileAvatar.symbols.contains(avatarSymbol) else { return ProfileAvatar.symbols }
        return [avatarSymbol] + ProfileAvatar.symbols
    }

    private var offeredColorHexes: [String] {
        guard !ProfileAvatar.colorHexes.contains(avatarColorHex) else { return ProfileAvatar.colorHexes }
        return [avatarColorHex] + ProfileAvatar.colorHexes
    }

    private var symbolGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 56), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(offeredSymbols, id: \.self) { symbol in
                Button {
                    avatarSymbol = symbol
                } label: {
                    Image(systemName: ProfileAvatar.renderableSymbolName(symbol))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
#if !os(tvOS)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color.white.opacity(avatarSymbol == symbol ? 0.18 : 0.07))
                        )
#endif
                        .overlay(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .strokeBorder(
                                    avatarSymbol == symbol ? accent : Color.white.opacity(0.12),
                                    lineWidth: avatarSymbol == symbol ? 2.5 : 1
                                )
                        )
                }
#if os(tvOS)
                .buttonStyle(TVGlassRowButtonStyle())
#else
                .buttonStyle(.plain)
#endif
            }
        }
        .padding(14)
    }

    private var colorGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 56), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(offeredColorHexes, id: \.self) { hex in
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
                .buttonStyle(TVGlassRowButtonStyle())
#else
                .buttonStyle(.plain)
#endif
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func pinRow(for profile: Profile) -> some View {
        VStack(spacing: 0) {
            Button {
                isSettingPIN = true
            } label: {
                GlassSettingsRow(
                    icon: "lock.fill",
                    iconColor: .yellow,
                    title: hasPIN ? "Change PIN" : "Set PIN"
                ) {
                    Text(hasPIN ? "On" : "Off")
                        .font(.subheadline)
                        .foregroundColor(isTvOS ? Color.secondary : Color.white.opacity(0.5))
                }
            }
#if os(tvOS)
            .buttonStyle(.card)
#else
            .buttonStyle(.plain)
#endif

            if hasPIN {
                GlassDivider()
                Button {
                    ProfileManager.shared.clearPIN(for: profile.id)
                    hasPIN = false
                } label: {
                    GlassSettingsRow(icon: "lock.open.fill", iconColor: .red, title: "Remove PIN")
                }
#if os(tvOS)
                .buttonStyle(.card)
#else
                .buttonStyle(.plain)
#endif
            }
        }
    }

    private func loadInitialState() {
        guard let profile = existingProfile else { return }
        name = profile.name
        avatarSymbol = profile.avatarSymbol
        avatarColorHex = profile.avatarColorHex
        avatarPhotoData = profile.avatarPhotoData
        isKidsProfile = profile.isKidsProfile
        hasPIN = profile.isLocked
    }

    private var canBecomeKidsProfile: Bool {
        guard let profile = existingProfile else { return true }
        if profile.isKidsProfile { return true }
        return ProfileManager.shared.canConvertToKidsProfile(id: profile.id)
    }

    private func save() {
        if var profile = existingProfile {
            profile.name = name
            profile.avatarSymbol = avatarSymbol
            profile.avatarColorHex = avatarColorHex
            profile.avatarPhotoData = avatarPhotoData
            profile.isKidsProfile = isKidsProfile

            profile.pinHash = ProfileManager.shared.profile(with: profile.id)?.pinHash
            ProfileManager.shared.updateProfile(profile)
        } else {
            ProfileManager.shared.createProfile(
                name: name,
                avatarSymbol: avatarSymbol,
                avatarColorHex: avatarColorHex,
                avatarPhotoData: avatarPhotoData,
                isKidsProfile: isKidsProfile
            )
        }
        presentationMode.wrappedValue.dismiss()
    }
}

#if canImport(PhotosUI) && !os(tvOS)
@available(iOS 16.0, macCatalyst 16.0, *)
private struct ProfilePhotoPickerRow: View {
    let accent: Color
    let hasPhoto: Bool
    let onPicked: (Data?) -> Void

    @State private var selection: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $selection, matching: .images, photoLibrary: .shared()) {
            GlassSettingsRow(
                icon: "photo.fill",
                iconColor: accent,
                title: hasPhoto ? "Change Photo" : "Choose Photo"
            )
        }
        .buttonStyle(.plain)
        .onChangeComp(of: selection) { _, item in
            guard let item else { return }
            Task {
                guard let raw = try? await item.loadTransferable(type: Data.self) else { return }
                let encoded = ProfileAvatarPhotoEncoder.encode(raw)
                await MainActor.run { onPicked(encoded) }
            }
        }
    }
}
#endif

struct ProfilePickerView: View {
    var isReaderMode: Bool = false

    var autoUnlockProfile: Profile?
    let onFinished: () -> Void

    @StateObject private var profileManager = ProfileManager.shared
    @StateObject private var accentColorManager = AccentColorManager.shared
    @State private var pendingUnlock: Profile?
    @Environment(\.eclipseStartupOverlayVisible) private var startupOverlayVisible

    private var accent: Color { accentColorManager.currentAccentColor }

    var body: some View {
        ZStack {
            SettingsGradientBackground().ignoresSafeArea()

            VStack(spacing: 28) {
                Text(isReaderMode ? "Who's reading?" : "Who's watching?")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 110), spacing: 22)],
                    spacing: 22
                ) {
                    ForEach(profileManager.profiles) { profile in
                        Button {
                            select(profile)
                        } label: {
                            VStack(spacing: 10) {
                                ProfileAvatarView(
                                    profile: profile,
                                    size: 92,
                                    isSelected: profile.id == profileManager.activeProfileID,
                                    selectionColor: accent
                                )
                                Text(profile.name)
                                    .font(.subheadline)
                                    .foregroundColor(isTvOS ? Color.primary : Color.white.opacity(0.85))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                        }
#if os(tvOS)
                        .buttonStyle(.card)
#else
                        .buttonStyle(.plain)
#endif
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .sheet(item: $pendingUnlock) { profile in
            ProfilePINEntryView(mode: .unlock(profile)) { success in
                guard success else { return }

                ProfileManager.shared.switchProfile(to: profile.id)
                onFinished()
            }
        }
        .onAppear {
            guard !startupOverlayVisible, let autoUnlockProfile, pendingUnlock == nil else { return }
            pendingUnlock = autoUnlockProfile
        }
        .onChangeComp(of: startupOverlayVisible) { _, visible in
            guard !visible, let autoUnlockProfile, pendingUnlock == nil else { return }
            pendingUnlock = autoUnlockProfile
        }
    }

    private func select(_ profile: Profile) {
        if profile.isLocked {
            pendingUnlock = profile
        } else {
            ProfileManager.shared.switchProfile(to: profile.id)
            onFinished()
        }
    }
}
