import ComponentKit
import SwiftUI

/// A quiet line that explains: under an inspector's cards, under a review's changes, in the sidebar's tree (loading,
/// empty, or what went wrong). Caption type in the secondary colour, or in `hue` for a problem.
///
/// ```swift
/// NoteLine("Read-only connection.", systemImage: "lock")
/// NoteLine(error, systemImage: nil, hue: .red)
/// ```
struct NoteLine: View {
  let text: String
  var systemImage: String?
  var hue: Hue?

  init(_ text: String, systemImage: String? = "info.circle", hue: Hue? = nil) {
    self.text = text
    self.systemImage = systemImage
    self.hue = hue
  }

  var body: some View {
    Group {
      if let systemImage {
        Label(text, systemImage: systemImage)
      } else {
        Text(text)
      }
    }
    .kitFont(.caption)
    .foregroundStyle(hue.map { AnyShapeStyle($0.text) } ?? AnyShapeStyle(.kitSecondary))
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 6)
  }
}
