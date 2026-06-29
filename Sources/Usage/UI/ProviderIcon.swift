import AppKit
import SwiftUI

/// Renders a provider's bundled SVG icon, falling back to its SF Symbol when the asset is missing or
/// can't be decoded.
struct ProviderIcon: View {
    let info: ProviderInfo
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = Self.image(for: info.id, colorScheme: colorScheme) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(iconColor)
        } else {
            Image(systemName: info.fallbackSymbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(iconColor)
        }
    }

    private var iconColor: Color {
        colorScheme == .dark ? .white : .black
    }

    /// Cache decoded NSImages so we don't re-read the bundle on every redraw.
    private static let cache = NSCache<NSString, NSImage>()

    private static func image(for id: String, colorScheme: ColorScheme) -> NSImage? {
        let variant = colorScheme == .dark ? "light" : "dark"
        let cacheKey = "\(id).\(variant)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }

        let themedName = "\(id)_\(variant)"
        let url =
            Bundle.module.url(
                forResource: themedName, withExtension: "svg", subdirectory: "ProviderIcons")
            ?? Bundle.module.url(forResource: themedName, withExtension: "svg")
            ?? Bundle.module.url(
                forResource: id, withExtension: "svg", subdirectory: "ProviderIcons")
            ?? Bundle.module.url(forResource: id, withExtension: "svg")
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true

        cache.setObject(image, forKey: cacheKey)
        return image
    }
}
