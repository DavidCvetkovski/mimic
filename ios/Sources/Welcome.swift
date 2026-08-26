import SwiftUI

/// The first thing anybody sees.
///
/// It used to be a button asking for six hundred megabytes, with one sentence
/// of explanation and nothing about what the app was for. That is a lot to ask
/// of somebody who has not heard it work yet — and the reason it is such a
/// large download is the same reason the app is worth having, so it is worth
/// two sentences rather than half of one.
struct Welcome: View {
    @EnvironmentObject private var store: Store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Wordmark()
                    Text("Type something.\nHear it in your own voice.")
                        .font(.custom("Iowan Old Style", size: 30, relativeTo: .largeTitle))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 28)

                VStack(alignment: .leading, spacing: 18) {
                    Point(icon: "mic", title: "Fifteen seconds",
                          detail: "Read a short paragraph aloud and it learns how you "
                                + "sound. That is the whole setup.")
                    Point(icon: "iphone", title: "On this phone",
                          detail: "The model, the recording and the synthesis all happen "
                                + "here. It works in aeroplane mode.")
                    Point(icon: "lock", title: "Nothing is sent anywhere",
                          detail: "No account, no server, no upload. Your voice does not "
                                + "leave the device, because there is nowhere for it to go.")
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Before it can speak, it needs the model — about 600 MB, "
                         + "downloaded once and kept. Best on Wi-Fi.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Get the model") { Task { await store.download() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.blood)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
                .padding(.bottom, 30)
            }
            .padding(.horizontal, 26)
        }
        .background(Palette.background(scheme))
    }
}

private struct Point: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(Palette.blood)
                .frame(width: 26, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
