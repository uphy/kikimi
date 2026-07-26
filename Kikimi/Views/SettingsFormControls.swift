import SwiftUI

extension Comparable {
    /// Bounds `self` into `range`. Used by the numeric settings fields below to keep typed-in
    /// values inside the same range their steppers enforce.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// One numeric row in a settings `Form`: label on the left, a right-aligned editable value with an
/// optional unit and a stepper on the right (`docs/design/30-settings-ui-polish.md` §3). Replaces
/// the bare `Stepper("label: \(value)")` rows, whose value lived inside the label (not directly
/// editable, and the label column shifted width every time the value changed).
struct SettingsIntField: View {
    let label: String
    var unit: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField("", value: clampedValue, format: .number.grouping(.never))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                if let unit {
                    Text(unit).foregroundStyle(.secondary)
                }
                Stepper("", value: clampedValue, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private var clampedValue: Binding<Int> {
        Binding(get: { value }, set: { value = $0.clamped(to: range) })
    }
}

/// `Double` counterpart of `SettingsIntField` (covers `TimeInterval` fields too).
/// `fractionDigits` fixes the displayed precision so 0.45 never renders as 0.45000000000000001.
struct SettingsDoubleField: View {
    let label: String
    var unit: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double
    var fractionDigits: Int = 1

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                TextField(
                    "", value: clampedValue,
                    format: .number.precision(.fractionLength(0...fractionDigits))
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                if let unit {
                    Text(unit).foregroundStyle(.secondary)
                }
                Stepper("", value: clampedValue, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private var clampedValue: Binding<Double> {
        Binding(get: { value }, set: { value = $0.clamped(to: range) })
    }
}
