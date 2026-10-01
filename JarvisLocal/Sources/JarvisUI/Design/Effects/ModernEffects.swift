//
//  ModernEffects.swift
//  JarvisLocal
//
//  Effets visuels modernes : glow, pulse, shimmer
//

import SwiftUI

// MARK: - Glow Effect

struct GlowEffect: ViewModifier {
    let color: Color
    let radius: CGFloat
    @State private var isGlowing = false
    
    init(color: Color, radius: CGFloat = 20) {
        self.color = color
        self.radius = radius
    }
    
    func body(content: Content) -> some View {
        content
            .shadow(
                color: color.opacity(isGlowing ? 0.6 : 0.3),
                radius: isGlowing ? radius * 1.2 : radius,
                x: 0,
                y: 0
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    isGlowing = true
                }
            }
    }
}

extension View {
    func glow(color: Color = JarvisPalette.primary, radius: CGFloat = 20) -> some View {
        self.modifier(GlowEffect(color: color, radius: radius))
    }
}

// MARK: - Pulse Effect

struct PulseEffect: ViewModifier {
    let scale: CGFloat
    @State private var isPulsing = false
    
    init(scale: CGFloat = 1.05) {
        self.scale = scale
    }
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPulsing ? scale : 1.0)
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear {
                isPulsing = true
            }
    }
}

extension View {
    func pulse(scale: CGFloat = 1.05) -> some View {
        self.modifier(PulseEffect(scale: scale))
    }
}

// MARK: - Shimmer Effect

struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.white.opacity(0.3),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geometry.size.width)
                    .offset(x: phase - geometry.size.width)
                    .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: phase)
                    .onAppear {
                        phase = geometry.size.width * 2
                    }
                }
                .mask(content)
            )
    }
}

extension View {
    func shimmer() -> some View {
        self.modifier(ShimmerEffect())
    }
}

// MARK: - Bounce Effect

struct BounceEffect: ViewModifier {
    @State private var isBouncing = false
    
    func body(content: Content) -> some View {
        content
            .scaleEffect(isBouncing ? 1.1 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: isBouncing)
            .onAppear {
                withAnimation {
                    isBouncing = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    isBouncing = false
                }
            }
    }
}

extension View {
    func bounce() -> some View {
        self.modifier(BounceEffect())
    }
}

// MARK: - Slide In Effect

struct SlideInEffect: ViewModifier {
    let edge: Edge
    @State private var offset: CGFloat
    
    init(edge: Edge = .bottom) {
        self.edge = edge
        switch edge {
        case .top, .bottom:
            offset = 50
        case .leading, .trailing:
            offset = 100
        }
    }
    
    func body(content: Content) -> some View {
        content
            .offset(
                x: edge == .leading ? offset : edge == .trailing ? -offset : 0,
                y: edge == .top ? offset : edge == .bottom ? -offset : 0
            )
            .opacity(offset != 0 ? 0 : 1)
            .onAppear {
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                    offset = 0
                }
            }
    }
}

extension View {
    func slideIn(from edge: Edge = .bottom) -> some View {
        self.modifier(SlideInEffect(edge: edge))
    }
}

// MARK: - Fade In Effect

struct FadeInEffect: ViewModifier {
    @State private var opacity: Double = 0
    
    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onAppear {
                withAnimation(.easeOut(duration: 0.4)) {
                    opacity = 1
                }
            }
    }
}

extension View {
    func fadeIn() -> some View {
        self.modifier(FadeInEffect())
    }
}

// MARK: - Glass Effect

struct GlassEffect: ViewModifier {
    let opacity: Double
    let blur: CGFloat
    
    init(opacity: Double = 0.1, blur: CGFloat = 20) {
        self.opacity = opacity
        self.blur = blur
    }
    
    func body(content: Content) -> some View {
        content
            .background(
                Color.white.opacity(opacity)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .blur(radius: blur)
            )
    }
}

extension View {
    func glass(opacity: Double = 0.1, blur: CGFloat = 20) -> some View {
        self.modifier(GlassEffect(opacity: opacity, blur: blur))
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    let status: Status
    let size: CGFloat
    
    enum Status {
        case online
        case offline
        case connecting
        case error
        
        var color: Color {
            switch self {
            case .online: return JarvisPalette.success
            case .offline: return JarvisPalette.textTertiary
            case .connecting: return JarvisPalette.warning
            case .error: return JarvisPalette.danger
            }
        }
        
        var isAnimated: Bool {
            switch self {
            case .online, .connecting: return true
            case .offline, .error: return false
            }
        }
    }
    
    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: size, height: size)
            .shadow(color: status.color.opacity(0.5), radius: 4)
            .if(status.isAnimated) { view in
                view.pulse(scale: 1.2)
            }
    }
}

// MARK: - Waveform Animation

struct WaveformAnimation: View {
    let isPlaying: Bool
    let barCount: Int = 5
    
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(JarvisPalette.primary)
                    .frame(width: 3, height: isPlaying ? randomHeight() : 4)
                    .animation(
                        isPlaying ? .easeInOut(duration: 0.4).repeatForever(autoreverses: true).delay(Double(index) * 0.08) : .default,
                        value: isPlaying
                    )
            }
        }
        .onAppear {
            if isPlaying {
                animateBars()
            }
        }
        .onChange(of: isPlaying) { _, newValue in
            if newValue {
                animateBars()
            }
        }
    }
    
    private func randomHeight() -> CGFloat {
        CGFloat.random(in: 8...20)
    }
    
    private func animateBars() {
        // Animation is handled by the modifier above
    }
}

// MARK: - Conditional View Modifier

extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
