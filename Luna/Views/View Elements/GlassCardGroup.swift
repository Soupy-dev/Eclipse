//
//  GlassCardGroup.swift
//  Luna
//
//  Translucent glass card group container with thin separators
//

import SwiftUI

// MARK: - Glass Card Group

struct GlassCardGroup<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: LunaTheme.shared.cardCornerRadius, style: .continuous)
                    .fill(LunaTheme.shared.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: LunaTheme.shared.cardCornerRadius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
            )
    }
}

// MARK: - Settings Row

struct GlassSettingsRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let trailing: Trailing
    
    init(
        icon: String,
        iconColor: Color = .white,
        title: String,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.trailing = trailing()
    }
    
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            
            Text(title)
                .font(.body)
                .foregroundColor(.white)
            
            Spacer()
            
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

// Convenience for NavigationLink rows with chevron
extension GlassSettingsRow where Trailing == Image {
    init(icon: String, iconColor: Color = .white, title: String) {
        self.init(icon: icon, iconColor: iconColor, title: title) {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.3))
        }
    }
}

// MARK: - Glass Section

struct GlassSection<Content: View>: View {
    let header: String?
    let content: Content
    
    init(header: String? = nil, @ViewBuilder content: () -> Content) {
        self.header = header
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let header = header {
                Text(header)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(LunaTheme.shared.sectionHeaderColor)
                    .padding(.horizontal, 20)
            }
            
            GlassCardGroup {
                content
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Glass Divider

struct GlassDivider: View {
    var body: some View {
        Rectangle()
            .fill(LunaTheme.shared.separatorColor)
            .frame(height: 0.5)
            .padding(.leading, 62)
    }
}
