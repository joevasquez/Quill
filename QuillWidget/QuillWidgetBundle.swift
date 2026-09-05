//
//  QuillWidgetBundle.swift
//  Quill iOS Widget
//
//  The single @main entry point for the widget extension. Exposes the
//  QuillWidget to the system so it appears in the home-screen widget
//  gallery.
//

import SwiftUI
import WidgetKit

@main
struct QuillWidgetBundle: WidgetBundle {
  var body: some Widget {
    QuillWidget()
    QuillRecordingLiveActivity()
  }
}
