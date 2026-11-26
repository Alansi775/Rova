import SwiftUI

struct SettingsView: View {
    /// Mirrors SpokenGuidance's own stored setting so the toggle can bind to
    /// it, and plays a sample the moment it is switched on: nobody should
    /// have to board a bus to find out what an app is about to say into
    /// their music.
    @State private var speakStops = SpokenGuidance.shared.isEnabled
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var engine: JourneyEngine
    @Environment(\.dismiss) private var dismiss

    private let store = TransitStore.shared

    private func applySpokenSetting(_ on: Bool) {
        SpokenGuidance.shared.isEnabled = on
        if on { SpokenGuidance.shared.demonstrate() }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Journey") {
                    labelled("Start", settings.home.name, settings.home.subtitle)
                    labelled("Destination", settings.destination.name, settings.destination.subtitle)
                    Button("Reset to Şafak Residence → Avcılar Metrobüs") {
                        settings.resetJourney(); Haptic.success(); dismiss()
                    }
                }

                Section {
                    row("Stops", store.meta["stop_count"] ?? "—")
                    row("Lines", store.meta["line_count"] ?? "—")
                    row("Route variants", store.meta["pattern_count"] ?? "—")
                    row("Bundle built", (store.meta["built_at"] ?? "").prefix(10).description)
                } header: { Text("Bundled network") }
                  footer: { Text("Stops and lines come from the İETT UlasimAnaVeri service. Timetables and stop sequences come from the İBB Open Data GTFS feed.") }

                Section {
                    row("Requests left this hour", "\(engine.requestsLeft) / 80")
                    row("Last refresh", engine.lastRefresh.map(Fmt.clock) ?? "—")
                    if let p = engine.liveProblem {
                        Text(p).font(.rvCaption).foregroundStyle(RV.Color.stale)
                    }
                } header: { Text("Live data") }
                  footer: { Text("Vehicle positions come straight from İETT's GetHatOtoKonum_json service. İETT publishes a limit of 100 requests per hour, so ROVA keeps itself below 80 and refreshes the line you are watching most often.") }

                Section {
                    Toggle("Start from my location", isOn: $settings.followMyLocation)
                } header: { Text("Journey") }
                  footer: { Text("On, ROVA plans from wherever you are. Off, it keeps the starting point you last chose.") }

                Section {
                    Stepper("Notify \(settings.notifyBeforeMinutes) min before",
                            value: $settings.notifyBeforeMinutes, in: 2...20)
                } header: { Text("Notifications") }

                Section {
                    Toggle("Say the stop out loud", isOn: $speakStops)
                        .onChange(of: speakStops) { _, on in applySpokenSetting(on) }
                    if speakStops {
                        Button("Hear what it sounds like") {
                            SpokenGuidance.shared.demonstrate()
                        }
                    }
                } header: { Text("Headphones") }
                  footer: {
                      Text("With headphones in and the phone in a pocket, ROVA lowers your music, plays a short chime and says the stop — two stops before you get off, then again on the one before, then at your stop. It speaks only when it can actually see where the bus is; a lost signal means silence, never a guess.")
                  }

                Section {
                    Toggle("Use ROVA backend", isOn: $settings.useBackend)
                    if settings.useBackend {
                        TextField("https://…", text: $settings.backendURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        SecureField("Device token", text: $settings.backendToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        HStack {
                            Circle().fill(engine.backendTint).frame(width: 8, height: 8)
                            Text(engine.backendStatus)
                                .font(.rvCaption).foregroundStyle(RV.Color.inkMuted)
                        }
                    }
                } header: { Text("ROVA backend") }
                  footer: { Text("The Mac at home polls İETT and this phone reads from it, so the map can refresh every few seconds instead of once a minute. Leave the fields empty to use the ones this build shipped with. If the backend is unreachable, ROVA goes straight to İETT by itself — nothing breaks.") }

                Section {
                    HStack {
                        ROVAMark(size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            ROVAWordmark(size: 15)
                            Text("MOVE WITH CERTAINTY").rvOverlineStyle()
                        }
                        Spacer()
                        Text("1.0").foregroundStyle(RV.Color.inkFaint)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(RV.Color.inkMuted).monospacedDigit() }
    }
    private func labelled(_ k: String, _ v: String, _ s: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).rvOverlineStyle()
            Text(v).font(.rvBody)
            Text(s).font(.rvCaption).foregroundStyle(RV.Color.inkMuted)
        }
    }
}
