import SwiftUI

/// The always-present chat at the bottom of the Dashboard. Collapsed it is a peek (last message line +
/// input bar); dragging the handle up (or tapping the peek) expands it to a full-height history.
/// It sits in a `ZStack` under `DashboardView`'s content, so the dashboard's sheets present above it.
///
/// Open/close is one continuous height: the content area between the handle and the input bar runs from
/// the peek's height to the full height, follows the finger while dragging, and springs to the nearer
/// end on release. The history list is always laid out at full height and only revealed, so nothing is
/// built, torn down or re-scrolled during the animation.
struct ChatOverlayView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = ChatViewModel()
    @Binding var isExpanded: Bool

    @State private var draft = ""
    @State private var photo: UIImage?
    @State private var showFoodCapture = false
    /// Live drag distance (positive = down) while the panel follows the finger.
    @State private var dragTranslation: CGFloat = 0
    @State private var peekHeight: CGFloat = 44
    @State private var inputBarHeight: CGFloat = 56
    @State private var pagingEnabled = false
    @State private var showTwinForecast = false
    @FocusState private var inputFocused: Bool

    private static let handleHeight: CGFloat = 21
    private static let topGap: CGFloat = 8
    private static let spring = Animation.spring(response: 0.38, dampingFraction: 0.86)

    var body: some View {
        GeometryReader { geo in
            let maxContent = max(peekHeight, geo.size.height - Self.handleHeight - inputBarHeight - 1 - Self.topGap)
            let height = contentHeight(maxContent: maxContent)
            let progress = maxContent > peekHeight
                ? min(1, max(0, (height - peekHeight) / (maxContent - peekHeight))) : (isExpanded ? 1 : 0)
            VStack(spacing: 0) {
                handle
                contentArea(height: height, maxContent: maxContent, progress: progress)
                Divider()
                inputBar
                    .readHeight { inputBarHeight = $0 }
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: -2)
                    .ignoresSafeArea(edges: .bottom)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .task {
            model.onNotesChanged = { [weak appState] in
                Task { await appState?.refreshAfterChatNotesChanged() }
            }
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
        // A note deleted outside the chat (Notes tab, dashboard) may undo a quick log shown here.
        .onChange(of: appState.notes.map(\.id)) { _ in Task { await model.refreshLoggedUndoState() } }
        .onChange(of: appState.preferredGlucoseUnit) { _ in syncPrompt() }
        .sheet(isPresented: $showFoodCapture) {
            FoodCaptureFlow { result in
                switch result {
                case .photo(let image):
                    // Attached to the draft so the user can add "bread 40 g" before sending.
                    photo = image
                case .arScan(let summary):
                    if let text = FoodCaptureResult.mealPrepText(summary) {
                        Task { await model.send(text: text, photoJPEG: nil) }
                    } else {
                        photo = summary.capturedImage // nothing recognised on device: let the backend look
                    }
                }
            }
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

    // MARK: Open / close

    /// The peek at the bottom fades out and the history (header, advice, messages) fades in as the area
    /// grows. The history is laid out at its full height and pinned to the bottom, so growing the area
    /// reveals the newest messages first, like a panel sliding up.
    private func contentArea(height: CGFloat, maxContent: CGFloat, progress: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                Divider()
                carbAdviceCard
                messageList
                    .frame(maxHeight: .infinity)
            }
            .frame(height: maxContent)
            .opacity(Double(progress))
            .allowsHitTesting(isExpanded && dragTranslation == 0)
            .accessibilityHidden(!isExpanded)

            peekLine
                .fixedSize(horizontal: false, vertical: true)
                .readHeight { if $0 > 0 { peekHeight = $0 } }
                .opacity(Double(1 - min(1, progress * 2.5)))
                .allowsHitTesting(!isExpanded)
                .accessibilityHidden(isExpanded)
        }
        .frame(height: height, alignment: .bottom)
        .clipped()
    }

    /// The resting height for the state, moved by the finger while dragging (clamped to the two ends,
    /// with a little rubber band past them).
    private func contentHeight(maxContent: CGFloat) -> CGFloat {
        let base = isExpanded ? maxContent : peekHeight
        let raw = base - dragTranslation
        if raw > maxContent { return maxContent + (raw - maxContent) * 0.15 }
        if raw < peekHeight { return peekHeight - (peekHeight - raw) * 0.15 }
        return raw
    }

    // MARK: Handle and drag

    private var handle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onTapGesture { setExpanded(!isExpanded) }
            .accessibilityLabel(isExpanded ? "Collapse chat" : "Expand chat")
            .accessibilityAddTraits(.isButton)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                if value.translation.height != 0, inputFocused { inputFocused = false }
                dragTranslation = value.translation.height
            }
            .onEnded { value in
                // Decide by where the fling would end, so a quick flick works as well as a long drag.
                let predicted = value.predictedEndTranslation.height
                let open = isExpanded ? predicted < 120 : predicted < -60
                setExpanded(open)
            }
    }

    private func setExpanded(_ expanded: Bool) {
        if !expanded { inputFocused = false }
        withAnimation(Self.spring) {
            isExpanded = expanded
            dragTranslation = 0
        }
    }

    // MARK: Peek

    private var peekLine: some View {
        HStack(spacing: 8) {
            if model.isSending {
                ProgressView().controlSize(.small)
            }
            Text(peekText)
                .font(.subheadline)
                .foregroundStyle(carbAdvice != nil ? Color.red : (model.lastMessageLine == nil ? .secondary : .primary))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            hitRatePill
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture { setExpanded(true) }
        .gesture(dragGesture)
    }

    // MARK: Carb advice

    private var carbAdvice: BackendAPI.CarbAdvice? {
        BackendAPI.CarbAdvice.visible(appState.calculations?.carbAdvice,
                                      calculationsStale: appState.calculationsStale,
                                      calculationsFromCache: appState.calculationsFromCache,
                                      hypoPromptOpen: appState.openHypoEvent != nil,
                                      tookIdentity: appState.tookCarbAdviceIdentity)
    }

    /// The advice headline (red) takes over the peek line while advice is showing.
    private var peekText: String {
        if let advice = carbAdvice { return ChatFormatting.carbAdviceHeadline(advice, unit: appState.preferredGlucoseUnit) }
        return model.lastMessageLine ?? "Ask about your glucose or log a dose, like \"5u 40g\""
    }

    @ViewBuilder
    private var carbAdviceCard: some View {
        if let advice = carbAdvice {
            CarbAdviceCardView(advice: advice, unit: appState.preferredGlucoseUnit, isBusy: model.isSending) { grams in
                let identity = advice.identity
                Task {
                    guard await model.sendFastCarbs(grams: grams) else { return }
                    appState.tookCarbAdviceIdentity = identity
                    await appState.refreshAfterChatNotesChanged()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: Expanded

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
            Spacer()
            hitRatePill
            Button { setExpanded(false) } label: {
                Image(systemName: "chevron.down")
            }
            .accessibilityLabel("Collapse chat")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .gesture(dragGesture)
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
                                       removal: removalActions)
                        .id(item.id)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomId)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onAppear {
                proxy.scrollTo(Self.bottomId, anchor: .bottom)
                // Only page older history once the list has settled at the bottom; otherwise the
                // top sentinel is visible on first layout and would load a page immediately.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pagingEnabled = true }
            }
            .onDisappear { pagingEnabled = false }
            .onChange(of: model.scrollAnchorId) { anchor in
                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
            }
            .onChange(of: model.bubbles.last) { _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomId, anchor: .bottom) }
            }
        }
    }

    private static let bottomId = "chat-bottom"

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
                Button { showFoodCapture = true } label: {
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
        Task { await model.send(text: text, photo: image) }
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private extension View {
    /// Reports this view's laid-out height whenever it changes.
    func readHeight(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
            .onPreferenceChange(HeightKey.self, perform: onChange)
    }
}
