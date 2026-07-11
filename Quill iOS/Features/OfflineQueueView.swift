//
//  OfflineQueueView.swift
//  Quill (iOS)
//
//  Settings sub-screen showing pending offline actions — items that
//  failed to dispatch (or even parse) when the device was offline and
//  are waiting for connectivity to retry.
//
//  The view is intentionally thin: it polls `ActionQueueManager.snapshot()`
//  on appear and after user-driven mutations (retry, discard). The actor
//  doesn't push state to UI consumers; that would couple HexCore to
//  NotificationCenter or Combine, which it deliberately avoids.
//

import HexCore
import SwiftUI

struct OfflineQueueView: View {
  @State private var items: [QueuedAction] = []
  @State private var isLoading = true
  @State private var showingClearConfirmation = false

  var body: some View {
    Group {
      if isLoading {
        ProgressView()
      } else if items.isEmpty {
        ContentUnavailableView(
          "No pending actions",
          systemImage: "tray",
          description: Text("Actions you take while offline appear here. They retry automatically when you're back online.")
        )
      } else {
        list
      }
    }
    .navigationTitle("Offline Queue")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button {
            Task { await retryAll() }
          } label: {
            Label("Retry all now", systemImage: "arrow.clockwise")
          }
          .disabled(items.isEmpty)

          Button(role: .destructive) {
            showingClearConfirmation = true
          } label: {
            Label("Clear all", systemImage: "trash")
          }
          .disabled(items.isEmpty)
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .task { await refresh() }
    .refreshable { await retryAll() }
    .alert("Clear all queued actions?", isPresented: $showingClearConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Clear", role: .destructive) {
        Task { await clearAll() }
      }
    } message: {
      Text("This permanently discards \(items.count) pending action(s). This can't be undone.")
    }
  }

  private var list: some View {
    List {
      Section {
        ForEach(items) { item in
          QueueRow(item: item)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
              Button(role: .destructive) {
                Task { await discard(id: item.id) }
              } label: {
                Label("Discard", systemImage: "trash")
              }
            }
        }
      } footer: {
        Text("\(items.count) item(s). Items retry automatically when you're online; pull down to retry now.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Actions

  private func refresh() async {
    items = await ActionQueueManager.shared.snapshot()
    isLoading = false
  }

  private func retryAll() async {
    await ActionQueueManager.shared.retryNow()
    // Give the manager a moment to actually run before we re-snapshot.
    try? await Task.sleep(for: .milliseconds(400))
    await refresh()
  }

  private func clearAll() async {
    for item in items {
      await ActionQueueManager.shared.discard(id: item.id)
    }
    await refresh()
  }

  private func discard(id: UUID) async {
    await ActionQueueManager.shared.discard(id: id)
    await refresh()
  }
}

// MARK: - Row

private struct QueueRow: View {
  let item: QueuedAction

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Image(systemName: iconName)
          .foregroundStyle(tint)
          .font(.body.weight(.semibold))
          .frame(width: 22)
        Text(item.displayTitle)
          .font(.body)
          .lineLimit(2)
      }

      HStack(spacing: 8) {
        Text(targetLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("•")
          .foregroundStyle(.tertiary)
        Text(item.createdAt.formatted(.relative(presentation: .numeric)))
          .font(.caption)
          .foregroundStyle(.secondary)
        if item.retryCount > 0 {
          Text("•")
            .foregroundStyle(.tertiary)
          Text(retryLabel)
            .font(.caption)
            .foregroundStyle(item.isExhausted ? .red : .orange)
        }
      }

      if let lastError = item.lastError, !lastError.isEmpty {
        Text(lastError)
          .font(.caption2)
          .foregroundStyle(.red.opacity(0.85))
          .lineLimit(2)
      }
    }
    .padding(.vertical, 2)
  }

  private var iconName: String {
    switch item.payload {
    case .ready(let intent):
      return ConnectionTarget.forIntent(intent).systemImage
    case .pendingParse:
      return "doc.text.magnifyingglass"
    }
  }

  private var tint: Color {
    switch item.payload {
    case .ready(let intent):
      let target = ConnectionTarget.forIntent(intent)
      if case .open = target { return .blue }
      return target.tintHex.flatMap { Color(hex: $0) } ?? QuillDesign.mcpTile
    case .pendingParse:
      return .orange
    }
  }

  private var targetLabel: String {
    switch item.payload {
    case .ready(let intent):
      return ConnectionTarget.forIntent(intent).displayName
    case .pendingParse:
      return "Awaiting parse"
    }
  }

  private var retryLabel: String {
    if item.isExhausted {
      return "Failed (max retries)"
    }
    return "Retried \(item.retryCount)×"
  }
}

private extension Color {
  init?(hex: String) {
    var hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    let r = Double((value >> 16) & 0xFF) / 255
    let g = Double((value >> 8) & 0xFF) / 255
    let b = Double(value & 0xFF) / 255
    self = Color(red: r, green: g, blue: b)
  }
}
