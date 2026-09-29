import SwiftUI

/// L3 — HomeView : interface principale style HeyClicky
///
/// Remplace l'ancienne fenêtre de chat avec une interface moderne
/// basée sur des cartes, avec animations fluides et design minimaliste.
public struct HomeView: View {
    @ObservedObject var coordinator: ShellCoordinator
    @State private var isResizing = false
    @State private var dragOffset: CGSize = .zero
    
    public init(coordinator: ShellCoordinator) {
        self.coordinator = coordinator
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header avec titre et actions
            header
            
            // Zone de messages principale
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(coordinator.chatMessages) { message in
                            messageCard(message)
                        }
                        
                        if coordinator.chatBusy {
                            typingIndicator
                        }
                    }
                    .padding(20)
                }
                .onChange(of: coordinator.chatMessages.count) { _, _ in
                    if let last = coordinator.chatMessages.last {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            // Zone de confirmation d'outils
            if let confirm = coordinator.chatConfirm {
                confirmationCard(confirm)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            // Zone de saisie
            inputArea
        }
        .frame(minWidth: 400, minHeight: 500)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
    }
    
    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.blue)
                
                Text("Jarvis")
                    .font(.system(size: 18, weight: .semibold))
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                // Indicateur de connexion
                ConnectionIndicator(status: coordinator.connectionStatus)
                
                if let error = coordinator.errorMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .help(error)
                }
                
                Divider()
                    .frame(height: 20)
                
                HStack(spacing: 8) {
                    Button(action: { coordinator.newChat() }) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(coordinator.chatBusy)
                    .help("Nouvelle discussion")
                    
                    if coordinator.chatBusy {
                        Button(action: { coordinator.interrupt() }) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Interrompre")
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.clear)
    }
    
    @ViewBuilder
    private func messageCard(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.text)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.blue)
                        )
                }
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
            
        case .assistant:
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.text)
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(.white.opacity(0.1))
                        )
                        .textSelection(.enabled)
                }
                Spacer(minLength: 60)
            }
            .transition(.move(edge: .leading).combined(with: .opacity))
            
        case .note:
            HStack {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                
                Text(message.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .transition(.opacity)
        }
    }
    
    private var typingIndicator: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                        .scaleEffect(typingScale[index])
                        .animation(
                            .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                            value: typingScale[index]
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.05))
            )
            Spacer()
        }
        .padding(.horizontal, 20)
    }
    
    @State private var typingScale: [CGFloat] = [1.0, 1.0, 1.0]
    
    private func confirmationCard(_ confirm: ChatConfirm) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "hand.tap")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.orange)
                
                Text("Confirmation requise")
                    .font(.system(size: 14, weight: .medium))
                
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text(confirm.tool)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                
                Text(confirm.reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            
            HStack(spacing: 8) {
                Button("Autoriser") {
                    coordinator.answerConfirm(allowed: true, always: false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                
                Button("Refuser") {
                    coordinator.answerConfirm(allowed: false, always: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button("Toujours") {
                    coordinator.answerConfirm(allowed: true, always: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Crée une règle allow dans permissions.json")
                
                Spacer()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.08))
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
    
    private var inputArea: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Bouton micro
                Button(action: { /* TODO: Activer dictée vocale */ }) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16))
                        .foregroundColor(coordinator.chatBusy ? .secondary : Color.blue)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .disabled(coordinator.chatBusy)
                .help("Dictée vocale")
                
                TextField(
                    "Écris un message…",
                    text: $coordinator.chatInput,
                    onCommit: { coordinator.sendChat() }
                )
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.white.opacity(0.1))
                )
                .disabled(coordinator.chatBusy)
                
                Button(action: { coordinator.sendChat() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(sendDisabled ? .secondary : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(sendDisabled)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(.clear)
    }
    
    private var sendDisabled: Bool {
        coordinator.chatBusy
            || coordinator.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Indicateur de connexion avec animation
struct ConnectionIndicator: View {
    let status: ConnectionStatus
    @State private var isPulsing = false
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colorForStatus)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(colorForStatus, lineWidth: 2)
                        .scaleEffect(isPulsing ? 1.5 : 1.0)
                        .opacity(isPulsing ? 0 : 1)
                        .animation(
                            shouldPulse ? .easeOut(duration: 1.5).repeatForever(autoreverses: false) : .default,
                            value: isPulsing
                        )
                )
                .onAppear {
                    if shouldPulse {
                        isPulsing = true
                    }
                }
            
            Text(textForStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help(helpText)
    }
    
    private var colorForStatus: Color {
        switch status {
        case .online:
            return .green
        case .connecting:
            return .orange
        case .offline, .error:
            return .red
        case .unknown:
            return .gray
        }
    }
    
    private var textForStatus: String {
        switch status {
        case .online:
            return "En ligne"
        case .connecting:
            return "Connexion..."
        case .offline:
            return "Hors ligne"
        case .error:
            return "Erreur"
        case .unknown:
            return "Inconnu"
        }
    }
    
    private var shouldPulse: Bool {
        switch status {
        case .online, .connecting:
            return true
        default:
            return false
        }
    }
    
    private var helpText: String {
        switch status {
        case .online:
            return "Connecté au serveur Ollama"
        case .connecting:
            return "Connexion au serveur Ollama en cours"
        case .offline:
            return "Serveur Ollama inaccessible"
        case .error(let message):
            return "Erreur: \(message)"
        case .unknown:
            return "Statut de connexion inconnu"
        }
    }
}