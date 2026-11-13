import AppKit
import SwiftUI

struct WindowPreviewCardStyle {
    var containerCornerRadius: CGFloat = 10
    var imageCornerRadius: CGFloat = 8
    var imagePadding: CGFloat = 8
    var background: Color = Palette.surface.opacity(0.8)
    var border: Color = Palette.border
    var placeholderForeground: Color = Palette.textMuted
    var placeholderSecondary: Color = Palette.textDim
}

struct WindowPreviewCard<Overlay: View>: View {
    let image: NSImage?
    let isLoading: Bool
    let appName: String
    var loadingTitle: String = "Capturing preview"
    var unavailableTitle: String = "Preview unavailable"
    var style: WindowPreviewCardStyle = WindowPreviewCardStyle()
    var holdingPreviousPreview: Bool = false
    @ViewBuilder let overlay: () -> Overlay

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: style.containerCornerRadius)
                .fill(style.background)
                .overlay(
                    RoundedRectangle(cornerRadius: style.containerCornerRadius)
                        .strokeBorder(style.border, lineWidth: 0.5)
                )

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: style.imageCornerRadius))
                    .padding(style.imagePadding)
                    .opacity(holdingPreviousPreview ? 0.88 : 1)
            } else if isLoading {
                WindowPreviewPlaceholder(
                    icon: "photo",
                    title: loadingTitle,
                    subtitle: appName,
                    foreground: style.placeholderForeground,
                    secondary: style.placeholderSecondary
                )
            } else {
                WindowPreviewPlaceholder(
                    icon: "eye.slash",
                    title: unavailableTitle,
                    subtitle: appName,
                    foreground: style.placeholderForeground,
                    secondary: style.placeholderSecondary
                )
            }

            overlay()
        }
    }
}

extension WindowPreviewCard where Overlay == EmptyView {
    init(
        image: NSImage?,
        isLoading: Bool,
        appName: String,
        loadingTitle: String = "Capturing preview",
        unavailableTitle: String = "Preview unavailable",
        style: WindowPreviewCardStyle = WindowPreviewCardStyle(),
        holdingPreviousPreview: Bool = false
    ) {
        self.init(
            image: image,
            isLoading: isLoading,
            appName: appName,
            loadingTitle: loadingTitle,
            unavailableTitle: unavailableTitle,
            style: style,
            holdingPreviousPreview: holdingPreviousPreview,
            overlay: { EmptyView() }
        )
    }
}

private struct WindowPreviewPlaceholder: View {
    let icon: String
    let title: String
    let subtitle: String
    let foreground: Color
    let secondary: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(foreground.opacity(0.7))
            Text(title)
                .font(Typo.monoBold(10))
                .foregroundColor(foreground)
            Text(subtitle)
                .font(Typo.mono(9))
                .foregroundColor(secondary)
                .lineLimit(1)
        }
        .padding(16)
    }
}
