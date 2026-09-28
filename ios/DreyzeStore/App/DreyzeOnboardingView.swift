import SwiftUI

private struct OnboardingPage: Identifiable {
    let id: Int
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
}

struct DreyzeOnboardingView: View {
    let onFinish: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            id: 0,
            symbol: "sparkles",
            title: "Discover apps",
            message: "Browse editor-selected apps, categories, and releases from the store server configured for this build."
        ),
        OnboardingPage(
            id: 1,
            symbol: "checkmark.shield",
            title: "Verified downloads",
            message: "DreyzeStore checks the published checksum and package metadata before a download can be used."
        ),
        OnboardingPage(
            id: 2,
            symbol: "desktopcomputer",
            title: "Install through Companion",
            message: "On standard iOS, a paired Windows Companion signs locally with your own Apple development files and confirms installation from iPhone inventory."
        ),
        OnboardingPage(
            id: 3,
            symbol: "iphone.and.arrow.forward",
            title: "Connect your PC",
            message: "Pair only with a Windows PC you control. You can browse and download before pairing; installation needs a connected phone and valid signing setup."
        )
    ]

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    StoreMark(size: 34)
                    Text("Welcome to DreyzeStore")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, max(geometry.safeAreaInsets.top + 18, 28))

                TabView(selection: $selection) {
                    ForEach(pages) { page in
                        pageView(page)
                            .tag(page.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .accessibilityIdentifier("onboarding.pages")

                HStack(spacing: 8) {
                    ForEach(pages) { page in
                        Capsule()
                            .fill(selection == page.id ? StorePalette.accent : StorePalette.accent.opacity(0.22))
                            .frame(width: selection == page.id ? 22 : 7, height: 7)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.bottom, 22)

                VStack(spacing: 12) {
                    Button {
                        if selection == pages.count - 1 {
                            onFinish(false)
                        } else {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.84)) {
                                selection += 1
                            }
                        }
                    } label: {
                        Text(selection == pages.count - 1 ? "Get Started" : "Continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StorePalette.accent)
                    .accessibilityIdentifier(selection == pages.count - 1 ? "onboarding.getStarted" : "onboarding.continue")

                    if selection == pages.count - 1 {
                        Button("Connect Windows Companion") { onFinish(true) }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(StorePalette.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .accessibilityIdentifier("onboarding.connectCompanion")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, max(geometry.safeAreaInsets.bottom + 16, 24))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StorePalette.canvas.ignoresSafeArea())
        }
        .background(StorePalette.canvas.ignoresSafeArea())
    }

    private func pageView(_ page: OnboardingPage) -> some View {
        VStack(spacing: 24) {
            Spacer(minLength: 16)
            Image(systemName: page.symbol)
                .font(.system(size: 38, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(StorePalette.accent)
                .frame(width: 92, height: 92)
                .background(StorePalette.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 29, style: .continuous))
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.largeTitle.weight(.bold))
                    .tracking(-0.6)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(page.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 28)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.page.\(page.id + 1)")
    }
}
