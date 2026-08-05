//
//  NotePDFExporter.swift
//  Quill (iOS)
//
//  Renders a Note (text + inline photos) into a single-page PDF at
//  US-Letter width so it can be shared intact through Mail, AirDrop,
//  Messages, or Files. Single page is intentional for v1: it preserves
//  the "long scroll" reading flow and renders the same whether the note
//  is three paragraphs or thirty. Print dialog can paginate if needed.
//

import HexCore
import SwiftUI
import UIKit

@MainActor
enum NotePDFExporter {
  /// Page width in PDF points (72dpi → 8.5" * 72 = 612pt, US Letter).
  private static let pageWidth: CGFloat = 612

  /// Build a PDF for `note` in the temporary directory and return its URL.
  /// `analyses` is keyed by photo UUID and rendered as a compact block
  /// directly under each photo so the exported document carries the AI
  /// takeaways alongside the image.
  static func export(_ note: Note, analyses: [UUID: PhotoAnalysis] = [:]) -> URL? {
    let content = NotePDFView(note: note, analyses: analyses)
      .frame(width: pageWidth, alignment: .topLeading)

    let renderer = ImageRenderer(content: content)
    renderer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)

    let filename = sanitize(note.displayTitle).isEmpty ? "Quill Note" : sanitize(note.displayTitle)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(filename).pdf")
    try? FileManager.default.removeItem(at: url)

    var success = false
    renderer.render { size, draw in
      var box = CGRect(origin: .zero, size: size)
      guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
      pdf.beginPDFPage(nil)
      draw(pdf)
      pdf.endPDFPage()
      pdf.closePDF()
      success = true
    }
    return success ? url : nil
  }

  /// Strip path-unsafe characters so the title can be used as a filename.
  private static func sanitize(_ s: String) -> String {
    s.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|"))
      .joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// SwiftUI view used purely as the source for `ImageRenderer`. Rendered
/// off-screen at fixed US-Letter width, so fonts/colors are tuned for
/// print rather than the on-device UI.
private struct NotePDFView: View {
  let note: Note
  let analyses: [UUID: PhotoAnalysis]

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 6) {
        Text(note.displayTitle)
          .quillFont(26, weight: .bold, design: .serif)
          .foregroundColor(.black)

        Text(metadataLine)
          .quillFont(11)
          .foregroundColor(.gray)
      }

      Rectangle()
        .fill(Color.gray.opacity(0.3))
        .frame(height: 0.5)

      ForEach(Array(NoteContent.segments(from: note.body).enumerated()), id: \.offset) { _, seg in
        switch seg {
        case .text(let t):
          NoteTextView(
            text: t,
            font: .system(size: 13),
            textColor: .black,
            bulletColor: .gray,
            headingColor: .black
          )
          .fixedSize(horizontal: false, vertical: true)
        case .photo(let id):
          VStack(alignment: .leading, spacing: 8) {
            if let ui = PhotoStore.shared.loadImage(noteID: note.id, photoID: id) {
              Image(uiImage: ui)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous))
            }
            if let analysis = analyses[id] {
              analysisBlock(analysis)
            }
          }
        }
      }

      Spacer(minLength: 8)

      Text("Exported from Quill · \(Date().formatted(date: .abbreviated, time: .shortened))")
        .quillFont(9)
        .foregroundColor(.gray)
    }
    .padding(40)
    .background(Color.white)
  }

  @ViewBuilder
  private func analysisBlock(_ analysis: PhotoAnalysis) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("AI Analysis")
        .quillFont(9, weight: .semibold)
        .foregroundColor(.gray)
      if !analysis.summary.isEmpty {
        Text(analysis.summary)
          .quillFont(11)
          .foregroundColor(.black)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(Array(analysis.keyDetails.enumerated()), id: \.offset) { _, detail in
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text("•").quillFont(11).foregroundColor(.gray)
          Text(detail)
            .quillFont(11)
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let transcribed = analysis.transcribedText, !transcribed.isEmpty {
        Text("Transcribed text:")
          .quillFont(9, weight: .semibold)
          .foregroundColor(.gray)
          .padding(.top, 2)
        Text(transcribed)
          .quillFont(10, design: .monospaced)
          .foregroundColor(.black)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(8)
    .background(Color.gray.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous))
  }

  private var metadataLine: String {
    var parts: [String] = []
    if let place = note.location?.placeName { parts.append(place) }
    parts.append(note.createdAt.formatted(date: .abbreviated, time: .shortened))
    parts.append("\(note.wordCount) words")
    if note.photoCount > 0 {
      parts.append("\(note.photoCount) photo\(note.photoCount == 1 ? "" : "s")")
    }
    return parts.joined(separator: " · ")
  }
}
