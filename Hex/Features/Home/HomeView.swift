//
//  HomeView.swift
//  Quill (macOS)
//
//  The landing pane — the macOS mirror of the iOS home surfaces:
//  proactive suggestions (Pro) up top, the three most recent cloud-synced
//  notes below. Review hands a suggestion's pre-built intents to the
//  existing menu-bar confirmation panel (review-before-run, never
//  auto-executed); clicking a note jumps to the Notes pane with it
//  selected.
//

import ComposableArchitecture
import HexCore
import SwiftUI

struct HomeView: View {
  @Bindable var transcriptionStore: StoreOf<TranscriptionFeature>
  /// Jump to the Notes pane with this note selected.
  var openNote: (UUID) -> Void
  /// Jump to General settings (the Pro plan toggle lives there).
  var openSettings: () -> Void
  /// Jump to the Integrations tab (connect sources CTA).
  var openIntegrations: () -> Void
  /// Jump to the Notes pane without a selection ("All notes").
  var openNotesPane: () -> Void

  /// Which half of home is showing — mirrors the iOS mode rail, where Act
  /// and note capture are separate destinations, not a stack. It sits
  /// directly above the input bar and governs it: Act sends what you type
  /// to the agent, Notes turns it into a note.
  ///
  /// (The `.act` case keeps its legacy "actions" rawValue so anyone's
  /// persisted choice survives the rename.)
  private enum HomeSection: String, CaseIterable, Identifiable {
    case act = "actions"
    case notes
    var id: String { rawValue }
    var title: String { self == .act ? "Act" : "Notes" }
  }

  /// Persisted so the pane reopens on whichever half you live in.
  @AppStorage("quill.homeSection") private var sectionRaw = HomeSection.act.rawValue
  private var section: HomeSection { HomeSection(rawValue: sectionRaw) ?? .act }

  /// Destinations muted on the Act chip row. Persisted (unlike iOS, where
  /// it's per-capture) because a Mac session is long and re-muting the same
  /// app every morning is the kind of chore that makes people stop using
  /// the row at all.
  @AppStorage("quill.actMutedDestinations") private var mutedRaw = ""
  @AppStorage(IntegrationConnectionStore.userDefaultsKey) private var connectedIntegrationsData = Data()
  @Shared(.hexSettings) private var hexSettings: HexSettings

  @ObservedObject private var controller = MacSuggestionsController.shared
  @ObservedObject private var cloudSync = MacCloudSync.shared
  /// Holds the live action confirmation when one is routed into the window
  /// instead of the menu-bar popdown (see InAppActionPresenter).
  @ObservedObject private var actionPresenter = InAppActionPresenter.shared
  @State private var isActComposerVisible = false

  /// Everything the agent could route to right now.
  private var actDestinations: [QuillActDestination] {
    QuillActDestination.connected(
      integrations: IntegrationConnectionStore.decode(connectedIntegrationsData),
      servers: hexSettings.mcpServers
    )
  }

  /// …minus anything muted on the chip row. This is what the `@` menu
  /// offers and what the planner is allowed to choose among.
  private var routableDestinations: [QuillActDestination] {
    let muted = mutedDestinations
    return actDestinations.filter { !muted.contains($0.id) }
  }

  private var mutedDestinations: Set<String> {
    get { Set(mutedRaw.split(separator: "\n").map(String.init)) }
    nonmutating set { mutedRaw = newValue.sorted().joined(separator: "\n") }
  }

  private var recentNotes: [SyncableNote] {
    cloudSync.cloudNotes
      .sorted { $0.updatedAt > $1.updatedAt }
      .prefix(8)
      .map { $0 }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 34) {
        brandHeader
        // The mode toggle sits directly above the input bar and governs
        // it — same relationship as the iOS mode rail above the composer.
        VStack(alignment: .leading, spacing: 16) {
          sectionSwitcher
          captureRow
            .zIndex(1)  // the `@` menu overlays the chips below it
          if section == .act {
            ActDestinationChips(
              destinations: actDestinations,
              muted: Binding(get: { mutedDestinations }, set: { mutedDestinations = $0 }),
              onAdd: openIntegrations
            )
          }
        }
        .zIndex(1)  // …and over the suggestions/notes sections below

        // The workflow itself, when it's being hosted here: the plan lands
        // directly under the bar you typed it into, rather than dropping out
        // of the menu bar across the screen.
        if let actionStore = actionPresenter.store {
          inlineActionSection(actionStore)
        }

        switch section {
        case .act:
          suggestionsSection
        case .notes:
          VStack(alignment: .leading, spacing: 28) {
            if !controller.meetings.isEmpty {
              meetingStrip
            }
            recentNotesSection
          }
        }
      }
      .padding(.horizontal, 28)
      .padding(.top, 24)
      .padding(.bottom, 36)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    // A soft brand-violet wash bleeding from the top gives the pane its
    // identity without breaking the flat, no-shadow language.
    .background(
      RadialGradient(
        colors: [QuillDesign.brand.color(0.10), .clear],
        center: UnitPoint(x: 0.5, y: -0.15),
        startRadius: 0,
        endRadius: 620
      )
      .ignoresSafeArea()
    )
    .animation(.spring(duration: 0.35, bounce: 0.15), value: actionPresenter.store == nil)
    // Tells the presenter whether an inline confirmation is possible. Also
    // covers the window being closed — SwiftUI tears the pane down with it.
    .onAppear { actionPresenter.isHomeVisible = true }
    .onDisappear { actionPresenter.isHomeVisible = false }
    .onChange(of: sectionRaw) { _, _ in
      isActComposerVisible = false
    }
    .task {
      await controller.refreshOnAppear()
      if cloudSync.isGoogleAuthorized() {
        _ = await cloudSync.fetchCloudNotes()
      }
    }
  }

  // MARK: - Inline action workflow

  private func inlineActionSection(_ actionStore: StoreOf<MultiActionConfirmationFeature>) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionLabel("Action", systemImage: "bolt.fill")
      MultiActionConfirmationView(store: actionStore, isInline: true)
    }
    .transition(
      .asymmetric(
        insertion: .opacity.combined(with: .offset(y: -10)),
        removal: .opacity.combined(with: .scale(scale: 0.97))
      )
    )
  }

  // MARK: - Brand header

  /// The one large-type block on the page — everything below uses quiet
  /// uppercase section labels so the pane reads calm, not busy.
  private var brandHeader: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 9) {
        Image("Feather")
          .resizable()
          .renderingMode(.template)
          .aspectRatio(contentMode: .fit)
          .foregroundStyle(QuillDesign.brand.color())
          .frame(width: 26, height: 26)
        Text("Quill")
          .font(.system(size: 26, weight: .bold))
          .tracking(-0.5)
      }
      Text(greeting)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Section switcher

  /// Big, centered Actions | Notes toggle with live count bubbles —
  /// suggested actions on one side, today's meetings on the other, so
  /// each tab says whether it's worth visiting before you click.
  private var sectionSwitcher: some View {
    HStack(spacing: 4) {
      switcherButton(.act, count: controller.isPro ? controller.current.count : 0)
      switcherButton(.notes, count: controller.meetings.count)
    }
    .padding(4)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
        .fill(Color.primary.opacity(0.05))
        .overlay(
          RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    )
    .frame(maxWidth: 380)
    .frame(maxWidth: .infinity)
  }

  private func switcherButton(_ target: HomeSection, count: Int) -> some View {
    let isOn = section == target
    return Button {
      QuillMotion.run(.spring(duration: 0.3, bounce: 0.15)) {
        sectionRaw = target.rawValue
      }
    } label: {
      HStack(spacing: 7) {
        Text(target.title)
          .font(.system(size: 14, weight: isOn ? .bold : .medium))
        if count > 0 {
          Text("\(count)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isOn ? .white : .secondary)
            .frame(minWidth: 19)
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(
              Capsule().fill(isOn ? QuillDesign.brand.color() : Color.secondary.opacity(0.18))
            )
        }
      }
      .foregroundStyle(isOn ? .primary : .secondary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 9)
      .background(
        RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous)
          .fill(isOn ? Color.primary.opacity(0.08) : .clear)
      )
      .contentShape(RoundedRectangle(cornerRadius: QuillDesign.Radius.card, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(target.title)\(count > 0 ? ", \(count) item\(count == 1 ? "" : "s")" : "")")
    .accessibilityAddTraits(isOn ? [.isSelected] : [])
  }

  /// Small uppercase section label — one style for every section below
  /// the hero (matches the iOS home's section language).
  private func sectionLabel(_ title: String, systemImage: String? = nil) -> some View {
    HStack(spacing: 7) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
    }
  }

  private var greeting: String {
    switch Calendar.current.component(.hour, from: Date()) {
    case 5..<12: "Good morning — ready when you are."
    case 12..<17: "Good afternoon — ready when you are."
    case 17..<22: "Good evening — ready when you are."
    default: "Burning the midnight oil?"
    }
  }

  // MARK: - Capture row

  /// Both halves begin with two deliberate choices. Their text surfaces only
  /// appear after the user explicitly chooses to type or write.
  @ViewBuilder
  private var captureRow: some View {
    switch section {
    case .act:
      if isActComposerVisible {
        HStack(alignment: .top, spacing: 8) {
          ActCommandField(
            destinations: routableDestinations,
            icon: "bolt.fill",
            accent: QuillDesign.actionAccent,
            placeholder: "Type a command — \u{201C}remind me to call Kelly Friday\u{201D}",
            hint: "Type @ to send this to a specific app",
            onSubmit: submitCommand
          )
          .id(HomeSection.act)

          Button {
            QuillMotion.run(.easeOut(duration: 0.16)) {
              isActComposerVisible = false
            }
          } label: {
            Image(systemName: "xmark")
              .frame(width: 18, height: 18)
          }
          .buttonStyle(.borderless)
          .help("Hide text input")
          .accessibilityLabel("Hide text input")

          actionVoiceButton
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      } else {
        HStack(spacing: 10) {
          Spacer(minLength: 0)
          actionVoiceButton
          Button {
            QuillMotion.run(.easeOut(duration: 0.16)) {
              isActComposerVisible = true
            }
          } label: {
            Label("Type an action", systemImage: "keyboard")
          }
          .buttonStyle(.bordered)
          .controlSize(.large)
          .disabled(actionCaptureIsBusy)
          .help("Type a command for Quill")
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
      }

    case .notes:
      HStack(spacing: 10) {
        Spacer(minLength: 0)
        noteDictateButton
        Button {
          startTextNote()
        } label: {
          Label("Write a note", systemImage: "square.and.pencil")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help("Create a blank note and start writing")
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity)
    }
  }

  private var actionRecordingIsActive: Bool {
    transcriptionStore.isRecording && transcriptionStore.selectedMode == .action
  }

  private var actionCaptureIsBusy: Bool {
    transcriptionStore.isTranscribing
      || transcriptionStore.isAIProcessing
      || transcriptionStore.isPrewarming
      || (transcriptionStore.isRecording && !actionRecordingIsActive)
  }

  private var actionVoiceButton: some View {
    Button {
      if actionRecordingIsActive {
        transcriptionStore.send(.stopRecording)
      } else {
        transcriptionStore.send(.setMode(.action))
        transcriptionStore.send(.startRecording)
      }
    } label: {
      Label(
        actionRecordingIsActive ? "Finish action" : "Speak an action",
        systemImage: actionRecordingIsActive ? "stop.fill" : "mic.fill"
      )
    }
    .buttonStyle(.borderedProminent)
    .tint(actionRecordingIsActive ? .red : QuillDesign.actionAccent)
    .controlSize(.large)
    .disabled(actionCaptureIsBusy)
    .help(actionRecordingIsActive ? "Finish and review this action" : "Speak an action for Quill")
  }

  private var noteDictateButton: some View {
    Button {
      startDictation(title: "")
    } label: {
      Label("Dictate a note", systemImage: "mic.fill")
    }
    .buttonStyle(.borderedProminent)
    .tint(QuillDesign.brand.color())
    .controlSize(.large)
    .help("Start dictating into a new note")
  }

  private func startTextNote() {
    let note = makeNote(title: "")
    cloudSync.cloudNotes.insert(note, at: 0)
    cloudSync.markDirty(id: note.id)
    openNote(note.id)
  }

  private func submitCommand(_ text: String, pinned: [QuillActDestination]) {
    guard !text.isEmpty else { return }
    isActComposerVisible = false
    // Same pipeline as the menu bar's "Type a Command…" panel — routines,
    // memory, MCP context, then the confirmation panel. The targeting
    // carries both user signals: what they pinned with `@`, and what's
    // left enabled on the chip row.
    transcriptionStore.send(
      .typedActionSubmitted(
        text,
        targeting: ActTargeting(
          all: actDestinations, muted: mutedDestinations, pinned: pinned
        )
      )
    )
  }

  /// Create a note (pre-titled for a meeting when given), open it in the
  /// Notes editor, and start dictation the moment the editor appears.
  private func startDictation(title: String) {
    let note = makeNote(title: title)
    cloudSync.cloudNotes.insert(note, at: 0)
    cloudSync.markDirty(id: note.id)
    NoteSelectionState.shared.pendingDictationNoteID = note.id
    openNote(note.id)
  }

  private func makeNote(title: String) -> SyncableNote {
    let now = Date()
    return SyncableNote(
      id: UUID(),
      title: title,
      body: "",
      createdAt: now,
      updatedAt: now,
      isAutoTitle: title.isEmpty,
      sourceDevice: Host.current().localizedName ?? "Mac",
      sourcePlatform: .macOS
    )
  }

  // MARK: - Meeting strip

  /// "Dictate into a meeting" — tap starts a dictation whose note is
  /// pre-titled for the event. The in-progress meeting gets a NOW tag.
  private var meetingStrip: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionLabel("Dictate into a meeting", systemImage: "calendar")

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(controller.meetings) { meeting in
            meetingCard(meeting)
          }
        }
      }
    }
  }

  private func meetingCard(_ meeting: MacSuggestionSources.UpcomingMeeting) -> some View {
    let blue = QuillDesign.ModePalette.dictate
    return Button {
      startDictation(title: meeting.title)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Circle()
            .fill(meeting.isNow ? blue.color() : Color.secondary.opacity(0.5))
            .frame(width: 6, height: 6)
          Text(meeting.time)
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(meeting.isNow ? blue.color() : .secondary)
          if meeting.isNow {
            Text("NOW")
              .font(.system(size: 9, weight: .heavy))
              .tracking(0.4)
              .foregroundStyle(.white)
              .padding(.vertical, 1)
              .padding(.horizontal, 4)
              .background(RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous).fill(blue.color()))
          }
        }
        Text(meeting.title)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Label(
          meeting.detail.isEmpty ? "Dictate notes" : "Dictate notes · \(meeting.detail)",
          systemImage: "mic"
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
      .padding(.vertical, 9)
      .padding(.horizontal, 12)
      .frame(maxWidth: 220, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: QuillDesign.cardCornerRadius, style: .continuous)
        .fill(meeting.isNow ? blue.color(0.12) : Color.clear)
    )
    .quillCard()
  }

  // MARK: - Suggestions

  private var suggestionsSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 7) {
        sectionLabel("Suggestions", systemImage: "lightbulb.max")
        Text("PRO")
          .font(.system(size: 8.5, weight: .heavy))
          .tracking(0.4)
          .foregroundStyle(.white)
          .padding(.vertical, 1.5)
          .padding(.horizontal, 5)
          .background(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.badge, style: .continuous)
              .fill(QuillDesign.brand.color())
          )
        Spacer()
        if controller.isPro {
          Button {
            Task { await controller.regenerateNow() }
          } label: {
            if controller.isGenerating {
              ProgressView().controlSize(.small)
            } else {
              Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
            }
          }
          .buttonStyle(.borderless)
          .disabled(controller.isGenerating)
          .help("Check for new suggestions")
        }
      }

      if !controller.isPro {
        upsellCard
      } else if controller.current.isEmpty {
        emptyCard
      } else {
        // Staggered entrance sells the "it just found these" moment when
        // a generation pass lands.
        ForEach(Array(controller.current.enumerated()), id: \.element.id) { index, suggestion in
          MacSuggestionCard(
            suggestion: suggestion,
            onReview: { controller.review(suggestion) },
            onDismiss: { controller.dismiss(suggestion) }
          )
          .transition(
            .asymmetric(
              insertion: .opacity.combined(with: .offset(y: 12))
                .animation(.spring(duration: 0.45, bounce: 0.2).delay(Double(index) * 0.07)),
              removal: .opacity.animation(.easeOut(duration: 0.15))
            )
          )
        }
      }
    }
    .animation(.spring(duration: 0.35), value: controller.current)
  }

  private var upsellCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Proactive suggestions are a Pro feature", systemImage: "lock.fill")
        .font(.headline)
      Text("Let Quill watch your inbox, calendar, and contacts and offer ready-to-run actions — you always review before anything happens.")
        .font(.callout)
        .foregroundStyle(.secondary)
      Button("Enable Pro in Settings") { openSettings() }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .quillCard()
  }

  private var emptyCard: some View {
    HStack(spacing: 12) {
      Image(systemName: controller.hadNoReadableSources
        ? "antenna.radiowaves.left.and.right.slash" : "checkmark.circle.fill")
        .font(.system(size: 22))
        .foregroundStyle(
          controller.hadNoReadableSources
            ? QuillDesign.ModePalette.act.color()
            : QuillDesign.ModePalette.resolved.color()
        )
      VStack(alignment: .leading, spacing: 6) {
        Text(controller.hadNoReadableSources ? "Nothing to read yet" : "You're all caught up")
          .font(.headline)
        Text(
          controller.hadNoReadableSources
            ? "Connect readable sources — Gmail and Dex suggestions come from their MCP servers."
            : "Quill will nudge you when something's worth acting on."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        if controller.hadNoReadableSources {
          Button("Connect Sources") { openIntegrations() }
            .padding(.top, 2)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .quillCard()
  }

  // MARK: - Recent notes

  private var recentNotesSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        sectionLabel("Recent", systemImage: "note.text")
        Spacer()
        Button {
          openNotesPane()
        } label: {
          HStack(spacing: 3) {
            Text("All notes")
              .font(.system(size: 11, weight: .semibold))
            Image(systemName: "chevron.right")
              .font(.system(size: 8, weight: .semibold))
          }
        }
        .buttonStyle(.borderless)
      }

      if recentNotes.isEmpty {
        HStack(spacing: 12) {
          Image(systemName: "note.text")
            .font(.system(size: 20))
            .foregroundStyle(.secondary)
          Text(
            cloudSync.isGoogleAuthorized()
              ? "No synced notes yet — capture one here or on your iPhone."
              : "Connect Google in Settings to sync notes from your iPhone."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        .padding(16)
        .quillCard()
      } else {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          ForEach(recentNotes, id: \.id) { note in
            noteRow(note, relativeTo: context.date)
          }
        }
      }
    }
  }

  /// Home only needs to identify a recent note. The editor owns its content,
  /// metadata, and other detail once the user opens it.
  private func noteRow(_ note: SyncableNote, relativeTo now: Date) -> some View {
    Button {
      openNote(note.id)
    } label: {
      HStack(spacing: 10) {
        Text(noteDisplayTitle(note))
          .font(.system(size: 15, weight: .semibold))
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(RelativeNoteTimestamp.label(for: note.updatedAt, relativeTo: now))
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .fixedSize()
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.vertical, 12)
      .padding(.horizontal, 14)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .quillCard()
  }

  // Mirrors NoteListRow's derivations in NotesView.
  private func noteDisplayTitle(_ note: SyncableNote) -> String {
    let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { return trimmed }
    let stripped = NoteContent.stripPhotos(from: note.body)
    let firstLine = stripped.components(separatedBy: .newlines).first ?? stripped
    let words = firstLine.split(separator: " ", omittingEmptySubsequences: true).prefix(6).joined(separator: " ")
    return words.isEmpty ? "New Note" : String(words.prefix(60))
  }

}

// MARK: - Suggestion card

private struct MacSuggestionCard: View {
  let suggestion: Suggestion
  var onReview: () -> Void
  var onDismiss: () -> Void

  private var tint: Color { QuillDesign.destination(hue: suggestion.source.hue).color() }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: suggestion.source.systemImage)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 30, height: 30)
          .background(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .fill(tint.opacity(0.15))
          )
        VStack(alignment: .leading, spacing: 0) {
          Text(suggestion.source.displayName.uppercased())
            .font(.system(size: 10.5, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(tint)
          Text(suggestion.intents.count > 1 ? "\(suggestion.intents.count)-step action" : "Suggested action")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(action: onDismiss) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help("Dismiss — this suggestion won't come back")
      }

      Text(suggestion.headline)
        .font(.headline)
        .fixedSize(horizontal: false, vertical: true)

      if !suggestion.why.isEmpty {
        Label(suggestion.why, systemImage: "sparkles")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      HStack(spacing: 10) {
        stepChain
        Spacer(minLength: 8)
        Button {
          onReview()
        } label: {
          HStack(spacing: 4) {
            Text("Review")
            Image(systemName: "chevron.right")
              .font(.system(size: 9, weight: .bold))
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(QuillDesign.actionAccent)
        .help("Opens the editable confirmation — nothing runs until you click Run")
      }
    }
    .padding(16)
    .quillCard()
  }

  /// Destination pills joined by chevrons; consecutive same-destination
  /// steps collapse to a count (Gmail ×3).
  private var stepChain: some View {
    let groups = Self.groupedTargets(for: suggestion.intents)
    return ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 5) {
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
          if index > 0 {
            Image(systemName: "chevron.right")
              .font(.system(size: 8, weight: .semibold))
              .foregroundStyle(.tertiary)
          }
          HStack(spacing: 4) {
            Image(systemName: group.target.systemImage)
              .font(.system(size: 10, weight: .medium))
            Text(group.target.displayName)
              .font(.system(size: 11, weight: .semibold))
            if group.count > 1 {
              Text("×\(group.count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 3)
          .padding(.horizontal, 7)
          .background(
            RoundedRectangle(cornerRadius: QuillDesign.Radius.chip, style: .continuous)
              .fill(Color.primary.opacity(0.06))
          )
        }
      }
    }
  }

  private static func groupedTargets(for intents: [ActionIntent]) -> [(target: ConnectionTarget, count: Int)] {
    var result: [(target: ConnectionTarget, count: Int)] = []
    for intent in intents {
      let target = ConnectionTarget.forIntent(intent)
      if let last = result.last, last.target.displayName == target.displayName {
        result[result.count - 1].count += 1
      } else {
        result.append((target, 1))
      }
    }
    return result
  }
}
