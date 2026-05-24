import SwiftUI
import AppKit

struct OnboardingView: View {
    @StateObject var controller = OnboardingController()
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch controller.step {
                case .welcome:   WelcomeStep()
                case .connect:   ConnectStep(controller: controller)
                case .firstTask: FirstTaskStep(controller: controller)
                case .done:      DoneStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            actionBar
        }
        .frame(width: 540, height: 420)
        .background(SVColor.windowBg)
    }

    private var actionBar: some View {
        HStack {
            HStack {
                switch controller.step {
                case .welcome:
                    Button("Quit") { NSApp.terminate(nil) }
                        .buttonStyle(.plain).foregroundStyle(SVColor.textSecondary)
                case .connect, .firstTask:
                    Button("← Back") { controller.back() }
                        .buttonStyle(.plain).foregroundStyle(SVColor.textSecondary)
                case .done:
                    EmptyView()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)

            SVProgressDots(total: 4, current: controller.step.rawValue)

            HStack {
                Spacer()
                Button(primaryLabel) { primaryAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.step == .done ? SVColor.accentGreen : SVColor.accentBlue)
                    .disabled(primaryDisabled)
            }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, SVSpacing.xxl)
        .padding(.vertical, SVSpacing.xl)
        .background(Color(red: 0.137, green: 0.137, blue: 0.145))
        .overlay(Rectangle().fill(SVColor.hairline).frame(height: 1), alignment: .top)
        .font(SVFont.body(12))
    }

    private var primaryLabel: String {
        switch controller.step {
        case .welcome:   return "Get Started"
        case .connect:   return "Continue"
        case .firstTask: return "Start Syncing"
        case .done:      return "Done"
        }
    }

    private var primaryDisabled: Bool {
        if controller.step == .connect, !controller.connectionTested { return true }
        return false
    }

    private func primaryAction() {
        if controller.step == .done {
            controller.complete()
            onComplete()
        } else {
            controller.next()
        }
    }
}
