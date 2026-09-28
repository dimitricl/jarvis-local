import SwiftUI
import JarvisKit

/// L3 — HUD : une pastille près du curseur, extensible pour le détail.
///
/// Style Liquid Glass sobre (`.glass`), jamais de fenêtre de chat imposée :
/// idle = invisible. Confirmations inline : Entrée = autoriser, Échap =
/// refuser, « Toujours » = règle persistée. Le coordinator AppKit (HUDPanel)
/// alimente cette vue et reçoit `onConfirm` / `onInterrupt` / `onSubmit`.
public struct HUDView: View {
    var state: HUDState
    var steps: [String]
    var input: Binding<String>
    var onConfirm: (Bool, Bool) -> Void
    var onInterrupt: () -> Void
    var onSubmit: (String) -> Void
    var onRetry: () -> Void

    public init(
        state: HUDState,
        steps: [String] = [],
        input: Binding<String>,
        onConfirm: @escaping (Bool, Bool) -> Void,
        onInterrupt: @escaping () -> Void,
        onSubmit: @escaping (String) -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.state = state
        self.steps = steps
        self.input = input
        self.onConfirm = onConfirm
        self.onInterrupt = onInterrupt
        self.onSubmit = onSubmit
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusDot
                Text(state.pill)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button(action: onInterrupt) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Interrompre (Échap ×2)")
            }
            if case .confirming(_, let reason, _) = state {
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Autoriser ⏎") { onConfirm(true, false) }
                            .buttonStyle(.glassProminent)
                        Button("Refuser") { onConfirm(false, false) }
                        Button("Toujours") { onConfirm(true, true) }
                            .help("Crée une règle allow dans permissions.json")
                    }
                    .font(.system(size: 12))
                    .buttonStyle(.glass)
                }
            }
            if case .unreachable(let host) = state {
                HStack {
                    Text(host).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    Button("Réessayer") { onRetry() }.buttonStyle(.glass)
                }
            }
            if !steps.isEmpty {
                Divider()
                ForEach(steps.suffix(6), id: \.self) { step in
                    Text(step)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            TextField("Demander à Jarvis… (Entrée = envoyer)", text: input, onCommit: {
                let text = input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                input.wrappedValue = ""
                onSubmit(text)
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
        }
        .padding(12)
        .frame(width: 340)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder
    private var statusDot: some View {
        let color: Color = switch state {
        case .idle: .clear
        case .listening: .red
        case .transcribing: .orange
        case .thinking, .loading: .blue
        case .acting: .purple
        case .confirming: .yellow
        case .speaking: .green
        case .done: .green
        case .unreachable: .red
        case .compacting: .blue
        }
        Circle().fill(color).frame(width: 8, height: 8)
    }
}
