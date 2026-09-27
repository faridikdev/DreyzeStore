import SwiftUI
import UIKit

enum StorePalette {
    static let accent = Color(red: 0.36, green: 0.62, blue: 0.39)
    static let leaf = Color(red: 0.79, green: 0.88, blue: 0.55)
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.055, green: 0.075, blue: 0.067, alpha: 1) : UIColor(red: 0.965, green: 0.963, blue: 0.94, alpha: 1) })
    static let surface = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor.secondarySystemBackground : UIColor.systemBackground })
    static let secondaryText = Color(uiColor: .secondaryLabel)
}

struct StoreMark: View {
    var size: CGFloat = 34
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).fill(StorePalette.accent)
            Text("D").font(.system(size: size * 0.58, weight: .black, design: .rounded)).foregroundStyle(.white)
            Circle().fill(StorePalette.leaf).frame(width: size * 0.13, height: size * 0.13).offset(x: size * 0.25, y: -size * 0.24)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct StoreSectionHeading: View {
    let title: String
    var eyebrow: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let eyebrow { Text(eyebrow.uppercased()).font(.caption2.weight(.bold)).tracking(1.1).foregroundStyle(StorePalette.accent) }
            Text(title).font(.title2.weight(.bold)).tracking(-0.4).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct OfflineNotice: View {
    var body: some View {
        Label("Offline · Showing saved information", systemImage: "wifi.slash")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel("Offline. Showing previously downloaded information.")
    }
}

struct StoreLoadError: View {
    let title: String
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 30, weight: .medium)).foregroundStyle(StorePalette.accent)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button(action: retry) { Label("Try Again", systemImage: "arrow.clockwise").font(.subheadline.weight(.semibold)) }
                .buttonStyle(.borderedProminent).tint(StorePalette.accent)
        }
        .frame(maxWidth: .infinity).padding(28)
        .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct StoreEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(StorePalette.accent)
                .frame(width: 76, height: 76).background(StorePalette.accent.opacity(0.10), in: Circle())
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 38)
    }
}

struct StoreSkeletonCard: View {
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 19).fill(.quaternary).frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 150, height: 14)
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 105, height: 11)
            }
            Spacer()
            Capsule().fill(.quaternary).frame(width: 56, height: 29)
        }
        .padding(14).background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .redacted(reason: .placeholder).accessibilityHidden(true)
    }
}

struct RemoteStoreImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 20
    var fit = false
    @State private var imageData: Data?
    @State private var failed = false

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                if fit { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(uiImage: image).resizable().scaledToFill() }
            } else if failed {
                placeholder
            } else {
                placeholder.overlay(ProgressView().tint(StorePalette.accent))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            imageData = nil
            failed = false
            guard let url else { failed = true; return }
            do { imageData = try await RemoteImageService.shared.data(for: url, maximumPixelDimension: fit ? 1_500 : 512) }
            catch is CancellationError { }
            catch { failed = true }
        }
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(StorePalette.accent.opacity(0.10))
            .overlay(Image(systemName: "app.dashed").font(.title2).foregroundStyle(StorePalette.accent.opacity(0.8)))
    }
}

struct AppSummaryCard: View {
    let app: StoreApp
    let repository: (any StoreRepository)?
    @State private var showInstallNotice = false

    var body: some View {
        HStack(spacing: 14) {
            NavigationLink(destination: AppDetailsView(repository: repository, appID: app.id)) {
                HStack(spacing: 14) {
                    RemoteStoreImage(url: app.iconURL, cornerRadius: 18).frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                        Text(app.developer.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Text(app.shortDescription ?? app.category.name).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button("GET") { showInstallNotice = true; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                .font(.caption.weight(.bold)).foregroundStyle(StorePalette.accent)
                .padding(.horizontal, 15).padding(.vertical, 8)
                .background(StorePalette.accent.opacity(0.11), in: Capsule())
                .accessibilityLabel("Get \(app.name). Installation is not available yet.")
        }
        .padding(14)
        .background(StorePalette.surface, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .alert("Installation isn’t available yet", isPresented: $showInstallNotice) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Installation will be available through the configured installation backend.")
        }
    }
}

struct ProfileButton: View {
    @State private var showingSettings = false
    var body: some View {
        Button { showingSettings = true } label: {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 28)).symbolRenderingMode(.hierarchical).foregroundStyle(StorePalette.accent)
        }
        .accessibilityLabel("Open profile and settings")
        .sheet(isPresented: $showingSettings) { SettingsView() }
    }
}

enum StoreHaptics {
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}
