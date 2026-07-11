// Translucent glass card group container with thin separators

import SwiftUI

// MARK: - Glass Card Group

struct GlassCardGroup<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .background(cardBackground)
    }

    @ViewBuilder
    private var cardBackground: some View {
#if !os(tvOS)
        if ExperimentalFeatureState.isEnabledAtLaunch {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.16, green: 0.13, blue: 0.22).opacity(0.88),
                            Color(red: 0.09, green: 0.09, blue: 0.15).opacity(0.78)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.54, green: 0.44, blue: 0.95).opacity(0.38),
                                    Color.white.opacity(0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color(red: 0.05, green: 0.03, blue: 0.12).opacity(0.30), radius: 14, x: 0, y: 8)
        } else {
            legacyCardBackground
        }
#else
        legacyCardBackground
#endif
    }

    private var legacyCardBackground: some View {
        RoundedRectangle(cornerRadius: EclipseTheme.shared.cardCornerRadius, style: .continuous)
            .fill(EclipseTheme.shared.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: EclipseTheme.shared.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
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
        HStack(spacing: 12) {
            settingsIcon
            
            Text(title)
                .font(rowTitleFont)
                .foregroundColor(.white)
            
            Spacer()
            
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, rowVerticalPadding)
        .contentShape(Rectangle())
    }

    private var iconSize: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch ? 16 : 15
    }

    private var iconFrame: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch ? 36 : 32
    }

    @ViewBuilder
    private var settingsIcon: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: iconFrame, height: iconFrame)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    iconColor.opacity(0.82),
                                    Color.white.opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                )
        } else {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: iconFrame, height: iconFrame)
                .background(iconColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var rowTitleFont: Font {
        ExperimentalFeatureState.isEnabledAtLaunch ? .body.weight(.medium) : .body
    }

    private var rowVerticalPadding: CGFloat {
        ExperimentalFeatureState.isEnabledAtLaunch ? 12 : 13
    }
}

// Convenience for NavigationLink rows with chevron
extension GlassSettingsRow where Trailing == AnyView {
    init(icon: String, iconColor: Color = .white, title: String) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.trailing = AnyView(
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.3))
        )
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
        VStack(alignment: .leading, spacing: 8) {
            if let header = header {
                Text(header)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(EclipseTheme.shared.sectionHeaderColor)
                    .padding(.horizontal, 18)
            }
            
            GlassCardGroup {
                content
            }
            .padding(.horizontal, 14)
        }
    }
}

// MARK: - Glass Divider

struct GlassDivider: View {
    /// Leading inset. Defaults to 54 so the rule starts after a row icon;
    /// pass 16 for icon-less rows.
    var leadingInset: CGFloat = 54

    var body: some View {
        Rectangle()
            .fill(EclipseTheme.shared.separatorColor)
            .frame(height: 0.5)
            .padding(.leading, leadingInset)
    }
}

// MARK: - Shared settings row pieces
//
// Building blocks for glass settings sub-menus so every screen shares the same
// row anatomy as the main Settings page (icon bubble, white title, secondary
// detail). Use these instead of native List rows when rebuilding a sub-menu.

/// The rounded icon bubble used on the left of settings rows.
struct GlassRowIcon: View {
    let icon: String
    var iconColor: Color = .white

    var body: some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
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
        } else {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 32, height: 32)
                .background(iconColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// A settings row with an optional icon, a title, an optional multi-line
/// subtitle and optional trailing content.
struct GlassDetailRow<Trailing: View>: View {
    let icon: String?
    let iconColor: Color
    let title: String
    let subtitle: String?
    let trailing: () -> Trailing

    init(
        icon: String? = nil,
        iconColor: Color = .white,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                GlassRowIcon(icon: icon, iconColor: iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ExperimentalFeatureState.isEnabledAtLaunch ? .body.weight(.medium) : .body)
                    .foregroundColor(.white)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// A glass slider row with a title, optional subtitle and a live value readout.
struct GlassSliderRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    var tint: Color = .white
    var valueFormat: String = "%.2f"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundColor(.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Text(String(format: valueFormat, value))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .monospacedDigit()
            }
#if os(tvOS)
            HStack(spacing: 18) {
                Button {
                    value = max(range.lowerBound, value - step)
                } label: {
                    Label("Decrease \(title)", systemImage: "minus")
                }
                .disabled(value <= range.lowerBound)

                Button {
                    value = min(range.upperBound, value + step)
                } label: {
                    Label("Increase \(title)", systemImage: "plus")
                }
                .disabled(value >= range.upperBound)
            }
#else
            Slider(value: $value, in: range, step: step)
                .tint(tint)
#endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// A selectable (checkmark) row used by inline pickers like language or mode.
struct GlassSelectionRow: View {
    var icon: String? = nil
    var iconColor: Color = .white
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    var accent: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon {
                    GlassRowIcon(icon: icon, iconColor: iconColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(ExperimentalFeatureState.isEnabledAtLaunch ? .body.weight(.medium) : .body)
                        .foregroundColor(.white)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.5))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(accent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Caption text shown beneath a `GlassSection`, mirroring a List section footer.
struct GlassSectionFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.white.opacity(0.45))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, -2)
    }
}

// MARK: - Shared design-system components
//
// Reusable pieces consumed by Home, Media Detail, Downloads, Schedule and the
// libraries so every screen shares one card / badge / empty-state language.

extension View {
    /// Wrap content in the shared glass treatment at the token card radius.
    func glassCard(cornerRadius: CGFloat? = nil) -> some View {
        applyLiquidGlassBackground(cornerRadius: cornerRadius ?? EclipseRadius.card)
    }
}

/// A consistent section header (title + optional count + optional chevron).
struct EclipseSectionHeader: View {
    let title: String
    var count: Int? = nil
    var showsChevron: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(EclipseType.sectionHeader)
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            if let count {
                Text("\(count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }

            Spacer(minLength: 0)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
    }
}

/// A small status / format pill (Downloading, Paused, OVA, etc.).
struct EclipseStatusBadge: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.85)))
    }
}

/// A consistent empty-state block with an optional call to action.
struct EclipseEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .regular))
                .foregroundColor(.white.opacity(0.5))

            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
    }
}

/// A circular progress ring with a centered percentage, for downloads.
struct DownloadProgressRing: View {
    var progress: Double
    var tint: Color = .white
    var size: CGFloat = 36
    var lineWidth: CGFloat = 3

    private var clamped: CGFloat { CGFloat(max(0, min(progress, 1))) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(clamped * 100))")
                .font(.system(size: size * 0.30, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}
