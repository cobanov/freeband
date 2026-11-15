import SwiftUI

/// Full screen while the phone rings for the band's Find Phone (docs/STAY-CONNECTED.md section 4).
struct FindPhoneView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: FBSpace.m) {
            Spacer()
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.textPrimary)
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .accessibilityHidden(true)
            Text("\(model.ringingFor ?? "") is looking for this phone")
                .textStyle(.title)
                .foregroundStyle(.textPrimary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, FBSpace.gutter)
        .frame(maxWidth: .infinity)
        .fbPinnedPrimary(String(localized: "Stop ringing"), background: .canvas) { model.stopFindPhone() }
        .fbScreen()
    }
}
