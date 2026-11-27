#if os(iOS)
import DesignSystem
import PlainShared
import SwiftUI
import WidgetKit

/// The search widget's face for every family. Paper and a dawn window, the brand's two surfaces
/// (Brand/identity.md); in the tinted and clear Home Screen styles (`widgetRenderingMode`
/// `.accented`) the same shapes are drawn as outlines in the tint.
public struct SearchWidgetView: View {
    let entry: SearchEntry
    @Environment(\.widgetFamily) private var family

    public init(entry: SearchEntry) {
        self.entry = entry
    }

    public var body: some View {
        content
            .widgetURL(PlainLink.url(for: .focusSearch))
            .containerBackground(for: .widget) { WidgetPaper() }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: AccessoryCircular()
        case .accessoryRectangular: AccessoryRectangular()
        case .accessoryInline: Label("Search Plain", systemImage: "magnifyingglass")
        case .systemMedium: MediumSearch(favorites: entry.content.favorites)
        default: SmallSearch()
        }
    }
}

// MARK: Home Screen and StandBy

/// Small: the dawn window over a search field. The whole widget opens the search field.
struct SmallSearch: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DawnWindow()
            SearchField(label: "Search", height: 40)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Search in Plain")
        .accessibilityAddTraits(.isButton)
    }
}

/// Medium: the search field, then the first favorites as tap targets. Without favorites, the
/// dawn window fills the row and the whole widget searches.
struct MediumSearch: View {
    let favorites: [SharedFavorite]

    var body: some View {
        VStack(spacing: 12) {
            Link(destination: PlainLink.url(for: .focusSearch)) {
                SearchField(label: "Search or enter address", height: 40)
            }
            .accessibilityLabel("Search in Plain")
            if favorites.isEmpty {
                DawnWindow()
            } else {
                // Four equal slots; fewer favorites keep the slot width and sit centered.
                GeometryReader { geometry in
                    let slot = geometry.size.width / CGFloat(SearchWidgetContent.favoriteSlots)
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(favorites) { favorite in
                            Link(destination: PlainLink.url(for: .open(favorite.url))) {
                                FavoriteDisc(favorite: favorite)
                            }
                            .frame(width: slot)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
    }
}

/// The address field as the app's resting pill draws it: a plain capsule with a Lagoon glass. No
/// focus rim: the widget can't take typing, it opens the field that can.
struct SearchField: View {
    let label: LocalizedStringKey
    let height: CGFloat
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(mode == .fullColor ? AnyShapeStyle(Color(Palette.accentOnGlass)) : AnyShapeStyle(.primary))
                .widgetAccentable()
            Text(label)
                .font(.subheadline)
                .foregroundStyle(mode == .fullColor ? AnyShapeStyle(Color(Palette.textSecondary)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background {
            if mode == .fullColor {
                Capsule().fill(Color(Palette.surface))
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.06), lineWidth: 1))
            } else {
                Capsule().fill(.primary.opacity(0.14))
            }
        }
    }
}

/// A favorite: the monogram disc and its name, as above the keyboard in the app.
struct FavoriteDisc: View {
    let favorite: SharedFavorite
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        VStack(spacing: 5) {
            Text(favorite.monogram)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(mode == .fullColor ? AnyShapeStyle(Color(Palette.accentOnGlass)) : AnyShapeStyle(.primary))
                .widgetAccentable()
                .frame(width: 44, height: 44)
                .background(Circle().fill(mode == .fullColor ? AnyShapeStyle(Color(Palette.surface)) : AnyShapeStyle(.primary.opacity(0.14))))
            Text(favorite.title)
                .font(.caption2)
                .foregroundStyle(mode == .fullColor ? AnyShapeStyle(Color(Palette.textPrimary)) : AnyShapeStyle(.primary))
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(favorite.title)
        .accessibilityAddTraits(.isLink)
    }
}

/// The mark's view through the paper ring: a dawn sky, a coral sun rising over the rim of a
/// deep-blue planet, a thin mint atmosphere (Brand/identity.md). Drawn with shapes, so it is crisp
/// at every size and costs no image.
struct DawnWindow: View {
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let horizon = size.height * 0.8
            // The rim drops about an eighth of the window's height at the edges, whatever its
            // width, so a wide window never shows sky under the planet's corners.
            let planet = CGSize(width: size.width * 2.4, height: size.height * 2.64)
            // A wide, shallow window gets a larger sun, so it still reads as the mark's dawn.
            let sun = min(size.width * 0.5, size.height * 0.62)
            ZStack {
                if mode == .fullColor {
                    LinearGradient(colors: BrandArt.dawnSky.map(Color.init), startPoint: .top, endPoint: .bottom)
                    Circle()
                        .fill(RadialGradient(
                            colors: BrandArt.sun.map(Color.init), center: .center, startRadius: 0, endRadius: sun / 2
                        ))
                        .frame(width: sun, height: sun)
                        .position(x: size.width * 0.5, y: horizon)
                    Ellipse()
                        .fill(LinearGradient(colors: BrandArt.planet.map(Color.init), startPoint: .top, endPoint: .bottom))
                        .overlay(Ellipse().stroke(Color(BrandArt.rim), lineWidth: 1.5))
                        .frame(width: planet.width, height: planet.height)
                        .position(x: size.width / 2, y: horizon + planet.height / 2)
                } else {
                    Rectangle().fill(.primary.opacity(0.1))
                    Circle()
                        .stroke(.primary, lineWidth: 1.5)
                        .frame(width: sun, height: sun)
                        .position(x: size.width * 0.5, y: horizon)
                        .widgetAccentable()
                    Ellipse()
                        .fill(.background)
                        .overlay(Ellipse().stroke(.primary, lineWidth: 1.5))
                        .frame(width: planet.width, height: planet.height)
                        .position(x: size.width / 2, y: horizon + planet.height / 2)
                        .widgetAccentable()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityHidden(true)
    }
}

/// Paper (Deep Lagoon when dark), flat: the dawn window carries the color.
struct WidgetPaper: View {
    var body: some View {
        Color(Palette.background)
    }
}

// MARK: Lock Screen

struct AccessoryCircular: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .semibold))
        }
        .accessibilityLabel("Search in Plain")
    }
}

struct AccessoryRectangular: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
            VStack(alignment: .leading, spacing: 0) {
                Text("Search").font(.headline).widgetAccentable()
                Text("Plain").font(.caption)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Search in Plain")
    }
}
#endif
