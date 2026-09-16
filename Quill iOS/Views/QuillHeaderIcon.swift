import HexCore
import SwiftUI

/// Plain navigation icon shared by home, note headers, and menu triggers.
struct QuillHeaderIcon: View {
  let systemImage: String
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Image(systemName: systemImage)
      .quillFont(21, weight: .medium)
      .foregroundStyle(QuillTheme.of(colorScheme).text2)
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
  }
}
