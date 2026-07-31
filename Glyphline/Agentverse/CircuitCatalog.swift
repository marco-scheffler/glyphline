import Foundation

/// One circuit as the renderer needs it: geometry in metres, already laid flat by
/// its own long axis, with the surroundings and terrain that belong to it.
struct Circuit: Decodable, Equatable, Sendable {
    var name: String
    var location: String?
    /// IANA identifier. The clock and the sun both follow the circuit, not the
    /// viewer — switching to Suzuka moves the time to Japan.
    var tz: String
    var lengthKm: Double
    var lat: Double
    var lon: Double
    /// How far the map was spun to lay the long axis flat. The renderer needs it
    /// to put the sun back where it belongs.
    var rot: Double
    var minX: Double
    var minY: Double
    var spanX: Double
    var spanY: Double
    /// Index into `points` where the start/finish line sits.
    var startIdx: Int
    /// Centreline, `[x, y]` in metres, running in the direction the circuit is
    /// actually driven.
    var points: [[Double]]
    /// Pit lane, same frame, same direction.
    var pit: [[Double]]

    // Filled in from the three neighbouring files, not read from circuits.json —
    // which is why they are absent from the CodingKeys. A default value alone is
    // not enough: the synthesised init(from:) demands every key it lists.
    var corners: [CircuitCorner] = []
    var scenery: CircuitScenery = CircuitScenery()
    var terrain: CircuitTerrain = CircuitTerrain()

    private enum CodingKeys: String, CodingKey {
        case name, location, tz, lengthKm, lat, lon, rot
        case minX, minY, spanX, spanY, startIdx, points, pit
    }
}

struct CircuitCorner: Decodable, Equatable, Sendable {
    var name: String
    /// Index into the circuit's `points`.
    var idx: Int
}

struct CircuitScenery: Decodable, Equatable, Sendable {
    var buildings: [CircuitBuilding] = []
    var areas: [CircuitArea] = []
}

struct CircuitBuilding: Decodable, Equatable, Sendable {
    /// Footprint ring, `[x, y]` in metres.
    var p: [[Double]]
    /// Height in metres. Real where OpenStreetMap carries one, 9 m otherwise.
    var h: Double
    var a: Double
}

struct CircuitArea: Decodable, Equatable, Sendable {
    var p: [[Double]]
    /// `water`, `wood` or `green`.
    var k: String
    var a: Double
}

/// Elevation over the circuit's bounding box, row-major, `gw` by `gh`.
struct CircuitTerrain: Decodable, Equatable, Sendable {
    var minX: Double = 0
    var minY: Double = 0
    var maxX: Double = 0
    var maxY: Double = 0
    var gw: Int = 0
    var gh: Int = 0
    /// Lowest and highest metres in `grid`.
    var lo: Double = 0
    var hi: Double = 0
    var grid: [Int] = []
    /// Elevation along the centreline, one entry per point.
    var profile: [Double] = []
    /// One flag per grid cell, or `nil` for an inland circuit — where the data
    /// carries the key explicitly set to null. Null rather than all-zero, so
    /// "no coast" cannot be read as "not computed".
    var sea: [Int]?
}

/// The five circuits, decoded once from the bundle.
///
/// Mirrors `PricingCatalog`: the same lookup with a subdirectory fallback, and the
/// same insistence that a missing resource is a build mistake. An empty catalog
/// would surface as a blank scene, which looks like a rendering bug and gets
/// debugged in the wrong file.
struct CircuitCatalog: Equatable, Sendable {
    private let circuits: [String: Circuit]

    init(circuits: [String: Circuit]) {
        self.circuits = circuits
    }

    var keys: [String] { Array(circuits.keys) }

    func circuit(_ key: String) -> Circuit? { circuits[key] }

    /// Every circuit as the key it is looked up by and the name it is offered
    /// under, ordered by that name. Dictionary iteration order is unspecified
    /// and differs between launches, so an unsorted list would rearrange the
    /// picker on every opening.
    var entriesByName: [(key: String, name: String)] {
        circuits.map { (key: $0.key, name: $0.value.name) }
            .sorted { $0.name < $1.name }
    }

    static func bundled(in bundle: Bundle = .main) throws -> CircuitCatalog {
        var circuits = try decode([String: Circuit].self, named: "circuits", in: bundle)
        let corners = try decode([String: [CircuitCorner]].self, named: "corners", in: bundle)
        let scenery = try decode([String: CircuitScenery].self, named: "scenery", in: bundle)
        let terrain = try decode([String: CircuitTerrain].self, named: "terrain", in: bundle)

        for key in circuits.keys {
            circuits[key]?.corners = corners[key] ?? []
            circuits[key]?.scenery = scenery[key] ?? CircuitScenery()
            circuits[key]?.terrain = terrain[key] ?? CircuitTerrain()
        }

        return CircuitCatalog(circuits: circuits)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type, named name: String, in bundle: Bundle
    ) throws -> T {
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Resources/agentverse")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "agentverse")
            ?? bundle.url(forResource: name, withExtension: "json")

        guard let url else {
            throw CircuitCatalogError.missingResource(name: name, extension: "json")
        }

        return try JSONDecoder().decode(T.self, from: try Data(contentsOf: url))
    }
}

enum CircuitCatalogError: Error, Equatable {
    case missingResource(name: String, extension: String)
}

/// Who the bundled circuit data belongs to.
///
/// Kept beside the catalog rather than inside the view: the obligation follows
/// the data, and a credit that lives only in a layout disappears the next time
/// someone rearranges the layout.
enum CircuitAttribution {
    static let lines = [
        "Circuit geometry © Tomislav Bacinger (MIT)",
        "Surroundings, pit lanes and corner names © OpenStreetMap contributors (ODbL)",
        "Elevation from Mapzen/AWS terrain tiles",
    ]
}
