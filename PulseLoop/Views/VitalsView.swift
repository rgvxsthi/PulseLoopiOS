import SwiftUI
import SwiftData

struct VitalsView: View {
    @Binding var path: NavigationPath
    /// Whether the Vitals tab is the one on screen. The `.page` TabView keeps adjacent tabs alive, so
    /// we gate expensive rebuilds on visibility — an off-screen Vitals must not rebuild on every sync.
    let isActive: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(RingSyncCoordinator.self) private var coordinator
    @Environment(\.zoomNamespace) private var zoomNS
    @Query private var profiles: [UserProfile]
    @State private var measuring: MeasurementSheet.Kind?
    @State private var dataChange = PulseDataChange.shared
    /// Owns the prepared vitals state. Created lazily in `.task` (never in `body`) so a `body`
    /// re-render never triggers DB work — it just reads the already-prepared store.
    @State private var store: VitalsStore?
    // Card reorder ("edit mode"): long-press a card to enter, drag to reorder, Done to exit.
    @State private var editing = false
    @State private var dragging: MetricKey?
    @State private var prefs = MetricPrefsStore.shared

    /// Canonical Vitals card order (used until the user reorders). Card id = `MetricKey`.
    private static let defaultOrder: [MetricKey] = [
        .heartRate, .spo2, .bloodPressureSystolic, .hrv, .stress, .fatigue, .bloodSugar, .temperature
    ]

    private var profile: UserProfile? { profiles.first }

    var body: some View {
        guard let activeStore = store else {
            return AnyView(PulseColors.background.ignoresSafeArea().task { ensureStore() })
        }

        return AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                measureRow(activeStore)
                grid(activeStore)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .background(PulseColors.background)
        .refreshable { await coordinator.pullToRefresh() }
        .pulseScrollEdges()
        .overlay(alignment: .top) { if editing { editDoneBar } }
        .task { ensureStore(); if isActive { store?.updateProfile(profile) } }
        .onChange(of: dataChange.token) { _, _ in if isActive { store?.refreshIfNeeded() } }
        .onChange(of: isActive) { _, active in if active { store?.updateProfile(profile) } }
        .onChange(of: profile?.updatedAt) { _, _ in store?.updateProfile(profile) }
        .sheet(item: Binding(get: { measuring.map(VitalsMeasuringItem.init) }, set: { measuring = $0?.kind })) { item in
            MeasurementSheet(kind: item.kind)
        })
    }

    /// Floating "Done" pill shown while reordering; also reminds the user to drag.
    private var editDoneBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down")
                .font(PulseFont.caption.weight(.semibold))
            Text("Drag to reorder")
                .font(PulseFont.subheadline.weight(.semibold))
            Spacer(minLength: 12)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { editing = false }
            } label: {
                Text("Done").font(PulseFont.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(PulseColors.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .pulseGlass(Capsule(), interactive: true)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Measure row

    @ViewBuilder
    private func measureRow(_ store: VitalsStore) -> some View {
        // On-demand spot measurements are capability-gated. A combined "Measure now" button (BP + SpO₂
        // + stress) needs a new BLE command and is deferred; for now we surface the supported spot
        // readings the ring can do today.
        // TODO(combined-measure): replace these with a single "Measure now" pill once the combined
        // measurement command lands.
        let caps = store.capabilities
        if caps.contains(.manualHeartRate) || caps.contains(.manualSpo2) {
            HStack(spacing: 8) {
                if caps.contains(.manualHeartRate) {
                    QuickActionButton(label: "Measure HR", accent: true) { measuring = .hr }
                }
                if caps.contains(.manualSpo2) {
                    QuickActionButton(label: "Measure SpO₂") { measuring = .spo2 }
                }
            }
        }
    }

    // MARK: - Grid

    /// Single full-width column, rendered in the user's saved order. Each card uses the full
    /// app width so values and charts stay legible. Long-press any card → reorder mode.
    @ViewBuilder
    private func grid(_ store: VitalsStore) -> some View {
        let physiology = UserPhysiologyProfile(profile)
        let keys = orderedKeys(store)

        VStack(spacing: 14) {
            ReorderableForEach(items: keys, isEditing: editing, dragging: $dragging,
                               move: { from, to in move(keys, from, to) }) { key in
                cardFor(key, store, physiology)
                    // simultaneousGesture so the long-press fires even though each card is a Button
                    // (a plain .onLongPressGesture is swallowed by the button's own tap gesture).
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.45).onEnded { _ in enterEdit() }
                    )
            }
        }
    }

    /// Visible Vitals cards in the saved order (falling back to `defaultOrder`).
    private func orderedKeys(_ store: VitalsStore) -> [MetricKey] {
        let visible = store.visibleMetrics.intersection(Set(Self.defaultOrder))
        let raws = prefs.resolvedOrder(
            visible: Set(visible.map(\.rawValue)),
            defaultOrder: Self.defaultOrder.map(\.rawValue),
            scope: .vitals
        )
        return raws.compactMap { MetricKey(rawValue: $0) }
    }

    @ViewBuilder
    private func cardFor(_ key: MetricKey, _ store: VitalsStore, _ physiology: UserPhysiologyProfile) -> some View {
        switch key {
        case .heartRate: chartCard(store, .heartRate, physiology)
        case .spo2: chartCard(store, .spo2, physiology, showPoints: true)
        case .bloodPressureSystolic: bpCard(store, physiology)
        case .hrv: chartCard(store, .hrv, physiology)
        case .stress:
            if let m = card(store, .stress) { VitalGaugeCard(model: m) { open(.stress) } }
        case .fatigue:
            if let m = card(store, .fatigue) { VitalGaugeCard(model: m) { open(.fatigue) } }
        case .bloodSugar:
            if let g = card(store, .glucose) { VitalGlucoseCard(model: g) { open(.glucose) } }
        case .temperature: chartCard(store, .temperature, physiology)
        default: EmptyView()
        }
    }

    private func move(_ keys: [MetricKey], _ from: Int, _ to: Int) {
        var k = keys
        let item = k.remove(at: from)
        k.insert(item, at: min(to, k.count))
        prefs.setOrder(k.map(\.rawValue), for: .vitals)
    }

    private func enterEdit() {
        guard !editing else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeInOut(duration: 0.2)) { editing = true }
    }

    // MARK: - Card builders

    private func card(_ store: VitalsStore, _ metric: MetricKind) -> VitalCardViewModel? {
        guard store.visibleMetrics.contains(metric.metricKey) else { return nil }
        return store.cards[metric]
    }

    @ViewBuilder
    private func chartCard(_ store: VitalsStore, _ metric: MetricKind,
                           _ physiology: UserPhysiologyProfile, showPoints: Bool = false) -> some View {
        if let model = card(store, metric) {
            let baseline = metric == .hrv ? BaselineStats.compute(store.hrvSamples) : nil
            VitalChartCard(model: model, profile: physiology, baseline: baseline, showPoints: showPoints) { open(metric) }
                .pulseZoomSource(AppRoute.metricDetail(metric), in: zoomNS)
        }
    }

    @ViewBuilder
    private func bpCard(_ store: VitalsStore, _ physiology: UserPhysiologyProfile) -> some View {
        if let model = card(store, .bloodPressure) {
            VitalBloodPressureCard(
                model: model,
                systolic: store.systolicSamples.last?.value,
                diastolic: store.diastolicSamples.last?.value,
                systolicZones: VitalsThresholdEngine.zones(for: .bloodPressure, profile: physiology),
                diastolicZones: VitalsThresholdEngine.diastolicReferenceZones(),
                onTap: { open(.bloodPressure) }
            )
            .pulseZoomSource(AppRoute.metricDetail(.bloodPressure), in: zoomNS)
        }
    }

    private func open(_ metric: MetricKind) {
        path.append(AppRoute.metricDetail(metric))
    }

    // MARK: - Store lifecycle

    private func ensureStore() {
        if store == nil { store = VitalsStore(modelContext: modelContext, profile: profile) }
    }
}

private struct VitalsMeasuringItem: Identifiable {
    let kind: MeasurementSheet.Kind
    var id: Int { kind == .hr ? 0 : 1 }
}
