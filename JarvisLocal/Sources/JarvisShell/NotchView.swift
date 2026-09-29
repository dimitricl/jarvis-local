import SwiftUI

/// L3 — NotchView : icône de menu bar moderne style HeyClicky
///
/// Affiche un badge de notification et réagit au survol pour ouvrir
/// l'interface principale. Style minimaliste avec animations fluides.
public struct NotchView: View {
    @Binding var isExpanded: Bool
    @Binding var unreadCount: Int
    var onTap: () -> Void
    
    public init(
        isExpanded: Binding<Bool>,
        unreadCount: Binding<Int>,
        onTap: @escaping () -> Void
    ) {
        self._isExpanded = isExpanded
        self._unreadCount = unreadCount
        self.onTap = onTap
    }
    
    public var body: some View {
        HStack(spacing: 4) {
            ZStack {
                // Icône principale
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.primary)
                
                // Badge de notification
                if unreadCount > 0 {
                    VStack {
                        HStack {
                            Spacer()
                            Text("\(min(unreadCount, 99))")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule()
                                        .fill(Color.blue)
                                )
                        }
                        Spacer()
                    }
                    .frame(width: 20, height: 20)
                }
            }
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
        )
        .onTapGesture {
            onTap()
        }
        .scaleEffect(isExpanded ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isExpanded)
    }
}