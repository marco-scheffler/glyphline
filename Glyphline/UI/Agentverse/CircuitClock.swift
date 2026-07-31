import Foundation

/// The circuit's own clock.
///
/// Every instant the scene is lit at is a wall-clock time *at the circuit*, and
/// never at the viewer's desk: switching to Suzuka moves the time to Japan and
/// switching to Las Vegas moves it to Nevada. The sun follows the circuit.
///
/// The whole point of gathering this here is the one conversion that can be
/// wrong while looking right: the slider spans the circuit's local day, and
/// `SunPosition` wants a UTC instant. Done backwards, the scene is plausibly lit
/// and off by the zone's offset — nine hours at Suzuka, which reads as a
/// lighting bug rather than as a clock bug.
enum CircuitClock {
    /// The zone `Circuit.tz` names, or nil when this system does not know the
    /// identifier.
    static func timeZone(for circuit: Circuit) -> TimeZone? {
        TimeZone(identifier: circuit.tz)
    }

    /// The zone actually used, and whether the identifier was unrecognised.
    ///
    /// The fallback is UTC and deliberately *not* `TimeZone.current`: falling
    /// back to the viewer's zone would light Suzuka by a European clock, which
    /// looks entirely correct and is entirely wrong. UTC is visibly not the
    /// circuit's own time, and callers label it as such.
    static func resolvedTimeZone(for circuit: Circuit) -> (zone: TimeZone, isFallback: Bool) {
        guard let zone = timeZone(for: circuit) else { return (.gmt, true) }
        return (zone, false)
    }

    /// A gregorian calendar pinned to the circuit's zone. Every conversion in
    /// here goes through it, so none of them can quietly pick up the viewer's.
    static func calendar(for circuit: Circuit) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = resolvedTimeZone(for: circuit).zone
        return calendar
    }

    /// The slider's span.
    static let minutesPerDay = 1_440.0

    /// How far into its own day the circuit is at `date`, in minutes.
    static func minutesOfLocalDay(for circuit: Circuit, at date: Date) -> Double {
        let calendar = calendar(for: circuit)
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(parts.hour ?? 0) * 60
            + Double(parts.minute ?? 0)
            + Double(parts.second ?? 0) / 60
    }

    /// The UTC instant of `minutes` past local midnight, on whichever local day
    /// `reference` falls on at the circuit.
    ///
    /// Offsetting from local midnight rather than building `DateComponents` with
    /// an hour keeps the slider monotonic across a daylight-saving change: on the
    /// two odd days a year the displayed local time skips or repeats an hour,
    /// which is what the wall clock there does anyway, but the instant never
    /// jumps backwards as the slider is dragged forwards.
    static func instant(for circuit: Circuit, minutesOfLocalDay minutes: Double,
                        on reference: Date) -> Date {
        let midnight = calendar(for: circuit).startOfDay(for: reference)
        return midnight.addingTimeInterval(minutes.clamped(to: 0...minutesPerDay) * 60)
    }

    /// The circuit's local time as the toolbar shows it beside the slider — the
    /// user's read on which clock the scene is following, and the check that the
    /// conversion above ran the right way round.
    static func localTimeText(for circuit: Circuit, at date: Date) -> String {
        let resolved = resolvedTimeZone(for: circuit)
        let formatter = DateFormatter()
        formatter.timeZone = resolved.zone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = formatter.string(from: date)
        // Named, because a UTC clock over a circuit whose zone we failed to
        // resolve must not pass for that circuit's local time.
        return resolved.isFallback ? "\(time) UTC" : time
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
