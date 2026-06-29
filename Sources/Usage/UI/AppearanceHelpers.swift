import SwiftUI

extension AppTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension AppDensity {
    var contentPadding: CGFloat {
        switch self {
        case .compact: 12
        case .default: 16
        case .spacious: 20
        }
    }

    var cardSpacing: CGFloat {
        switch self {
        case .compact: 12
        case .default: 18
        case .spacious: 24
        }
    }

    var cardPadding: CGFloat {
        switch self {
        case .compact: 10
        case .default: 14
        case .spacious: 18
        }
    }

    var cardInnerSpacing: CGFloat {
        switch self {
        case .compact: 10
        case .default: 14
        case .spacious: 18
        }
    }

    var metricSpacing: CGFloat {
        switch self {
        case .compact: 4
        case .default: 6
        case .spacious: 8
        }
    }

    var progressBarHeight: CGFloat {
        switch self {
        case .compact: 4
        case .default: 5
        case .spacious: 7
        }
    }
}
