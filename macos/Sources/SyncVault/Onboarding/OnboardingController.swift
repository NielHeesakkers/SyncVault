import Foundation

@MainActor
final class OnboardingController: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome, connect, firstTask, done
    }

    @Published var step: Step = .welcome

    // Step 2 — Connect
    @Published var serverURL: String = ""
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var connectionTested: Bool = false

    // Step 3 — First sync task
    @Published var localPath: String = ("\(NSHomeDirectory())/Documents")
    @Published var remoteFolderName: String = "Documents"
    @Published var syncMode: SyncTask.SyncMode = .twoWay

    private static let completeKey = "onboardingComplete"

    func next() {
        if let next = Step(rawValue: step.rawValue + 1) {
            step = next
        }
    }

    func back() {
        if let prev = Step(rawValue: step.rawValue - 1) {
            step = prev
        }
    }

    func complete() {
        UserDefaults.standard.set(true, forKey: Self.completeKey)
    }

    /// True when the user has never finished the wizard. The SwiftUI app gates
    /// the onboarding window on this.
    static var needsOnboarding: Bool {
        !UserDefaults.standard.bool(forKey: completeKey)
    }
}
