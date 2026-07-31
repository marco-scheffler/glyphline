import Foundation

/// Where the sun stands over a point on the globe at an instant, by the standard
/// NOAA solar position algorithm.
///
/// Everything the scene looks like hangs off these two numbers: the direction and
/// length of every shadow, the colour of the sun and the sky, and the exposure
/// that separates day from night. The algorithm is accurate to well under a
/// tenth of a degree for the years this app will ever be asked about, which is
/// far finer than anything a rendered sky can show.
enum SunPosition {
    /// Elevation above the horizon and azimuth clockwise from north, both in
    /// degrees. Elevation is *apparent* — corrected for atmospheric refraction —
    /// because the interesting colours all live within a few degrees of the
    /// horizon, which is exactly where an uncorrected elevation is worst.
    static func at(latitude: Double, longitude: Double, date: Date) -> (elevation: Double, azimuth: Double) {
        let julianDay = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        // Julian centuries since J2000.0, the time argument of every series below.
        let t = (julianDay - 2_451_545.0) / 36_525.0

        let geomMeanLongitude = (280.46646 + t * (36_000.76983 + t * 0.0003032))
            .truncatingRemainder(dividingBy: 360)
        let geomMeanAnomaly = 357.52911 + t * (35_999.05029 - 0.0001537 * t)
        let eccentricity = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)

        let m = radians(geomMeanAnomaly)
        let equationOfCentre =
            sin(m) * (1.914602 - t * (0.004817 + 0.000014 * t))
            + sin(2 * m) * (0.019993 - 0.000101 * t)
            + sin(3 * m) * 0.000289

        let trueLongitude = geomMeanLongitude + equationOfCentre
        // The lunar node term: the small nutation wobble that turns the true
        // longitude into the apparent one an observer actually sees.
        let omega = 125.04 - 1_934.136 * t
        let apparentLongitude = trueLongitude - 0.00569 - 0.00478 * sin(radians(omega))

        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let obliquity = meanObliquity + 0.00256 * cos(radians(omega))

        let declination = asin(sin(radians(obliquity)) * sin(radians(apparentLongitude)))

        let y = pow(tan(radians(obliquity) / 2), 2)
        let l0 = radians(geomMeanLongitude)
        // Equation of time in minutes: how far true solar time runs ahead of mean.
        let equationOfTime = 4 * degrees(
            y * sin(2 * l0)
            - 2 * eccentricity * sin(m)
            + 4 * eccentricity * y * sin(m) * cos(2 * l0)
            - 0.5 * y * y * sin(4 * l0)
            - 1.25 * eccentricity * eccentricity * sin(2 * m)
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minutesOfDay =
            Double(parts.hour ?? 0) * 60
            + Double(parts.minute ?? 0)
            + Double(parts.second ?? 0) / 60

        // Four minutes of solar time per degree of longitude.
        let trueSolarTime = (minutesOfDay + equationOfTime + 4 * longitude)
            .truncatingRemainder(dividingBy: 1_440)
        var hourAngle = trueSolarTime / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }

        let latitudeRadians = radians(latitude)
        let hourAngleRadians = radians(hourAngle)
        let cosZenith = min(1, max(-1,
            sin(latitudeRadians) * sin(declination)
            + cos(latitudeRadians) * cos(declination) * cos(hourAngleRadians)
        ))
        let zenith = acos(cosZenith)
        let trueElevation = 90 - degrees(zenith)

        let azimuth = azimuthDegrees(
            latitudeRadians: latitudeRadians,
            declination: declination,
            zenith: zenith,
            hourAngle: hourAngle
        )

        let elevation = min(90, max(-90, trueElevation + refraction(trueElevation: trueElevation)))
        return (elevation, azimuth)
    }

    private static func azimuthDegrees(
        latitudeRadians: Double,
        declination: Double,
        zenith: Double,
        hourAngle: Double
    ) -> Double {
        let denominator = cos(latitudeRadians) * sin(zenith)
        // At the poles, and with the sun exactly overhead, azimuth is undefined.
        // North is as good an answer as any and keeps the value in range.
        guard abs(denominator) > 1e-12 else { return hourAngle > 0 ? 180 : 0 }
        let cosAzimuth = min(1, max(-1,
            (sin(latitudeRadians) * cos(zenith) - sin(declination)) / denominator
        ))
        let angle = degrees(acos(cosAzimuth))
        let azimuth = hourAngle > 0 ? angle + 180 : 540 - angle
        return azimuth.truncatingRemainder(dividingBy: 360)
    }

    /// NOAA's piecewise refraction model, in arcseconds before scaling. The
    /// atmosphere lifts the sun by about half a degree at the horizon and by
    /// almost nothing overhead, so the correction only matters near zero — which
    /// is where the dawn and dusk colours are decided.
    private static func refraction(trueElevation: Double) -> Double {
        if trueElevation > 85 { return 0 }
        let tangent = tan(radians(trueElevation))
        let arcseconds: Double
        if trueElevation > 5 {
            arcseconds = 58.1 / tangent - 0.07 / pow(tangent, 3) + 0.000086 / pow(tangent, 5)
        } else if trueElevation > -0.575 {
            arcseconds = 1_735
                + trueElevation * (-518.2 + trueElevation
                * (103.4 + trueElevation * (-12.79 + trueElevation * 0.711)))
        } else {
            arcseconds = -20.772 / tangent
        }
        return arcseconds / 3_600
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    private static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
}
