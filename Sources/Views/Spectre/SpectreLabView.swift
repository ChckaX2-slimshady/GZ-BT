import SwiftUI

/// The Spectre research lab — Model Information, Token DNA / SIGS, the
/// experimental module registry, and the canonical research questions.
///
/// This is an **instrument**, not a feature showcase. Two rules shape every row:
/// status describes implementation and never benefit, and a mechanism that is not
/// built renders as a disabled control with its reason rather than a switch that
/// silently does nothing.
struct SpectreLabView: View {
    @Environment(\.theme) private var theme
    let vm: SpectreLabViewModel

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Space.md)]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            modelPanel
            dnaPanel
            questionsPanel
            modulePanel
            disclaimerPanel
        }
        .task { await vm.load() }
    }

    // MARK: - Model information

    private var modelPanel: some View {
        panel("MODEL INFORMATION") {
            LazyVGrid(columns: columns, spacing: Space.md) {
                ForEach(vm.modelRows) { row in
                    readout(row)
                }
            }
        }
    }

    // MARK: - Token DNA

    @ViewBuilder
    private var dnaPanel: some View {
        panel("TOKEN DNA · SIGS") {
            if vm.isPresent {
                VStack(alignment: .leading, spacing: Space.md) {
                    LazyVGrid(columns: columns, spacing: Space.md) {
                        ForEach(vm.dnaRows) { readout($0) }
                    }
                    fieldList("FIELDS EMITTED", vm.emittedFields, tint: theme.accentPrimary)
                    if !vm.nullFields.isEmpty {
                        fieldList("ABSENT, WITH REASON", vm.nullFields, tint: theme.textTertiary)
                        Text("Three states, never a sentinel: present · null-with-reason · "
                             + "not-requested. A reader that treated null as 0.0 is the "
                             + "failure this forecloses.")
                            .font(ChameleonType.caption)
                            .foregroundStyle(theme.textTertiary)
                    }
                    distributions
                }
            } else {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("No compiled artifact")
                        .font(ChameleonType.headline)
                        .foregroundStyle(theme.textSecondary)
                    Text(vm.absenceReason ?? "—")
                        .font(ChameleonType.caption)
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var distributions: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !vm.flagDistribution.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    sectionLabel("CLASS FLAGS")
                    ForEach(vm.flagDistribution) { barRow($0) }
                }
            }
            if !vm.specialKindDistribution.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    sectionLabel("SPECIAL KINDS")
                    ForEach(vm.specialKindDistribution) { barRow($0) }
                }
            }
        }
    }

    private func barRow(_ bucket: SpectreDNA.Bucket) -> some View {
        let total = vm.tokensClassified
        let fraction = total > 0 ? Double(bucket.count) / Double(total) : 0
        return HStack(spacing: Space.sm) {
            Text(bucket.label)
                .font(ChameleonType.monoSmall)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 130, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceInset)
                    Capsule()
                        .fill(theme.accentPrimary.opacity(0.75))
                        .frame(width: max(1, geometry.size.width * fraction))
                }
            }
            .frame(height: 5)
            Text(bucket.count.formatted(.number))
                .font(ChameleonType.monoSmall)
                .foregroundStyle(theme.textTertiary)
                .frame(width: 62, alignment: .trailing)
        }
    }

    // MARK: - Research questions

    private var questionsPanel: some View {
        panel("RESEARCH QUESTIONS") {
            VStack(alignment: .leading, spacing: Space.md) {
                Text("The four priorities the design contract says must be answered "
                     + "before any mechanism becomes canonical.")
                    .font(ChameleonType.caption)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(vm.questionStates) { entry in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.sm) {
                            Text(entry.question.title)
                                .font(ChameleonType.caption)
                                .foregroundStyle(theme.textPrimary)
                            Spacer(minLength: Space.sm)
                            Text(entry.anyBuilt ? "instrument built" : "NO BUILT INSTRUMENT")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(entry.anyBuilt ? theme.accentPrimary : theme.warning)
                        }
                        Text(entry.question.question)
                            .font(ChameleonType.monoSmall)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("gate: \(entry.question.gate)  ·  via "
                             + entry.instruments.map(\.id).sorted().joined(separator: ", "))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, Space.xs)
                }
            }
        }
    }

    // MARK: - Modules

    private var modulePanel: some View {
        panel("EXPERIMENTAL MODULES") {
            VStack(alignment: .leading, spacing: Space.md) {
                ForEach(SpectreLabRegistry.byCategory) { group in
                    VStack(alignment: .leading, spacing: Space.sm) {
                        sectionLabel(group.category.label)
                        ForEach(group.modules) { module in
                            moduleRow(module)
                        }
                    }
                }

                if !vm.resolution.notes.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        sectionLabel("RESOLUTION")
                        ForEach(vm.resolution.notes, id: \.self) { note in
                            Text(note)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func moduleRow(_ module: SpectreLabModule) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                Text(module.name)
                    .font(ChameleonType.caption)
                    .foregroundStyle(vm.isOperable(module) ? theme.textPrimary : theme.textTertiary)
                statusBadge(module.status)
                efficacyBadge(module.efficacy)
                Spacer(minLength: Space.sm)
                Toggle("", isOn: Binding(
                    get: { vm.isRequested(module.id) },
                    set: { vm.setRequested(module.id, $0) }))
                    .labelsHidden()
                    .disabled(!vm.isOperable(module))
            }

            Text(module.summary)
                .font(.system(size: 10))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // An unbuilt mechanism states why, rather than offering a live switch.
            if !module.isAvailable {
                Text(module.implementation)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.warning.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if vm.isRequested(module.id) && !vm.isEffective(module.id) && vm.isOperable(module) {
                Text("requested but not effective — see resolution below")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(theme.warning)
            }
        }
        .padding(.vertical, Space.xs)
    }

    private func statusBadge(_ status: SpectreLabModule.Status) -> some View {
        let tint: Color = switch status {
        case .built: theme.accentPrimary
        case .partial: theme.accentSecondary
        case .hook, .unavailable: theme.textTertiary
        }
        return Text(status.label.uppercased())
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .stroke(tint.opacity(0.5), lineWidth: 0.8))
    }

    private func efficacyBadge(_ efficacy: SpectreLabModule.Efficacy) -> some View {
        Text(efficacy.label)
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.textTertiary)
    }

    // MARK: - Disclaimers

    private var disclaimerPanel: some View {
        panel("STANDING CAVEATS") {
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(vm.disclaimers, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        Text("!")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.warning)
                        Text(line)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Building blocks

    private func panel<Content: View>(_ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            sectionLabel(title)
            content()
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .membraneSurface(cornerRadius: Radius.md, elevation: .low)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(theme.textTertiary)
    }

    private func readout(_ row: SpectreLabViewModel.Row) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(row.label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
            Text(row.value)
                .font(ChameleonType.mono)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            if let caveat = row.caveat {
                Text(caveat)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(theme.warning.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.md)
        .membraneSurface(cornerRadius: Radius.sm, elevation: .low)
    }

    private func fieldList(_ title: String,
                           _ rows: [SpectreLabViewModel.Row],
                           tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            sectionLabel(title)
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                    Text(row.label)
                        .font(ChameleonType.monoSmall)
                        .foregroundStyle(tint)
                        .frame(width: 130, alignment: .leading)
                    Text(row.value)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
