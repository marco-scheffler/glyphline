import Foundation

/// Where on the globe to put the sun the office windows look out on.
///
/// `TimeZone.current.identifier` is a city name — `Europe/Berlin`,
/// `America/Sao_Paulo` — so a table of IANA zone to representative coordinates
/// buys a real sun angle with no location permission dialog, no network call and
/// no dependence on being online. The alternative, CoreLocation, asks the user to
/// hand over their position for the sake of ambient lighting; that is far too
/// much to charge for a window.
enum UserPlace {
    /// A point on the globe, together with how confident we are that it is the
    /// user's.
    struct Coordinates: Equatable, Sendable {
        /// Degrees north of the equator, negative south of it.
        let latitude: Double
        /// Degrees east of Greenwich, negative west of it.
        let longitude: Double
        let source: Source

        init(latitude: Double, longitude: Double, source: Source) {
            self.latitude = latitude
            self.longitude = longitude
            self.source = source
        }
    }

    /// Where a set of coordinates came from — carried alongside them because the
    /// fallback is a guess and the UI has to be able to say so rather than
    /// present a guess as a fact.
    enum Source: String, Equatable, Sendable {
        /// The zone was in the table, so both numbers name a real city.
        case table
        /// The zone was not in the table. The longitude is derived from the
        /// GMT offset and is good to a degree or so; the latitude is a
        /// placeholder, because an offset says nothing at all about how far
        /// north or south a place is — not even which hemisphere.
        case offsetFallback
        /// The user typed the coordinates in themselves.
        case manual
    }

    /// Used when only the offset is known.
    ///
    /// Roughly the latitude of Madrid, New York and Beijing: the band where most
    /// of the world's population actually lives, and far enough from the poles
    /// that the day length stays plausible all year instead of collapsing into
    /// midnight sun. It is a guess, and `.offsetFallback` exists so it is never
    /// mistaken for anything else.
    static let fallbackLatitude: Double = 40

    /// Degrees of longitude per second of GMT offset: 360° over 86400 s.
    private static let secondsPerDegreeOfLongitude: Double = 240

    static func current(
        timeZone: TimeZone = .current,
        override: Coordinates? = nil
    ) -> Coordinates {
        if let override {
            // The source the caller stored is irrelevant — reaching us as an
            // override is what makes it manual.
            return Coordinates(latitude: override.latitude, longitude: override.longitude, source: .manual)
        }

        if let place = bundledTable?.places[timeZone.identifier] {
            return Coordinates(latitude: place.latitude, longitude: place.longitude, source: .table)
        }

        return Coordinates(
            latitude: fallbackLatitude,
            longitude: Double(timeZone.secondsFromGMT()) / secondsPerDegreeOfLongitude,
            source: .offsetFallback
        )
    }

    /// Loaded once. The table is a few hundred pairs of doubles and never
    /// changes while the app runs, so re-reading it per frame would be pure
    /// waste; a failure to load leaves every zone on the offset fallback rather
    /// than taking the app down over a light source.
    private static let bundledTable: TimeZonePlaceTable? = try? .bundled()

    struct TimeZonePlaceTable: Sendable {
        struct Place: Equatable, Sendable {
            let latitude: Double
            let longitude: Double
        }

        let places: [String: Place]

        static func bundled(in bundle: Bundle = .main) throws -> TimeZonePlaceTable {
            let resourceURL = bundle.url(
                forResource: "timezone-places",
                withExtension: "json",
                subdirectory: "Resources"
            ) ?? bundle.url(forResource: "timezone-places", withExtension: "json")

            guard let resourceURL else {
                throw UserPlaceError.missingResource(name: "timezone-places", extension: "json")
            }

            let data = try Data(contentsOf: resourceURL)
            let raw = try JSONDecoder().decode([String: [Double]].self, from: data)

            var places: [String: Place] = [:]
            places.reserveCapacity(raw.count)
            for (identifier, pair) in raw {
                guard pair.count == 2 else {
                    throw UserPlaceError.malformedEntry(identifier: identifier)
                }
                places[identifier] = Place(latitude: pair[0], longitude: pair[1])
            }
            return TimeZonePlaceTable(places: places)
        }
    }
}

enum UserPlaceError: Error, Equatable {
    case missingResource(name: String, extension: String)
    case malformedEntry(identifier: String)
}
