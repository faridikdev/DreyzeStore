import SwiftUI
import UIKit

struct StoreFeaturePlaceholderView: View {
    let title: String
    let systemImage: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 31, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("\(title) is being prepared")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text("Store content will appear here after the API and catalog features are implemented.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 360)
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.large)
        }
    }
}
