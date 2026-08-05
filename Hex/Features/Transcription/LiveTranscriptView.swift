//
//  LiveTranscriptView.swift
//  Hex
//
//  Floating translucent overlay showing partial transcription results in real-time.
//

import Inject
import SwiftUI
import HexCore

struct LiveTranscriptView: View {
  @ObserveInjection var inject
  var text: String
  var isVisible: Bool

  var body: some View {
    if isVisible && !text.isEmpty {
      Text(text)
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .foregroundStyle(.white)
        .lineLimit(3)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 400)
        .background(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card)
            .fill(.ultraThinMaterial)
            .background(
              RoundedRectangle(cornerRadius: QuillDesign.Radius.card)
                .fill(Color.black.opacity(0.6))
            )
        )
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .animation(.easeInOut(duration: 0.2), value: text)
    }
  }
}

#Preview {
  VStack(spacing: 20) {
    LiveTranscriptView(text: "Hello, this is a live transcript...", isVisible: true)
    LiveTranscriptView(text: "", isVisible: true)
    LiveTranscriptView(text: "Short", isVisible: true)
  }
  .padding(40)
  .background(Color.gray.opacity(0.3))
}
