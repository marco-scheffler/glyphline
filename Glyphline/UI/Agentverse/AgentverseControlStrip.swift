import SwiftUI

/// The window's controls, as a full-width strip under the title bar.
///
/// Not a toolbar. In the toolbar the five circuit tabs, the five weather tabs
/// and the time controls shared one row with the window title, and at the
/// window's 900 pt minimum they drew on top of one another — the user's
/// screenshot read "MonzaAutoSpa CleaSuzukCloud". A strip of its own has the
/// whole window width and nothing competing for it, which is how the approved
/// mockup (`tools/agentverse/template2.html`, `.zx-ctl`) arranges them: labelled
/// groups on a dark panel with a hairline border, so the controls sit with the
/// map rather than fight it.
struct AgentverseControlStrip: View {
    /// The catalog's picker entries, in the catalog's own order.
    let circuits: [(key: String, name: String, short: String)]
    @Binding var circuitKey: String
    @Binding var weatherChoice: WeatherChoice
    /// Minutes past local midnight at the circuit, or nil while the scene is
    /// simply following the clock there.
    @Binding var localMinutesOverride: Double?
    /// What the clock at the circuit says right now, for when nothing overrides
    /// it. Passed in rather than computed here so the strip stays a pure
    /// function of its inputs.
    let localMinutesNow: Double
    let clockText: String
    /// Nil when no circuit is selected — then there is no local time to show.
    let hasCircuit: Bool

    /// One row where there is room for one, two where there is not.
    ///
    /// Measured: the three groups side by side want 998 points and the window's
    /// minimum is 900, so at the minimum they cannot share a row — the mockup
    /// wraps for the same reason (`.zx-ctl` is `flex-wrap: wrap`). The first
    /// candidate is therefore rigid down to the slider's width, so that
    /// `ViewThatFits` can tell it does not fit; the wrapped candidate lets the
    /// slider stretch, since it is the strip's only elastic element.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                pickerGroups
                if hasCircuit { timeGroup(sliderWidth: .fixed(160)) }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 14) { pickerGroups }
                if hasCircuit { timeGroup(sliderWidth: .elastic) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(Color(red: 0.039, green: 0.055, blue: 0.078))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.09))
                .frame(height: 1)
        }
    }

    /// How much room the time slider gets: rigid in the one-row layout so that
    /// the layout can be rejected when it does not fit, stretchy once wrapped.
    private enum SliderWidth {
        case fixed(CGFloat)
        case elastic
    }

    @ViewBuilder private var pickerGroups: some View {
        Group {
            group("Circuit") {
                // Tabs, not a menu: the ask was tabs, twice. The short names are
                // what fits — the formal ones run to "Circuit de
                // Spa-Francorchamps".
                Picker("Circuit", selection: $circuitKey) {
                    ForEach(circuits, id: \.key) { entry in
                        Text(entry.short).tag(entry.key).help(entry.name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            group("Weather") {
                Picker("Weather", selection: $weatherChoice) {
                    ForEach(WeatherChoice.allCases, id: \.self) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .help("What the sky over the circuit is doing. Auto follows the "
                      + "weather on location.")
            }
        }
    }

    /// The slider, the circuit's local time beside it, and the way back to now.
    ///
    /// The time is shown because the conversion behind it — slider position to
    /// local wall clock at the circuit to UTC — is exactly the kind that produces
    /// a plausibly lit scene when it runs the wrong way round. On screen it is
    /// obvious that switching to Suzuka moved the clock to Japan.
    private func timeGroup(sliderWidth: SliderWidth) -> some View {
        let minutes = Binding(
            get: { localMinutesOverride ?? localMinutesNow },
            set: { localMinutesOverride = $0 }
        )
        return HStack(spacing: 9) {
            caption("Local time")
            // The one elastic element in the strip: everything else is text at
            // its intrinsic width, so when there is room to spare this is what
            // takes it. Below 120 points a day stops being draggable, hence the
            // floor on the wrapped layout.
            slider(minutes, width: sliderWidth)
            Text(clockText)
                .font(.callout.monospacedDigit())
                // Wide enough for the longest form the locale can produce, so
                // the neighbouring button does not shuffle as the clock runs.
                .frame(minWidth: 62, alignment: .leading)
            Button("Now") { localMinutesOverride = nil }
                .disabled(localMinutesOverride == nil)
        }
    }

    @ViewBuilder private func slider(
        _ minutes: Binding<Double>, width: SliderWidth
    ) -> some View {
        let control = Slider(value: minutes, in: 0...CircuitClock.minutesPerDay)
            .help("The time of day at the circuit")
        switch width {
        case .fixed(let points):
            control.frame(width: points)
        case .elastic:
            control.frame(minWidth: 120)
        }
    }

    @ViewBuilder private func group<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 7) {
            caption(title)
            content()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .kerning(1.4)
            .textCase(.uppercase)
            .foregroundStyle(.white.opacity(0.42))
            .fixedSize()
    }
}
