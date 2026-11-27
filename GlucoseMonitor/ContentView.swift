import SwiftUI
import UIKit

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Int = 0
    /// The dose whose injection site is being asked about (mirrors `appState.pendingSiteNote`, delayed).
    @State private var siteNote: BackendAPI.GlucoseNote?

    private static let dashboardTab = 0
    static let chatTab = 1
    static let settingsTab = 2
    private static let tabItems: [SwipeTabBar.Item] = [
        .init(title: "Dashboard", systemImage: "waveform.path.ecg"),
        .init(title: "Chat", systemImage: "bubble.left.and.bubble.right"),
        .init(title: "Settings", systemImage: "gearshape"),
    ]
    /// Hides the tab bar while the keyboard is up (like the system tab bar), so it doesn't sit
    /// between the chat input and the keyboard.
    @State private var keyboardVisible = false
    /// Current horizontal swipe as a fraction of the page width (negative = towards the next tab).
    @State private var swipeFraction: CGFloat = 0
    /// Measured height of the floating tab bar; each page keeps this much clear at the bottom.
    @State private var tabBarHeight: CGFloat = 0
    /// Bumped when the Dashboard is opened (or a meal is logged in chat) to scroll it to the top.
    @State private var dashboardScrollTopTick = 0
    /// Bumped when Chat is opened to scroll it to the latest message.
    @State private var chatScrollBottomTick = 0
    /// Bumped when Settings is opened to scroll it to the top.
    @State private var settingsScrollTopTick = 0

    var body: some View {
        // The pages follow the finger while swiping left/right; SwipeTabBar is the bottom tab bar.
        // The tab bar floats over the pages like the iOS 26 system bar: scrolling content passes
        // underneath the glass, and each page reserves the bar's height in its bottom safe area
        // (`reservesTabBarSpace()`) so its last item can always be scrolled clear of the bar.
        SwipePager(selection: $selectedTab, dragFraction: $swipeFraction, pageCount: Self.tabItems.count) { index in
            page(index)
                .environment(\.tabBarInset, keyboardVisible ? 0 : tabBarHeight)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .bottom) {
            if !keyboardVisible {
                SwipeTabBar(selection: $selectedTab,
                            position: CGFloat(selectedTab) - swipeFraction,
                            items: Self.tabItems)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: TabBarHeightKey.self, value: geo.size.height)
                    })
            }
        }
        .onPreferenceChange(TabBarHeightKey.self) { tabBarHeight = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .onChange(of: selectedTab) { newTab in
            hideKeyboard()
            // All pages stay alive in the pager, so reset each one's scroll position when it opens.
            switch newTab {
            case Self.dashboardTab: dashboardScrollTopTick += 1
            case Self.chatTab: chatScrollBottomTick += 1
            default: settingsScrollTopTick += 1
            }
            // Refresh glucose values whenever the user opens (selects) the Dashboard tab. Force an
            // on-demand server sync so the data is fresh on open (no spinner). Safe to call
            // unconditionally: the backend serialises/coalesces per-user syncs, refreshGlucoseOnly
            // coalesces with any in-flight refresh, and the token refresh has its own 45-min throttle.
            guard newTab == Self.dashboardTab, appState.isAuthenticated else { return }
            Task { await appState.refreshGlucoseOnly(silent: true, forceServerSync: true) }
        }
        // "Where did you inject?" after a dose. The dose is saved while its logging sheet is still up,
        // and only one sheet can be presented at a time, so wait for that sheet to finish closing.
        .onChange(of: appState.pendingSiteNote) { note in
            guard let note else { return }
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                siteNote = note
                appState.pendingSiteNote = nil
            }
        }
        .sheet(item: $siteNote) { note in
            InjectionSitePickerSheet(note: note)
                .environmentObject(appState)
                .presentationDetents([.large])
        }
        .onAppear {
            appState.checkAuthentication()
            if appState.isAuthenticated {
                Task {
                    await GlucoseMonitorAPI.proactiveRefreshSessionTokensOnLaunch()
                    appState.checkAuthentication()
                    let hasCache = appState.currentReading != nil || !appState.glucoseHistory.isEmpty
                    if hasCache {
                        // Dashboard opened with cached data: force a fresh server sync (no spinner).
                        await appState.refreshGlucoseOnly(silent: true, forceServerSync: true)
                    } else if appState.currentReading == nil {
                        await appState.refreshAll()
                    }
                }
                appState.startAutoRefreshIfNeeded()
                BackgroundRefreshService.scheduleNextRefresh()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                guard appState.isAuthenticated else { return }
                BackgroundRefreshService.runBackgroundFetchIfNeeded()
            case .active:
                guard appState.isAuthenticated else { return }
                Task {
                    await GlucoseMonitorAPI.proactiveRefreshSessionTokens(minimumInterval: 10 * 60)
                    await MainActor.run { appState.checkAuthentication() }
                    let elapsed = appState.lastGlucoseRefresh.map { Date().timeIntervalSince($0) } ?? .infinity
                    // Opening the app always refreshes when the reading is over 5 min old; otherwise
                    // skip only if we refreshed in the last 45 s (quick app switches).
                    guard elapsed > 45 || appState.isReadingOutdated else { return }
                    if appState.currentReading == nil {
                        await appState.refreshAll()
                    } else {
                        await appState.refreshGlucoseOnly(silent: true, forceServerSync: true)
                    }
                }
            default:
                break
            }
        }
        .onChange(of: appState.isAuthenticated) { ok in
            if ok {
                selectedTab = Self.dashboardTab
                Task {
                    await GlucoseMonitorAPI.proactiveRefreshSessionTokensOnLaunch()
                    await MainActor.run { appState.checkAuthentication() }
                    // Fetch the user's data immediately after sign-in / LibreLinkUp connect so the
                    // dashboard shows real values right away instead of waiting for a manual
                    // pull-to-refresh or the 5-min auto-refresh. refreshAll forces a server-side
                    // LibreLinkUp sync (loadGlucoseHistory forceServerSync: true).
                    await appState.refreshAll()
                }
                appState.startAutoRefreshIfNeeded()
            } else {
                appState.stopAutoRefresh()
            }
        }
        .fullScreenCover(isPresented: Binding(
            get: { !appState.isAuthenticated },
            set: { _ in }
        )) {
            SignInView()
                .environmentObject(appState)
        }
    }
}

// MARK: - Tab pager

private struct TabBarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Height of the floating tab bar that page content must keep clear at the bottom.
    var tabBarInset: CGFloat {
        get { self[TabBarInsetKey.self] }
        set { self[TabBarInsetKey.self] = newValue }
    }
}

private struct ReservesTabBarSpace: ViewModifier {
    @Environment(\.tabBarInset) private var inset

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: inset)
        }
    }
}

extension View {
    /// Keeps the floating tab bar's height clear at the bottom of this screen: scroll views can
    /// still scroll under the glass, but their last item (and any bottom input bar) sits above it.
    /// Apply inside each NavigationStack, on the root and on pushed screens, because a
    /// NavigationStack doesn't pass on safe-area insets added outside it.
    func reservesTabBarSpace() -> some View {
        modifier(ReservesTabBarSpace())
    }
}

private struct TabBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension ContentView {
    @ViewBuilder
    fileprivate func page(_ index: Int) -> some View {
        switch index {
        case Self.dashboardTab:
            DashboardView(selectedTab: $selectedTab, scrollTopTick: $dashboardScrollTopTick)
        case Self.chatTab:
            ChatOverlayView(onMealLogged: {
                withAnimation(.tabSwipe) { selectedTab = Self.dashboardTab }
            }, scrollToBottomTick: chatScrollBottomTick)
        default:
            SettingsView(scrollTopTick: settingsScrollTopTick)
        }
    }
}

extension Animation {
    /// Page change / snap-back animation for the tab pager and tab bar.
    static let tabSwipe = Animation.spring(response: 0.3, dampingFraction: 0.9)
}

/// Horizontal pager that works like drag and drop: the current page moves exactly with the finger
/// and only changes once it has been dragged past a fifth of the screen width. Letting go before
/// that springs it back; a quick flick does not change the page.
struct SwipePager<Page: View>: View {
    @Binding var selection: Int
    /// The in-progress drag as a fraction of the page width (shared so the tab bar can follow it).
    @Binding var dragFraction: CGFloat
    let pageCount: Int
    @ViewBuilder let page: (Int) -> Page
    /// True while a horizontal swipe is in progress; pauses the pages' own scrolling meanwhile.
    @State private var isSwiping = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 0) {
                ForEach(0..<pageCount, id: \.self) { index in
                    page(index)
                        .frame(width: width, height: geo.size.height)
                        .accessibilityHidden(index != selection)
                }
            }
            .frame(width: width, alignment: .leading)
            .offset(x: (dragFraction - CGFloat(selection)) * width)
            .scrollDisabled(isSwiping)
            .background(
                WindowSwipeRecognizer(
                    onChanged: { dx in
                        if !isSwiping { hideKeyboard() }
                        isSwiping = true
                        // Rubber-band past the first and last page.
                        let atEdge = (selection == 0 && dx > 0) || (selection == pageCount - 1 && dx < 0)
                        guard width > 0 else { return }
                        dragFraction = (atEdge ? dx / 3 : dx) / width
                    },
                    onEnded: { dx in
                        isSwiping = false
                        var target = selection
                        if dx < -width / 5 {
                            target += 1
                        } else if dx > width / 5 {
                            target -= 1
                        }
                        target = min(max(target, 0), pageCount - 1)
                        withAnimation(.tabSwipe) {
                            selection = target
                            dragFraction = 0
                        }
                    }
                )
            )
        }
        .clipped()
    }
}

/// Recognises horizontal swipes anywhere in the window. SwiftUI gestures don't receive touches that
/// land on Lists, Forms, ScrollViews or buttons, so a UIKit pan recognizer is attached to the window
/// itself and runs alongside every other gesture. It stays inactive while a sheet, alert or
/// full-screen cover is shown, and yields to the navigation back swipe.
private struct WindowSwipeRecognizer: UIViewRepresentable {
    var onChanged: (CGFloat) -> Void
    /// Called with the final horizontal translation; 0 when the swipe was cancelled.
    var onEnded: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    static func dismantleUIView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AnchorView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attach(to: window)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChanged: ((CGFloat) -> Void)?
        var onEnded: ((CGFloat) -> Void)?
        private var pan: UIPanGestureRecognizer?

        /// Touches starting this close to the left edge are left to the system.
        private static let leftEdgeInset: CGFloat = 8

        func attach(to window: UIWindow?) {
            guard pan?.view !== window else { return }
            detach()
            guard let window else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            window.addGestureRecognizer(pan)
            self.pan = pan
        }

        func detach() {
            if let pan { pan.view?.removeGestureRecognizer(pan) }
            pan = nil
        }

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer, let window = pan.view as? UIWindow else {
                return false
            }
            // Not while anything (sheet, alert, sign-in cover) is presented over the tabs.
            if window.rootViewController?.presentedViewController != nil { return false }
            let start = pan.location(in: window).x - pan.translation(in: window).x
            guard start > Self.leftEdgeInset else { return false }
            let velocity = pan.velocity(in: window)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// The navigation back swipe (an edge pan) wins when it applies, e.g. on a pushed Settings
        /// page. On a root page it fails immediately, so the tab swipe starts without delay.
        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            other is UIScreenEdgePanGestureRecognizer
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            let dx = pan.translation(in: pan.view).x
            switch pan.state {
            case .began, .changed: onChanged?(dx)
            case .ended: onEnded?(dx)
            case .cancelled, .failed: onEnded?(0)
            default: break
            }
        }
    }
}

// MARK: - Tab bar

/// Bottom tab bar for the swipe pager, styled like the system tab bar: a floating Liquid Glass
/// capsule on iOS 26 and later, the classic flat bar on earlier versions.
struct SwipeTabBar: View {
    struct Item {
        let title: String
        let systemImage: String
    }

    @Binding var selection: Int
    /// Fractional tab position, following the finger during a swipe (e.g. 0.4 = 40% of the way
    /// from the first tab to the second).
    let position: CGFloat
    let items: [Item]


    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassBar
        } else {
            classicBar
        }
        #else
        classicBar
        #endif
    }

    private func select(_ index: Int) {
        withAnimation(.tabSwipe) { selection = index }
    }

    private func itemLabel(_ item: Item, weight: Font.Weight) -> some View {
        VStack(spacing: 3) {
            Image(systemName: item.systemImage)
                .font(.system(size: 22))
                .frame(height: 26)
            Text(item.title)
                .font(.system(size: 10, weight: weight))
        }
    }

    #if compiler(>=6.2)
    /// Floating glass capsule; the selection pill tracks `position`, so it slides with the finger
    /// during a swipe and animates with the page when the switch completes.
    @available(iOS 26.0, *)
    private var glassBar: some View {
        let pillPosition = min(max(position, 0), CGFloat(items.count - 1))
        let highlighted = Int(pillPosition.rounded())
        return HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { index in
                let item = items[index]
                let isSelected = highlighted == index
                Button {
                    select(index)
                } label: {
                    itemLabel(item, weight: .semibold)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .background {
            GeometryReader { geo in
                let itemWidth = geo.size.width / CGFloat(max(items.count, 1))
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: itemWidth, height: geo.size.height)
                    .offset(x: pillPosition * itemWidth)
            }
        }
        .padding(4)
        .glassEffect(.clear.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
    #endif

    private var classicBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    let isSelected = selection == index
                    Button {
                        select(index)
                    } label: {
                        itemLabel(item, weight: .medium)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 7)
                            .padding(.bottom, 3)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
        .background(.bar)
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var appState: AppState
    @Binding var selectedTab: Int
    @Binding var scrollTopTick: Int
    @State private var showAddNote = false
    @State private var selectedGlycemicEvent: BackendAPI.GlycemicEvent?
    @State private var showExtendedForecast = false
    @State private var showLongActing = false
    @State private var showActivity = false
    @State private var showTwinForecast = false
    @State private var noteToEdit: BackendAPI.GlucoseNote?
    @State private var isfSuggestion: BackendAPI.IsfMealWindowSuggestion?
    @State private var isfSuggestionBusy = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if !appState.isAuthenticated {
                    notSignedInPlaceholder
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 16) {
                                Color.clear.frame(height: 0).id("dashboardTop")
                                if appState.libreDataStale && scenePhase == .active {
                                    libreStaleBanner
                                }
                                // Re-evaluated on a timer so an expired dose strip leaves without waiting for a refresh.
                                TimelineView(.periodic(from: .now, by: 15)) { context in
                                    if let strip = appState.watchStrip(at: context.date) {
                                        WatchStripView(strip: strip, unit: appState.preferredGlucoseUnit) {
                                            withAnimation { proxy.scrollTo("forecastChart", anchor: .top) }
                                        }
                                    }
                                }
                                if let suggestion = isfSuggestion, shouldShowIsfBanner(suggestion) {
                                    isfSuggestionBanner(suggestion)
                                }
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    compactGlucoseCard(at: context.date)
                                }
                                extendedChartSection
                                    .id("forecastChart")
                                recentNotesSection
                                if appState.dataSource == "libre" {
                                    sensorAlarmsBar
                                }
                                quickActions
                                if let msg = appState.errorMessage {
                                    Text(msg)
                                        .font(.footnote)
                                        .foregroundColor(.red)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)
                                }
                            }
                            .padding()
                        }
                        .refreshable { await appState.refreshAll() }
                        .onChange(of: scrollTopTick) { _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation(.easeOut(duration: 0.25)) {
                                    proxy.scrollTo("dashboardTop", anchor: .top)
                                }
                            }
                        }
                    }
                }
            }
            .reservesTabBarSpace()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAddNote) {
                NoteEditorSheet { input, photo in
                    await appState.createNote(input, photo: photo)
                }
                .environmentObject(appState)
            }
            .sheet(isPresented: $showLongActing) {
                LongActingInsulinSheet(
                    insulinName: appState.insulinPrefs?.longActingInsulin.displayName ?? "Long-acting insulin"
                )
                .environmentObject(appState)
            }
            .sheet(isPresented: $showActivity) {
                ActivityNoteSheet()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showTwinForecast) {
                NavigationStack { TwinForecastView() }
                    .environmentObject(appState)
            }
            .sheet(item: $noteToEdit) { note in
                if note.isLongActing {
                    LongActingInsulinSheet(insulinName: note.meal, editing: note)
                        .environmentObject(appState)
                } else {
                    EditNoteSheet(note: note) { body in
                        await appState.updateNote(id: note.id, body: body)
                    }
                    .environmentObject(appState)
                }
            }
            .sheet(item: $selectedGlycemicEvent) { event in
                GlycemicEventDetailSheet(event: event)
                    .environmentObject(appState)
            }
            .sheet(item: $appState.openHypoEvent) { event in
                HypoPromptView(
                    event: event,
                    displayUnit: appState.preferredGlucoseUnit,
                    onConfirm: { grams in await appState.confirmHypo(grams: grams) },
                    onDismiss: { Task { await appState.dismissHypo() } }
                )
            }
            .task {
                guard appState.isAuthenticated else { return }
                if appState.currentReading == nil && appState.glucoseHistory.isEmpty {
                    await appState.refreshAll()
                } else {
                    let elapsed = appState.lastGlucoseRefresh.map { Date().timeIntervalSince($0) } ?? .infinity
                    if elapsed > 90 {
                        await appState.refreshGlucoseOnly(silent: true, forceServerSync: true)
                    }
                    await appState.fetchNotes()
                }
                await loadIsfSuggestion()
            }
        }
    }

    // MARK: - Morning ISF suggestion banner

    /// Local morning window (05:00-11:00) - banner only surfaces then even if the server says show.
    private var isLocalMorning: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        return (5 ..< 11).contains(hour)
    }

    private func shouldShowIsfBanner(_ suggestion: BackendAPI.IsfMealWindowSuggestion) -> Bool {
        suggestion.show && isLocalMorning && !suggestion.proposalLines.isEmpty
    }

    @ViewBuilder
    private func isfSuggestionBanner(_ suggestion: BackendAPI.IsfMealWindowSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("Updated settings ready")
                    .font(.subheadline.bold())
                Spacer()
            }
            Text("Based on your recent data, we suggest refining ISF and carb ratios by time of day. Review and apply, or dismiss for a few days.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(suggestion.allWindowsOrdered) { w in
                HStack {
                    Text(w.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle((w.hasIsfProposal || w.hasRatioProposal) ? .primary : .tertiary)
                    Spacer()
                    if w.hasIsfProposal || w.hasRatioProposal {
                        VStack(alignment: .trailing, spacing: 2) {
                            if let isf = w.isfText {
                                Text(isf)
                            }
                            if let ratio = w.ratioText {
                                Text(ratio)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    } else {
                        Text("No data yet")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    Task { await dismissIsfSuggestion() }
                } label: {
                    Text("Not now")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isfSuggestionBusy)

                Button {
                    Task { await acceptIsfSuggestion() }
                } label: {
                    Text("Apply")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(isfSuggestionBusy)
            }
        }
        .padding()
        .background(Color.purple.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.purple.opacity(0.35), lineWidth: 1)
        )
    }

    private func loadIsfSuggestion() async {
        guard appState.isAuthenticated, isLocalMorning else {
            isfSuggestion = nil
            return
        }
        do {
            isfSuggestion = try await BackendAPI.fetchIsfMealWindowSuggestion()
        } catch {
            isfSuggestion = nil
        }
    }

    private func acceptIsfSuggestion() async {
        isfSuggestionBusy = true
        defer { isfSuggestionBusy = false }
        do {
            try await BackendAPI.acceptIsfMealWindowSuggestion(includeRatios: true)
            isfSuggestion = nil
        } catch {
            appState.errorMessage = "Could not apply suggestion."
        }
    }

    private func dismissIsfSuggestion() async {
        isfSuggestionBusy = true
        defer { isfSuggestionBusy = false }
        do {
            try await BackendAPI.dismissIsfMealWindowSuggestion()
            isfSuggestion = nil
        } catch {
            isfSuggestion = nil
        }
    }

    // MARK: - Compact glucose card (widget-style current to prediction + stacked COB/IOB)

    private static let dashboardGlucoseOrange = Color(red: 1, green: 0.58, blue: 0)
    private static let dashboardCobTint = Color(red: 0.92, green: 0.55, blue: 0.12)
    private static let dashboardIobTint = Color(red: 0.35, green: 0.45, blue: 0.95)

    /// Shown while the readings are stale - LibreLinkUp is not answering, it answers but nothing new
    /// has arrived for 15 min, or it rejected the saved password - so the card hides the current
    /// value's status and the forecast. For rejected credentials, a tap opens Settings.
    @ViewBuilder
    private var libreStaleBanner: some View {
        let cause = appState.libreStaleCause ?? .upstreamDown
        if cause.needsSettings {
            Button { withAnimation(.tabSwipe) { selectedTab = ContentView.settingsTab } } label: { libreStaleBannerBody(cause) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Settings")
        } else {
            libreStaleBannerBody(cause)
        }
    }

    private func libreStaleBannerBody(_ cause: LibreStaleCause) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: cause.needsSettings ? "lock.trianglebadge.exclamationmark.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(cause.title)
                    .font(.subheadline.bold())
                // Re-evaluated every minute so "for 55 min" keeps counting between refreshes.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(cause.detail(lastReading: appState.currentReading?.timestamp, now: context.date))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if cause.needsSettings {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }

    private func compactGlucoseCard(at date: Date) -> some View {
        let calc = appState.calculations
        let pre = PreBolusTimer.state(notes: appState.notes, now: date)
        let cobStr = calc.map { String(format: "%.1f g", $0.activeCarbsOnBoard) } ?? "--"
        let iobStr = appState.displayedIOB.map { String(format: "%.2f u", $0) } ?? "--"

        return Group {
            if appState.isLoading && appState.currentReading == nil {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else if let r = appState.currentReading, let v = r.value {
                let displayUnit = appState.preferredGlucoseUnit
                let displayValue = convertGlucose(v, from: r.unit, to: displayUnit)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            glucosePredictionHeadline(current: displayValue, unit: displayUnit, calc: calc, trendArrow: r.trendArrow, expanded: showExtendedForecast,
                                                      hideValues: appState.libreDataStale)
                                .minimumScaleFactor(0.55)
                                .lineLimit(1)
                                .animation(.easeInOut(duration: 0.2), value: showExtendedForecast)
                                .onTapGesture {
                                    guard calc?.predictionPath?.isEmpty == false else { return }
                                    withAnimation(.easeInOut(duration: 0.2)) { showExtendedForecast.toggle() }
                                }

                            HStack(alignment: .center, spacing: 10) {
                                if let status = r.status, !appState.libreDataStale {
                                    statusBadge(status)
                                }
                            }

                            if let ts = r.timestamp {
                                (Text("Updated ") + Text(ts, style: .relative) + Text(" ago"))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            compactStackedMetric(
                                icon: "fork.knife",
                                title: "COB",
                                value: cobStr,
                                tint: Self.dashboardCobTint
                            )
                            compactStackedMetric(
                                icon: "syringe.fill",
                                title: "IOB",
                                value: iobStr,
                                tint: Self.dashboardIobTint
                            )
                            if appState.calculationsStale {
                                HStack(spacing: 3) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                    Text("Stale")
                                        .font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(appState.calculationsStale ? Color.orange.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 1)
                        )
                    }

                    if pre.visible {
                        HStack(spacing: 6) {
                            Image(systemName: "timer")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                            Text("Pre-bolus \(pre.label)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                    }
                }
            } else if let manual = appState.latestManualGlucose {
                let effectiveCurrent = appState.effectiveManualGlucoseMmol ?? manual.value
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            glucosePredictionHeadline(
                                current: effectiveCurrent,
                                unit: "mmol/L",
                                calc: calc,
                                expanded: showExtendedForecast
                            )
                            .minimumScaleFactor(0.55)
                            .lineLimit(1)
                            .animation(.easeInOut(duration: 0.2), value: showExtendedForecast)
                            .onTapGesture {
                                guard calc?.predictionPath?.isEmpty == false else { return }
                                withAnimation(.easeInOut(duration: 0.2)) { showExtendedForecast.toggle() }
                            }
                            (Text("Updated ") + Text(manual.timestamp, style: .relative) + Text(" ago"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            compactStackedMetric(icon: "fork.knife",  title: "COB", value: cobStr, tint: Self.dashboardCobTint)
                            compactStackedMetric(icon: "syringe.fill", title: "IOB", value: iobStr, tint: Self.dashboardIobTint)
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "drop.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No reading yet")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Pull down to refresh")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.07), radius: 10, y: 3)
    }

    @ViewBuilder
    private func glucosePredictionHeadline(current: Double, unit: String, calc: BackendAPI.GlucoseCalculationsResponse?, trendArrow: String? = nil, expanded: Bool = false,
                                           hideValues: Bool = false) -> some View {
        let unitStr = unitLabel(unit)
        let fourHour = calc?.predictionPath?.last?.predictedGlucose
        let trendArrowDisplay = hideValues ? "\u{2192}"
            : (trendArrow?.isEmpty == false && trendArrow != "?") ? trendArrow! : "\u{2192}"
        // Stale data (hideValues): show placeholders, never an old reading or a forecast built on it.
        let currentText = hideValues ? "--" : formatGlucose(current, unit: unit)

        if let calc {
            // Tap switches the single forecast slot between 2h and 4h (same position),
            // so high 2-digit values never get truncated by trying to show both at once.
            let showFour = expanded && fourHour != nil
            let forecastValue: Double = showFour ? (fourHour ?? calc.twoHourPrediction) : calc.twoHourPrediction
            VStack(alignment: .leading, spacing: 2) {
                // Label row
                HStack(spacing: 0) {
                    Text("Now")
                        .frame(minWidth: 60, alignment: .leading)
                    Spacer().frame(width: 36)
                    Text(showFour ? "4h forecast" : "2h forecast")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

                // Number row
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(currentText)
                        .frame(minWidth: 60, alignment: .leading)
                    Text(trendArrowDisplay)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(Self.dashboardGlucoseOrange.opacity(0.7))
                    Text(hideValues ? "--" : formatBackendGlucoseMmol(forecastValue, displayUnit: unit))
                    Text(unitStr)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Self.dashboardGlucoseOrange)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("Now")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(currentText)
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Self.dashboardGlucoseOrange)
                    Text(unitStr)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func compactStackedMetric(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint.opacity(0.9))
                Text(value)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - Chart

    // MARK: - Sensor & Alarms bar (LLU only)

    @ViewBuilder
    private var sensorAlarmsBar: some View {
        VStack(spacing: 8) {
            // Sensor row
            if let sensor = appState.sensorInfo, sensor.status != "unknown" {
                HStack(spacing: 8) {
                    Image(systemName: sensorStatusIcon(sensor.status))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(sensorStatusColor(sensor))
                    Text(sensor.sensorModel ?? "FreeStyle Libre")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if let remaining = sensor.daysRemaining {
                        Text(sensorRemainingLabel(remaining))
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(sensorStatusColor(sensor))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(sensorStatusColor(sensor).opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(sensorStatusColor(sensor).opacity(0.18), lineWidth: 1)
                )
            }

        }
    }

    private func sensorStatusIcon(_ status: String?) -> String {
        switch status {
        case "active":  return "sensor.tag.radiowaves.forward.fill"
        case "warmup":  return "timer"
        case "expired": return "exclamationmark.triangle.fill"
        default:        return "sensor.tag.radiowaves.forward"
        }
    }

    private func sensorStatusColor(_ sensor: GlucoseMonitorAPI.LibreSensorInfo) -> Color {
        let remaining = sensor.daysRemaining ?? 99
        switch sensor.status {
        case "expired": return .red
        case "warmup":  return .orange
        case "active":
            if remaining <= 1 { return .red }
            if remaining <= 3 { return .orange }
            return .green
        default: return .secondary
        }
    }

    private func sensorRemainingLabel(_ days: Int) -> String {
        if days < 0  { return "Expired" }
        if days == 0 { return "Expires today" }
        if days == 1 { return "1 day left" }
        return "\(days) days left"
    }

    private func lateProteinRiseBanner(_ rise: BackendAPI.GlucoseCalculationsResponse.LateProteinRise) -> some View {
        let started = rise.onsetAt <= Date()
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.up.right.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(started ? "Late rise from protein under way" : "Late rise from protein ~\(ChatFormatting.clock(rise.onsetAt))")
                    .font(.subheadline.weight(.semibold))
                Text("Gluconeogenesis \u{2248} \(String(format: "%.0f", rise.carbEquivalentG)) g slow carbs, already in the forecast")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var extendedChartSection: some View {
        let is8h = appState.calculations?.eightHourPrediction != nil
        let window: GlucoseChartWindow = is8h ? .extended : .standard
        return VStack(alignment: .leading, spacing: 8) {
            Text(is8h ? "Forecast (4h / 8h)" : "Forecast (4h)")
                .font(.headline)
            if let rise = appState.calculations?.lateProteinRise, !appState.libreDataStale {
                lateProteinRiseBanner(rise)
            }
            GlucoseHistoryChart(
                history: appState.glucoseHistory,
                // Stale LibreLinkUp data: no forecast curve built on an old reading.
                prediction: appState.libreDataStale ? [] : appState.predictionChartPoints(),
                notes: appState.notes,
                window: window,
                currentGlucose: appState.currentGlucoseMmolForAPI(),
                events: appState.glycemicEvents,
                onSelectEvent: { selectedGlycemicEvent = $0 }
            )
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }

    // MARK: - Recent notes (12h)

    private var recentNotesSection: some View {
        let slice = recentNotesLast12Hours
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent notes (12h)")
                    .font(.headline)
                Spacer()
                if appState.isLoadingNotes {
                    ProgressView()
                        .scaleEffect(0.75)
                }
                Button {
                    showAddNote = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            if appState.isLoadingNotes && appState.notes.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading notes???")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if let err = appState.notesLoadError, slice.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            } else if slice.isEmpty {
                Text("No notes in the last 12 hours.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                List {
                    ForEach(slice) { note in
                        RecentNoteRow(note: note)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.visible)
                            .contentShape(Rectangle())
                            .onTapGesture { noteToEdit = note }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .environment(\.defaultMinListRowHeight, 72)
                .frame(height: CGFloat(slice.count) * 100)
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }

    private var recentNotesLast12Hours: [BackendAPI.GlucoseNote] {
        let now = Date()
        let start = now.addingTimeInterval(-12 * 3600)
        return appState.notes
            .filter {
                guard let t = $0.timestamp else { return false }
                return t >= start && t <= now
            }
            .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
            .prefix(8)
            .map { $0 }
    }

    // MARK: - Quick actions

    /// Long-acting (basal) logging row. Always tappable; the configured injection time only drives
    /// the subtitle hint ("Due" / "Log now" / "Next at").
    private var longActingActionRow: some View {
        let status = LongActingSchedule.status(injectionTimeHHmm: appState.insulinPrefs?.longActingInjectionTime)
        return Button { showLongActing = true } label: {
            HStack {
                Label("Long-acting insulin", systemImage: "syringe")
                    .font(.subheadline)
                Spacer()
                if !status.label.isEmpty {
                    Text(status.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .foregroundColor(.primary)
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Actions")
                .font(.headline)
            VStack(spacing: 0) {
                longActingActionRow
                Divider()
                Button { showActivity = true } label: {
                    quickActionRow(title: "Log activity", systemImage: "figure.run")
                }
                Divider()
                Button { showTwinForecast = true } label: {
                    quickActionRow(title: "Forecast at each log", systemImage: "chart.line.uptrend.xyaxis")
                }
                // SickModeSection renders nothing when sick mode is off and data is from cache.
                if appState.sickMode?.active == true || !appState.calculationsFromCache {
                    Divider()
                    SickModeSection(appState: appState)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }

    private func quickActionRow(title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .foregroundColor(.primary)
    }

    // MARK: Placeholder

    private var notSignedInPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("Not signed in")
                .font(.title2.bold())
            Text("Open Settings to configure your backend and sign in.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: Helpers

    private func statusBadge(_ status: String) -> some View {
        let label: String
        let color: Color
        switch status.lowercased() {
        case "critical": label = "Critical"; color = .red
        case "low":      label = "Low";      color = .orange
        case "high":     label = "High";     color = Color(red: 0.85, green: 0.55, blue: 0)
        default:         label = "Normal";   color = .green
        }
        return Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    /// Convert a glucose value between units. `from` is the source unit string (nil treated as mmol/L).
    private func convertGlucose(_ value: Double, from sourceUnit: String?, to targetUnit: String) -> Double {
        let srcIsMg = (sourceUnit ?? "mmol/L").lowercased().contains("mg")
        let dstIsMg = targetUnit.lowercased().contains("mg")
        if srcIsMg == dstIsMg { return value }
        return srcIsMg ? GlucoseUnit.mgdlToMmol(value) : GlucoseUnit.mmolToMgdl(value)
    }

    private func formatGlucose(_ value: Double, unit: String) -> String {
        unit.lowercased().contains("mg")
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    /// Backend predictions are mmol/L; convert to the display unit.
    private func formatBackendGlucoseMmol(_ mmol: Double, displayUnit: String) -> String {
        if displayUnit.lowercased().contains("mg") {
            return String(format: "%.0f", GlucoseUnit.mmolToMgdl(mmol))
        }
        return String(format: "%.1f", mmol)
    }

    private func unitLabel(_ unit: String) -> String {
        unit.lowercased().contains("mg") ? "mg/dL" : "mmol/L"
    }

}

// MARK: - Recent note row (dashboard)

private struct RecentNoteRow: View {
    let note: BackendAPI.GlucoseNote
    @EnvironmentObject private var appState: AppState
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.green.opacity(0.6))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(note.displayTitle)
                    .font(.subheadline.weight(.medium))
                if let ts = note.timestamp {
                    Text(ts, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    if note.carbs > 0 {
                        Text(String(format: "%.0f g", note.carbs))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if note.insulin > 0 {
                        Text(String(format: "%.1f u", note.insulin))
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if let gv = appState.glucoseMmolForNoteRowDisplay(note) {
                        Label(String(format: "%.1f", gv), systemImage: "drop.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let photoUrl = note.photoUrl, !photoUrl.isEmpty {
                NotePhotoThumbnail(urlString: photoUrl)
            }
            Button {
                confirmDelete = true
            } label: {
                Text("Del")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .frame(alignment: .center)
            .alert("Delete note?", isPresented: $confirmDelete) {
                Button("Yes", role: .destructive) {
                    Task { await appState.deleteNote(id: note.id) }
                }
                Button("No", role: .cancel) {}
            }
        }
        .padding(.vertical, 6)
    }
}


struct NotePhotoThumbnail: View {
    let urlString: String
    var width: CGFloat? = 52
    var height: CGFloat = 52
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: width, height: height)
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            }
        }
        .task(id: urlString) {
            image = await loadImage(from: urlString)
        }
    }

    private func loadImage(from urlString: String) async -> UIImage? {
        let base = GlucoseMonitorAPI.effectiveBackendBaseURL()
        let isBackendRelative = !(urlString.hasPrefix("http://") || urlString.hasPrefix("https://"))
        let fullURL = isBackendRelative
            ? base + (urlString.hasPrefix("/") ? urlString : "/\(urlString)")
            : urlString
        guard let url = URL(string: fullURL) else {
            print("[NotePhotoThumbnail] invalid URL: \(fullURL)")
            return nil
        }
        var request = URLRequest(url: url)
        if isBackendRelative, let token = GlucoseMonitorAPI.storedAccessToken(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("[NotePhotoThumbnail] HTTP \(http.statusCode) loading \(url)")
                return nil
            }
            if let image = UIImage(data: data) {
                return image
            }
            print("[NotePhotoThumbnail] could not decode image data (\(data.count) bytes) from \(url)")
            return nil
        } catch {
            print("[NotePhotoThumbnail] failed to load \(url): \(error)")
            return nil
        }
    }
}
