import SwiftUI

/// Full-screen Chat tab: glucose header, transcript, and composer. Always open (no peek / collapse).
struct ChatOverlayView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = ChatViewModel()
    /// After a meal is logged from a plan card: parent switches to the dashboard and scrolls up.
    var onMealLogged: (() -> Void)? = nil

    @State private var draft = ""
    @State private var photo: UIImage?
    @State private var showFoodCamera = false
    @State private var showFoodLibrary = false
    @State private var pagingEnabled = false
    @State private var showTwinForecast = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                messageList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                inputBar
            }
            .background(Color(.systemBackground))
            .navigationBarHidden(true)
        }
        .task {
            model.onNotesChanged = { [weak appState] in
                Task { await appState?.refreshAfterChatNotesChanged() }
            }
            model.onDoseLogged = { [weak appState] noteIds in
                Task { await appState?.refreshAfterChatNotesChanged(askSiteFor: noteIds) }
            }
            model.onMealLogged = { onMealLogged?() }
            model.onAnswerPrompt = { [weak appState] event, category, carbs, insulin in
                await appState?.answerGlycemicEvent(event, category: category, carbs: carbs, insulin: insulin) ?? false
            }
            model.onDismissPrompt = { [weak appState] event in
                await appState?.dismissGlycemicEvent(event) ?? false
            }
            model.onSnoozePrompt = { [weak appState] in appState?.snoozeGlycemicPrompt() }
            syncPrompt()
            await model.loadInitial()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await model.loadHitRate() }
        }
        .sheet(isPresented: $showTwinForecast) {
            NavigationStack { TwinForecastView() }
                .environmentObject(appState)
        }
        .onChange(of: appState.visibleGlycemicPrompt) { _ in syncPrompt() }
        .onChange(of: appState.notes.map(\.id)) { _ in Task { await model.refreshLoggedUndoState() } }
        .onChange(of: appState.preferredGlucoseUnit) { _ in syncPrompt() }
        .fullScreenCover(isPresented: $showFoodCamera) {
            CameraPickerView(isPresented: $showFoodCamera, sourceType: .camera) { image in
                photo = image
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showFoodLibrary) {
            CameraPickerView(isPresented: $showFoodLibrary, sourceType: .photoLibrary) { image in
                photo = image
            }
            .ignoresSafeArea()
        }
    }

    private func mealPlanActions(_ card: MealPlanCard) -> MealPlanActions {
        let id = card.messageId
        return MealPlanActions(
            isBusy: model.busyPlanIds.contains(id),
            isReplaced: MealPlanRules.isReplaced(card, newestPlanId: model.newestPlanId),
            onTook: { dose, pause in Task { await model.tookPlan(messageId: id, doseUnits: dose, pauseMinutes: pause) } },
            onEat: { macros, ateAt in Task { await model.eatPlan(messageId: id, macros: macros, ateAt: ateAt) } },
            onSkip: { Task { await model.skipPlan(messageId: id) } },
            onReplan: { items in Task { await model.replan(items: items) } },
            bannerState: model.bannerState(id),
            onChooseDose: { units in Task { await model.chooseBannerDose(messageId: id, units: units) } },
            onConfirmRed: { model.confirmBannerRed(messageId: id) },
            onBannerBack: { model.resetBanner(messageId: id) })
    }

    private func proposalActions(_ card: EventProposalCard) -> EventProposalActions {
        let id = card.messageId
        return EventProposalActions(
            isBusy: model.busyProposalIds.contains(id),
            onConfirm: { Task { await model.confirmProposal(messageId: id) } },
            onDismiss: { model.dismissProposal(messageId: id) })
    }

    private func sickActions(_ card: SickModeChatCard) -> SickModeChatActions {
        let id = card.messageId
        return SickModeChatActions(
            isBusy: model.busySickIds.contains(id),
            onTurnOn: { severity, since in
                Task {
                    await model.runSickCommand(messageId: id) {
                        guard let status = await appState.startSickMode(severity, since: since), status.active else { return nil }
                        return SickModeChatCard.doneOnText(status.severity ?? severity)
                    }
                }
            },
            onEnd: {
                Task {
                    await model.runSickCommand(messageId: id) {
                        guard let status = await appState.endSickMode(reason: "USER"), !status.active else { return nil }
                        return SickModeChatCard.doneEndedText
                    }
                }
            })
    }

    private func removalActions(_ card: NoteRemovalCard) -> NoteRemovalActions {
        let id = card.messageId
        return NoteRemovalActions(
            isBusy: model.busyRemovalIds.contains(id),
            onRemove: { Task { await model.confirmRemoval(messageId: id) } },
            onKeep: { model.keepRemoval(messageId: id) })
    }

    private func syncPrompt() {
        model.setPendingPrompt(appState.visibleGlycemicPrompt, displayUnit: appState.preferredGlucoseUnit)
    }

    private var promptActions: GlycemicPromptActions {
        GlycemicPromptActions(
            isBusy: appState.isAnsweringGlycemicPrompt,
            onAnswer: { category, carbs, insulin in
                Task { await model.answerPrompt(category: category, carbs: carbs, insulin: insulin) }
            },
            onNotSure: { model.snoozePrompt() },
            onNothing: { Task { await model.dismissPrompt() } })
    }

    // MARK: Header

    private var header: some View {
        let unit = appState.preferredGlucoseUnit
        let reading = appState.currentGlucoseMmolForAPI().map { ChatFormatting.glucose(mmol: $0, unit: unit) } ?? "--"
        let arrow = appState.currentReading?.trendArrow.flatMap { $0.isEmpty || $0 == "?" ? nil : $0 } ?? ""
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(reading) \(arrow)")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(ChatFormatting.iobCob(iob: appState.displayedIOB, cob: appState.calculations?.activeCarbsOnBoard))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            hitRatePill
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var hitRatePill: some View {
        if let label = model.hitRateLabel {
            Button { showTwinForecast = true } label: {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(label) forecast accuracy, tap to see past forecasts")
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if model.historyLoaded && model.hasMoreHistory {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .onAppear {
                                guard pagingEnabled else { return }
                                Task { await model.loadOlder() }
                            }
                    }
                    let bubbles = model.bubbles
                    ForEach(Array(bubbles.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || !Calendar.current.isDate(item.createdAt, inSameDayAs: bubbles[index - 1].createdAt) {
                            ChatDaySeparator(date: item.createdAt)
                        }
                        ChatMessageRow(item: item, displayUnit: appState.preferredGlucoseUnit,
                                       onUndo: { Task { await model.undo(itemId: item.id) } },
                                       prompt: promptActions,
                                       mealPlan: mealPlanActions,
                                       proposal: proposalActions,
                                       removal: removalActions,
                                       sickMode: sickActions)
                        .id(item.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomId)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                scrollToBottom(proxy)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pagingEnabled = true }
            }
            .onDisappear { pagingEnabled = false }
            .onChange(of: model.scrollAnchorId) { anchor in
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            }
            .onChange(of: model.bubbles.last?.id) { _ in scrollToBottom(proxy) }
            .onChange(of: model.lastMessageLine) { _ in scrollToBottom(proxy) }
            .onChange(of: model.isSending) { _ in scrollToBottom(proxy) }
        }
    }

    private static let bottomId = "chat-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
            }
        }
    }

    // MARK: Input

    private var canSend: Bool {
        !model.isSending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil)
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let photo {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Button {
                        self.photo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .offset(x: 6, y: -6)
                    .accessibilityLabel("Remove photo")
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Write or add a photo…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    FoodSourcePicker.present(
                        onCamera: { FoodCameraAuth.requestAndRun { showFoodCamera = true } },
                        onLibrary: { showFoodLibrary = true })
                } label: {
                    Image(systemName: "camera")
                        .font(.title3)
                        .padding(.bottom, 6)
                }
                .disabled(model.isSending)
                .accessibilityLabel("Scan food or add a photo")
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        let image = photo
        draft = ""
        photo = nil
        inputFocused = false
        Task { await model.send(text: text, photo: image) }
    }
}
