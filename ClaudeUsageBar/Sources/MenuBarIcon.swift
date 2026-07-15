import Foundation

enum MenuBarIcon: String, CaseIterable, Identifiable {
    static let preferenceKey = "menuBarIcon"

    case halfCircle
    case sparkles
    case gauge
    case bolt
    case chart
    case terminal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .halfCircle: return "Demi-cercle"
        case .sparkles: return "Étincelles"
        case .gauge: return "Jauge"
        case .bolt: return "Éclair"
        case .chart: return "Graphique"
        case .terminal: return "Terminal"
        }
    }

    var systemSymbolName: String? {
        switch self {
        case .halfCircle: return nil
        case .sparkles: return "sparkles"
        case .gauge: return "gauge"
        case .bolt: return "bolt.fill"
        case .chart: return "chart.bar.fill"
        case .terminal: return "terminal.fill"
        }
    }

    static var saved: MenuBarIcon {
        guard let rawValue = UserDefaults.standard.string(forKey: preferenceKey) else {
            return .halfCircle
        }
        return MenuBarIcon(rawValue: rawValue) ?? .halfCircle
    }
}
