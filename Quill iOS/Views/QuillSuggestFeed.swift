//
//  QuillSuggestFeed.swift
//  Quill (iOS)
//
//  Proactive suggestions: a quiet "peek" bar on home + a dedicated
//  full-screen Suggestions page. Home is for glancing — the peek bar
//  renders NOTHING when there are no suggestions or Pro is off, so the
//  launcher is never cluttered by empty or locked states. Browsing,
//  the empty state, and the Pro upsell all live on the page. The accept
//  flow is shared: Review anywhere opens the same pre-filled
//  confirmation sheet.
//
//  Flat throughout: hairline borders + tints, no shadows.
//

import HexCore
import SwiftUI

// MARK: - Source mark

/// Tinted rounded mark + the source hue — the identity that carries from
/// card to confirmation sheet.
struct QuillSourceMark: View {
  var source: SuggestionSource
  var size: CGFloat = 34

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  private var tint: OKLCH { QuillDesign.destination(hue: source.hue) }

  var body: some View {
    Image(systemName: source.systemImage)
      .font(.system(size: size * 0.42, weight: .semibold))
      .foregroundStyle(tint.color())
      .frame(width: size, height: size)
      .background(
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
          .fill(tint.color(theme.isDark ? 0.2 : 0.14))
      )
  }
}

// MARK: - Step chain

/// "What happens" preview: destination-tinted pills joined by chevrons.
/// Consecutive same-destination steps collapse to a count (Gmail ×3).
struct QuillStepChain: View {
  var intents: [ActionIntent]

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  private struct Group: Identifiable {
    let id: Int
    let target: ConnectionTarget
    let count: Int
  }

  private var groups: [Group] {
    var result: [(target: ConnectionTarget, count: Int)] = []
    for intent in intents {
      let target = ConnectionTarget.forIntent(intent)
      if let last = result.last, last.target.displayName == target.displayName {
        result[result.count - 1].count += 1
      } else {
        result.append((target, 1))
      }
    }
    return result.enumerated().map { Group(id: $0.offset, target: $0.element.target, count: $0.element.count) }
  }

  var body: some View {
    QuillWrap(spacing: 5) {
      ForEach(groups) { group in
        HStack(spacing: 5) {
          if group.id > 0 {
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .semibold))
              .foregroundStyle(theme.text3)
          }
          pill(group)
        }
      }
    }
  }

  private func pill(_ group: Group) -> some View {
    let tint = tintColor(group.target)
    return HStack(spacing: 5) {
      Image(systemName: group.target.systemImage)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(tint)
      Text(group.target.displayName)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.text2)
      if group.count > 1 {
        Text("×\(group.count)")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(theme.text3)
      }
    }
    .padding(.vertical, 3)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(tint.opacity(theme.isDark ? 0.16 : 0.11))
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(tint.opacity(0.32), lineWidth: 0.5)
        )
    )
  }

  private func tintColor(_ target: ConnectionTarget) -> Color {
    if let hex = target.tintHex, let oklch = OKLCH(hex: hex) {
      return QuillDesign.destination(hue: oklch.H).color()
    }
    return theme.text2
  }
}

// MARK: - Peek bar (home)

/// The home teaser: stacked source icons, a count, the top suggestion's
/// source + headline, and a View affordance. One tap target → the page.
/// Callers render it only when there ARE suggestions and Pro is on.
struct QuillSuggestPeekBar: View {
  var suggestions: [Suggestion]
  var onOpen: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  /// One mark per distinct source, in feed order.
  private var distinctSources: [SuggestionSource] {
    var seen = Set<SuggestionSource>()
    return suggestions.map(\.source).filter { seen.insert($0).inserted }
  }

  var body: some View {
    if let top = suggestions.first {
      let topTint = QuillDesign.destination(hue: top.source.hue)

      Button(action: onOpen) {
        HStack(spacing: 11) {
          HStack(spacing: -8) {
            ForEach(distinctSources.prefix(4)) { source in
              QuillSourceMark(source: source, size: 28)
                .overlay(
                  RoundedRectangle(cornerRadius: 28 * 0.32, style: .continuous)
                    .strokeBorder(theme.cardSolid, lineWidth: 1.5)
                )
            }
          }

          VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
              Text("\(suggestions.count) suggestion\(suggestions.count == 1 ? "" : "s")")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.text2)
              Text(top.source.displayName)
                .font(.system(size: 10.5, weight: .heavy))
                .tracking(0.3)
                .textCase(.uppercase)
                .foregroundStyle(topTint.color())
            }
            Text(top.headline)
              .font(.system(size: 14.5, weight: .semibold))
              .tracking(-0.2)
              .foregroundStyle(theme.text)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          HStack(spacing: 2) {
            Text("View")
              .font(.system(size: 13.5, weight: .semibold))
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .semibold))
          }
          .foregroundStyle(QuillDesign.brand.color())
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
          RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(theme.card)
            // A faint source-tinted bleed from the left edge gives it life.
            .overlay(
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                  LinearGradient(
                    colors: [topTint.color(theme.isDark ? 0.14 : 0.1), .clear],
                    startPoint: .leading,
                    endPoint: UnitPoint(x: 0.55, y: 0.5)
                  )
                )
            )
            .overlay(
              RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.hair, lineWidth: 0.5)
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      }
      .buttonStyle(QuillPressStyle())
      .padding(.horizontal, 16)
      .accessibilityLabel("\(suggestions.count) suggestions. Top: \(top.headline)")
      .accessibilityHint("Opens the Suggestions page")
    }
  }
}

// MARK: - Full suggestion card (page)

struct QuillSuggestionCard: View {
  var suggestion: Suggestion
  var onReview: () -> Void
  var onDismiss: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  private var tint: OKLCH { QuillDesign.destination(hue: suggestion.source.hue) }
  private var act: OKLCH { QuillDesign.ModePalette.act }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        QuillSourceMark(source: suggestion.source)
        VStack(alignment: .leading, spacing: 1) {
          Text(suggestion.source.displayName)
            .font(.system(size: 12.5, weight: .heavy))
            .tracking(0.2)
            .textCase(.uppercase)
            .foregroundStyle(tint.color())
          Text(suggestion.intents.count > 1 ? "\(suggestion.intents.count)-step action" : "Suggested action")
            .font(.system(size: 11.5))
            .foregroundStyle(theme.text3)
        }
        Spacer()
        Button(action: onDismiss) {
          Image(systemName: "xmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.text3)
            .frame(width: 28, height: 28)
            .background(Circle().fill(theme.chip))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss suggestion")
      }
      .padding(.bottom, 11)

      Text(suggestion.headline)
        .font(.system(size: 17.5, weight: .bold))
        .tracking(-0.3)
        .foregroundStyle(theme.text)
        .fixedSize(horizontal: false, vertical: true)

      if !suggestion.why.isEmpty {
        HStack(alignment: .top, spacing: 6) {
          Image(systemName: "sparkles")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.text3)
            .padding(.top, 3)
          Text(suggestion.why)
            .font(.system(size: 13.5))
            .foregroundStyle(theme.text2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 5)
      }

      Rectangle()
        .fill(theme.hair)
        .frame(height: 0.5)
        .padding(.vertical, 12)

      HStack(alignment: .center, spacing: 10) {
        QuillStepChain(intents: suggestion.intents)
          .frame(maxWidth: .infinity, alignment: .leading)

        Button(action: onReview) {
          HStack(spacing: 5) {
            Text("Review")
              .font(.system(size: 14.5, weight: .bold))
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .bold))
          }
          .foregroundStyle(act.lightnessCapped(at: theme.isDark ? 0.84 : 0.4).color())
          .padding(.vertical, 9)
          .padding(.horizontal, 15)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(act.color(theme.isDark ? 0.22 : 0.16))
          )
          .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(QuillPressStyle())
        .accessibilityHint("Opens an editable review — nothing runs until you tap Run")
      }
    }
    .padding(15)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(theme.card)
        .overlay(
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(theme.hair, lineWidth: 0.5)
        )
    )
  }
}

// MARK: - Suggestions page

/// The dedicated browse surface: back button, big title with a PRO tag,
/// and an inbox-style list of full cards. Empty and locked states live
/// here at full size — never on home.
struct QuillSuggestionsPage: View {
  var suggestions: [Suggestion]
  var isPro: Bool
  var noReadableSources: Bool
  /// True while a generation pass is running — spins the refresh button.
  var isGenerating: Bool = false
  var onReview: (Suggestion) -> Void
  var onDismiss: (Suggestion) -> Void
  var onUnlock: () -> Void
  /// Manual re-check, bypassing the freshness throttle.
  var onRefresh: () -> Void = {}

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  var body: some View {
    VStack(spacing: 0) {
      topBar

      ScrollView {
        VStack(spacing: 12) {
          if !isPro {
            QuillProUpsellCard(onUnlock: onUnlock)
          } else if suggestions.isEmpty {
            QuillSuggestEmpty(noReadableSources: noReadableSources)
          } else {
            ForEach(suggestions) { suggestion in
              QuillSuggestionCard(
                suggestion: suggestion,
                onReview: { onReview(suggestion) },
                onDismiss: { onDismiss(suggestion) }
              )
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 30)
      }
    }
    .background(pageBackground.ignoresSafeArea())
    .toolbar(.hidden, for: .navigationBar)
  }

  private var topBar: some View {
    HStack(alignment: .center, spacing: 12) {
      Button {
        dismiss()
      } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(theme.text2)
          .frame(width: 36, height: 36)
          .background(
            Circle()
              .fill(theme.chip)
              .overlay(Circle().strokeBorder(theme.hair, lineWidth: 0.5))
          )
          .contentShape(Circle())
      }
      .buttonStyle(QuillPressStyle())
      .accessibilityLabel("Back")

      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 8) {
          Text("Suggestions")
            .font(.system(size: 24, weight: .bold))
            .tracking(-0.5)
            .foregroundStyle(theme.text)
          Text("PRO")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(QuillDesign.brand.color())
            )
        }
        Text("Ready-to-run actions from your sources")
          .font(.system(size: 12.5))
          .foregroundStyle(theme.text2)
      }

      Spacer()

      if isPro {
        Button(action: onRefresh) {
          Group {
            if isGenerating {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.text2)
            }
          }
          .frame(width: 36, height: 36)
          .background(
            Circle()
              .fill(theme.chip)
              .overlay(Circle().strokeBorder(theme.hair, lineWidth: 0.5))
          )
          .contentShape(Circle())
        }
        .buttonStyle(QuillPressStyle())
        .disabled(isGenerating)
        .accessibilityLabel("Check for new suggestions")
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 4)
    .padding(.bottom, 12)
  }

  private var pageBackground: some View {
    Group {
      if theme.isDark {
        RadialGradient(
          gradient: Gradient(colors: theme.pageGradient),
          center: UnitPoint(x: 0.5, y: -0.08),
          startRadius: 0,
          endRadius: 900
        )
      } else {
        LinearGradient(
          gradient: Gradient(colors: theme.pageGradient),
          startPoint: .top,
          endPoint: .bottom
        )
      }
    }
  }
}

// MARK: - Empty state (page)

struct QuillSuggestEmpty: View {
  /// When true, the connected sources produced nothing readable — say so
  /// (and how to fix it) instead of pretending the user is caught up.
  var noReadableSources: Bool = false

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  private var accent: OKLCH {
    noReadableSources ? QuillDesign.ModePalette.act : QuillDesign.ModePalette.resolved
  }

  var body: some View {
    HStack(alignment: noReadableSources ? .top : .center, spacing: 13) {
      Image(systemName: noReadableSources ? "antenna.radiowaves.left.and.right.slash" : "checkmark")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(accent.lightnessCapped(at: theme.isDark ? 0.8 : 0.55).color())
        .frame(width: 38, height: 38)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(accent.color(0.12))
        )
      VStack(alignment: .leading, spacing: 1) {
        Text(noReadableSources ? "Nothing to read yet" : "You're all caught up")
          .font(.system(size: 15.5, weight: .semibold))
          .foregroundStyle(theme.text)
        Text(
          noReadableSources
            ? "Google's Gmail connection is send-only, so inbox and Dex suggestions come from their MCP servers — add them in Settings → Connections."
            : "Quill will nudge you when something's worth acting on."
        )
        .font(.system(size: 13.5))
        .foregroundStyle(theme.text2)
        .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 16)
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(theme.card)
        .overlay(
          RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(theme.hair, lineWidth: 0.5)
        )
    )
  }
}

// MARK: - Pro upsell (page)

struct QuillProUpsellCard: View {
  var onUnlock: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 11) {
        Image(systemName: "lock.fill")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(QuillDesign.brand.lightnessCapped(at: theme.isDark ? 0.8 : 0.55).color())
          .frame(width: 36, height: 36)
          .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
              .fill(QuillDesign.brand.color(0.16))
          )
        HStack(spacing: 7) {
          Text("Proactive suggestions")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(theme.text)
          Text("PRO")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(QuillDesign.brand.color())
            )
        }
        Spacer(minLength: 0)
      }

      Text("Let Quill watch your inbox, calendar, and contacts and offer ready-to-run actions — you always review before anything happens.")
        .font(.system(size: 14))
        .foregroundStyle(theme.text2)

      Button(action: onUnlock) {
        Text("Upgrade to Pro")
          .font(.system(size: 15.5, weight: .semibold))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 46)
          .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(QuillDesign.brand.color())
          )
      }
      .buttonStyle(QuillPressStyle())
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(theme.card)
        .overlay(
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
              RadialGradient(
                colors: [QuillDesign.brand.color(theme.isDark ? 0.14 : 0.1), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 320
              )
            )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(QuillDesign.brand.color(0.32), lineWidth: 0.5)
        )
    )
  }
}

// MARK: - Dictate × Calendar strip

/// In Dictate mode the suggestion slot links to your day instead: tap a
/// meeting to start a dictation whose note is titled for it. The current
/// meeting gets a NOW tag and a filled tint.
struct QuillDictateCalendarStrip: View {
  var meetings: [IOSSuggestionSources.UpcomingMeeting]
  var onDictate: (IOSSuggestionSources.UpcomingMeeting) -> Void

  @Environment(\.colorScheme) private var colorScheme
  private var theme: QuillTheme { .of(colorScheme) }

  private var blue: OKLCH { QuillDesign.ModePalette.dictate }

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "calendar")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(blue.color())
        Text("Dictate into a meeting")
          .font(.system(size: 13, weight: .semibold))
          .tracking(0.3)
          .textCase(.uppercase)
          .foregroundStyle(theme.text3)
        Spacer()
      }
      .padding(.horizontal, 20)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(meetings) { meeting in
            meetingCard(meeting)
          }
        }
        .padding(.horizontal, 16)
      }
    }
  }

  private func meetingCard(_ meeting: IOSSuggestionSources.UpcomingMeeting) -> some View {
    Button {
      onDictate(meeting)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Circle()
            .fill(meeting.isNow ? blue.color() : theme.text3)
            .frame(width: 6, height: 6)
          Text(meeting.time)
            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(
              meeting.isNow
                ? blue.lightnessCapped(at: theme.isDark ? 0.82 : 0.42).color()
                : theme.text2
            )
          if meeting.isNow {
            Text("NOW")
              .font(.system(size: 9.5, weight: .heavy))
              .tracking(0.4)
              .foregroundStyle(.white)
              .padding(.vertical, 1)
              .padding(.horizontal, 5)
              .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(blue.color()))
          }
        }
        Text(meeting.title)
          .font(.system(size: 14.5, weight: .semibold))
          .tracking(-0.2)
          .foregroundStyle(theme.text)
          .lineLimit(1)
        HStack(spacing: 5) {
          Image(systemName: "mic")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(blue.color())
          Text(meeting.detail.isEmpty ? "Dictate notes" : "Dictate notes · \(meeting.detail)")
            .font(.system(size: 12))
            .foregroundStyle(theme.text3)
            .lineLimit(1)
        }
      }
      .padding(.vertical, 11)
      .padding(.horizontal, 13)
      .frame(maxWidth: 210, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(meeting.isNow ? blue.color(theme.isDark ? 0.18 : 0.1) : theme.card)
          .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .strokeBorder(
                meeting.isNow ? blue.color(0.4) : theme.hair,
                lineWidth: meeting.isNow ? 1 : 0.5
              )
          )
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(QuillPressStyle())
  }
}
