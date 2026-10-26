import UIKit

/// Haptic vocabulary for the session (DESIGN: click, right-click, drag start, mode switch, connect).
/// Generators are prepared ahead of time so the tap feels instantaneous.
@MainActor
final class Haptics {
    static let shared = Haptics()

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.haptics) }

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()

    enum Event {
        case click, rightClick, dragStart, dragEnd, modeSwitch, connected, failure, gesture, detent, key, scanned
    }

    func prepare() {
        guard isEnabled else { return }
        light.prepare(); rigid.prepare(); medium.prepare()
    }

    func play(_ event: Event) {
        guard isEnabled else { return }
        switch event {
        case .click: light.impactOccurred(intensity: 0.85); light.prepare()
        case .rightClick: rigid.impactOccurred(intensity: 0.9); rigid.prepare()
        case .dragStart: medium.impactOccurred(); medium.prepare()
        case .dragEnd: soft.impactOccurred(intensity: 0.6)
        case .modeSwitch, .detent: selection.selectionChanged()
        case .connected, .scanned: notification.notificationOccurred(.success)
        case .failure: notification.notificationOccurred(.error)
        case .gesture: soft.impactOccurred(intensity: 0.9)
        case .key: light.impactOccurred(intensity: 0.45)
        }
    }
}
