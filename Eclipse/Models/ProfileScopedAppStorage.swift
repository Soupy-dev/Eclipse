import SwiftUI

struct ProfileScopedAppStorage<Content: View>: View {

    @ObservedObject private var profileManager = ProfileManager.shared
    private let content: Content

    init(_ content: Content) {
        self.content = content
    }

    var body: some View {
        content.defaultAppStorage(
            ProfileSettingsStore.shared.store(for: profileManager.activeProfileID)
        )
    }
}

extension View {

    func profileScopedAppStorage() -> ProfileScopedAppStorage<Self> {
        ProfileScopedAppStorage(self)
    }
}
