import SwiftUI
import UIKit

/// The system share sheet, which is where all of this actually happens.
///
/// Saving to Files, sending to WhatsApp, saving a video to the camera roll and
/// AirDropping it to a Mac are all one thing on iOS, and it is this. Writing
/// four buttons that each did one of them would be less capable and more code.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file waiting to be shared. Identifiable so a sheet can be driven by it.
struct Shareable: Identifiable {
    let id = UUID()
    let url: URL
}
