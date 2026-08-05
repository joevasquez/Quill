//
//  OfflineQueueSectionView.swift
//  Quill (macOS)
//
//  Settings → General section showing pending offline actions and a
//  manual retry/clear control. Deliberately inline (no separate tab) —
//  most users will see "Empty" and never engage; the few who hit a
//  network failure during Action mode get a low-friction surface to
//  diagnose and intervene.
//
//  Polls `ActionQueueManager.snapshot()` on appear and after user
//  actions. The actor doesn't push state to UI consumers; that would
//  couple HexCore to NotificationCenter or Combine, which it
//  deliberately avoids.
//

import HexCore
import Inject
import SwiftUI

struct OfflineQueueSectionView: View {
  @ObserveInjection var inject

  @State private var items: [QueuedAction] = []
  @State private var isLoading = true

  var body: some View {
    Section {
      if items.isEmpty && !isLoading {
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.caption)
          Text("No pending actions")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if !items.isEmpty {
        ForEach(items) { item in
          QueueRow(item: item) {
            Task { await discard(id: item.id) }
          }
        }

        HStack {
          Button {
            Task { await retryAll() }
          } label: {
            Label("Retry now", systemImage: "arrow.clockwise")
          }
          .controlSize(.small)

          Spacer()

          Button(role: .destructive) {
            Task { await clearAll() }
          } label: {
            Label("Clear all", systemImage: "trash")
          }
          .controlSize(.small)
        }
      }
    } header: {
      HStack {
        Text("Offline Queue")
        if !items.isEmpty {
          Text("\(items.count)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.orange, in: Capsule())
        }
      }
    } footer: {
      Text("Actions you take while offline are saved here and retried automatically when you're back online.")
        .settingsCaption()
    }
    .task { await refresh() }
    .enableInjection()
  }

  // MARK: - Actions

  private func refresh() async {
    items = await ActionQueueManager.shared.snapshot()
    isLoading = false
  }

  private func retryAll() async {
    await ActionQueueManager.shared.retryNow()
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
  let onDiscard: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: iconName)
        .foregroundStyle(tint)
        .font(.body.weight(.semibold))
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.displayTitle)
          .font(.body)
          .lineLimit(2)

        HStack(spacing: 6) {
          Text(targetLabel)
          Text("•")
            .foregroundStyle(.tertiary)
          Text(item.createdAt.formatted(.relative(presentation: .numeric)))
          if item.retryCount > 0 {
            Text("•")
              .foregroundStyle(.tertiary)
            Text(retryLabel)
              .foregroundStyle(item.isExhausted ? .red : .orange)
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if let lastError = item.lastError, !lastError.isEmpty {
          Text(lastError)
            .font(.caption2)
            .foregroundStyle(.red.opacity(0.85))
            .lineLimit(2)
        }
      }

      Spacer(minLength: 0)

      Button {
        onDiscard()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Discard this item")
      .accessibilityLabel("Discard this item")
    }
    .padding(.vertical, 2)
  }

  private var iconName: String {
    switch item.payload {
    case .ready(let intent):
      return Integration.all.first { $0.identifier == intent.targetIntegration }?.systemImage ?? "questionmark.circle"
    case .pendingParse:
      return "doc.text.magnifyingglass"
    }
  }

  private var tint: Color {
    switch item.payload {
    case .ready(let intent):
      return Color(hex: Integration.all.first { $0.identifier == intent.targetIntegration }?.tintHex ?? "") ?? .secondary
    case .pendingParse:
      return .orange
    }
  }

  private var targetLabel: String {
    switch item.payload {
    case .ready(let intent):
      return Integration.all.first { $0.identifier == intent.targetIntegration }?.name ?? intent.targetIntegration.rawValue
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
