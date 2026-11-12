import SwiftUI
import MapKit

struct SearchView: View {
    let title: String
    var onPick: (Place) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var location: LocationService
    @StateObject private var model = SearchModel()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                if model.query.isEmpty {
                    Section {
                        quick("Use my current location", "location.fill") {
                            guard let l = location.current else { return }
                            Task {
                                let n = await Reverse.describe(l.coordinate)
                                onPick(Place(name: n.0, subtitle: n.1,
                                             lat: l.coordinate.latitude, lon: l.coordinate.longitude))
                            }
                        }
                        quick(DefaultJourney.origin.name, "house.fill") { onPick(DefaultJourney.origin) }
                        quick(DefaultJourney.destination.name, "flag.checkered") { onPick(DefaultJourney.destination) }
                    }
                    Section("Nearby stops") {
                        ForEach(model.nearbyStops, id: \.0.code) { stop, d in
                            Button {
                                onPick(Place(name: stop.name, subtitle: "\(stop.district) · İETT stop",
                                             lat: stop.lat, lon: stop.lon))
                            } label: {
                                row(stop.name, "\(stop.district) · \(Fmt.distance(d))", "signpost.right.fill")
                            }
                        }
                    }
                } else {
                    ForEach(model.results) { r in
                        Button { onPick(r.place) } label: {
                            row(r.title, r.subtitle, "mappin.and.ellipse")
                        }
                    }
                    if model.results.isEmpty && !model.searching {
                        Text("No places found").foregroundStyle(RV.Color.inkMuted)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search a place or address")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { model.loadNearby(location.current?.coordinate) }
        }
    }

    private func quick(_ t: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { row(t, "", icon) }
    }

    private func row(_ t: String, _ s: String, _ icon: String) -> some View {
        HStack(spacing: RV.Space.m) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(RV.Color.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(t).font(.rvBody).foregroundStyle(RV.Color.ink).lineLimit(1)
                if !s.isEmpty {
                    Text(s).font(.rvCaption).foregroundStyle(RV.Color.inkMuted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

@MainActor
final class SearchModel: ObservableObject {
    struct Result: Identifiable, Hashable {
        let id = UUID()
        let title: String
        let subtitle: String
        let place: Place
    }

    @Published var query = "" { didSet { schedule() } }
    @Published private(set) var results: [Result] = []
    @Published private(set) var nearbyStops: [(Stop, Double)] = []
    @Published private(set) var searching = false

    private var task: Task<Void, Never>?
    private let region = MKCoordinateRegion(
        center: .init(latitude: 41.03, longitude: 28.80),
        span: .init(latitudeDelta: 1.1, longitudeDelta: 1.6))

    func loadNearby(_ c: CLLocationCoordinate2D?) {
        let centre = c ?? Settings.shared.home.coordinate
        nearbyStops = TransitStore.shared.stopsNear(centre, radius: 900, limit: 12)
    }

    private func schedule() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; searching = false; return }
        searching = true
        task = Task { [region] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled else { return }

            // Local İETT stops first — they are what the planner can actually use.
            let folded = q.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr"))
            var out: [Result] = TransitStore.shared.stops.values
                .filter { $0.name.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                          locale: Locale(identifier: "tr")).contains(folded) }
                .sorted { $0.name.count < $1.name.count }
                .prefix(5)
                .map { Result(title: $0.name, subtitle: "\($0.district) · İETT stop",
                              place: Place(name: $0.name, subtitle: "\($0.district) · İETT stop",
                                           lat: $0.lat, lon: $0.lon)) }

            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            req.region = region
            if let resp = try? await MKLocalSearch(request: req).start() {
                for item in resp.mapItems.prefix(10) {
                    let c = item.placemark.coordinate
                    let sub = item.placemark.title ?? ""
                    out.append(Result(title: item.name ?? q, subtitle: sub,
                                      place: Place(name: item.name ?? q, subtitle: sub,
                                                   lat: c.latitude, lon: c.longitude)))
                }
            }
            guard !Task.isCancelled else { return }
            self.results = out
            self.searching = false
        }
    }
}
