import Foundation
import SwiftUI

enum PomodoroPhase: Equatable {
    case idle
    case running
    case paused
    case completed
}

enum PomodoroInterval: Equatable {
    case focus
    case breakTime
}

@MainActor
final class PomodoroTimer: ObservableObject {
    static let availableDurations = [20, 25, 45]
    static let sessionsPerCycle = 4
    static let breakMinutes = 5
    static let selectedMinutesKey = "pomodoro.selectedMinutes"

    @Published private(set) var phase: PomodoroPhase = .idle
    @Published private(set) var interval: PomodoroInterval = .focus
    @Published private(set) var selectedMinutes: Int
    @Published private(set) var remainingSeconds: Int
    @Published private(set) var completedFocusSessions = 0

    var onStateChange: (() -> Void)?

    private let defaults: UserDefaults
    private let now: () -> Date
    private let scheduleCompletion: (Int, PomodoroInterval, Int) -> Void
    private let cancelCompletion: () -> Void
    private var endDate: Date?
    private var ticker: Timer?

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        scheduleCompletion: @escaping (Int, PomodoroInterval, Int) -> Void = {
            NotificationManager.shared.schedulePomodoroCompletion(
                after: $0,
                interval: $1,
                intervalMinutes: $2
            )
        },
        cancelCompletion: @escaping () -> Void = {
            NotificationManager.shared.cancelPomodoroCompletion()
        }
    ) {
        self.defaults = defaults
        self.now = now
        self.scheduleCompletion = scheduleCompletion
        self.cancelCompletion = cancelCompletion

        let savedMinutes = defaults.integer(forKey: Self.selectedMinutesKey)
        let initialMinutes = Self.availableDurations.contains(savedMinutes) ? savedMinutes : 20
        selectedMinutes = initialMinutes
        remainingSeconds = initialMinutes * 60
    }

    var formattedTime: String {
        Self.format(seconds: remainingSeconds)
    }

    var progress: Double {
        let totalSeconds = max(1, intervalMinutes * 60)
        return min(1, max(0, 1 - Double(remainingSeconds) / Double(totalSeconds)))
    }

    var currentSessionNumber: Int {
        if interval == .breakTime {
            return max(1, min(Self.sessionsPerCycle, completedFocusSessions))
        }
        return completedFocusSessions >= Self.sessionsPerCycle
            ? 1
            : completedFocusSessions + 1
    }

    var intervalMinutes: Int {
        interval == .focus ? selectedMinutes : Self.breakMinutes
    }

    var isActive: Bool {
        phase == .running || phase == .paused
    }

    func selectDuration(_ minutes: Int) {
        guard Self.availableDurations.contains(minutes), !isActive else { return }
        selectedMinutes = minutes
        remainingSeconds = minutes * 60
        interval = .focus
        phase = .idle
        defaults.set(minutes, forKey: Self.selectedMinutesKey)
        stateDidChange()
    }

    func start() {
        cancelTicker()
        cancelCompletion()
        if completedFocusSessions >= Self.sessionsPerCycle {
            completedFocusSessions = 0
        }
        interval = .focus
        remainingSeconds = selectedMinutes * 60
        phase = .running
        endDate = now().addingTimeInterval(TimeInterval(remainingSeconds))
        scheduleCompletion(remainingSeconds, interval, selectedMinutes)
        startTicker()
        stateDidChange()
    }

    func pause() {
        guard phase == .running else { return }
        refresh()
        guard phase == .running else { return }
        phase = .paused
        endDate = nil
        cancelTicker()
        cancelCompletion()
        stateDidChange()
    }

    func resume() {
        guard phase == .paused, remainingSeconds > 0 else { return }
        phase = .running
        endDate = now().addingTimeInterval(TimeInterval(remainingSeconds))
        scheduleCompletion(remainingSeconds, interval, intervalMinutes)
        startTicker()
        stateDidChange()
    }

    func reset() {
        cancelTicker()
        cancelCompletion()
        endDate = nil
        interval = .focus
        completedFocusSessions = 0
        remainingSeconds = selectedMinutes * 60
        phase = .idle
        stateDidChange()
    }

    static func format(seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        return String(format: "%02d:%02d", safeSeconds / 60, safeSeconds % 60)
    }

    private func startTicker() {
        cancelTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        ticker?.tolerance = 0.1
    }

    func refresh() {
        guard phase == .running, let endDate else { return }
        let updatedSeconds = max(0, Int(ceil(endDate.timeIntervalSince(now()))))
        if updatedSeconds > 0 {
            guard updatedSeconds != remainingSeconds else { return }
            remainingSeconds = updatedSeconds
            stateDidChange()
            return
        }

        switch interval {
        case .focus:
            beginAutomaticBreak(after: endDate)
        case .breakTime:
            finishBreak()
        }
        stateDidChange()
    }

    private func beginAutomaticBreak(after focusEndDate: Date) {
        completedFocusSessions = min(
            Self.sessionsPerCycle,
            completedFocusSessions + 1
        )
        interval = .breakTime
        let breakEndDate = focusEndDate.addingTimeInterval(
            TimeInterval(Self.breakMinutes * 60)
        )
        let breakSeconds = max(0, Int(ceil(breakEndDate.timeIntervalSince(now()))))

        guard breakSeconds > 0 else {
            remainingSeconds = 0
            finishBreak()
            return
        }

        remainingSeconds = breakSeconds
        phase = .running
        endDate = breakEndDate
        scheduleCompletion(breakSeconds, .breakTime, Self.breakMinutes)
        startTicker()
    }

    private func finishBreak() {
        remainingSeconds = 0
        phase = .completed
        endDate = nil
        cancelTicker()
    }

    private func cancelTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func stateDidChange() {
        onStateChange?()
    }

    deinit {
        ticker?.invalidate()
    }
}
