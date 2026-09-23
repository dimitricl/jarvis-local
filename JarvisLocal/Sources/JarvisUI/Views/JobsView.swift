import SwiftUI
import JarvisCore

/// Liste minimale des jobs en cours (socle agents) : statut + bouton d'annulation.
/// Volontairement sans design poussé (le style visuel est une itération séparée).
/// Ne lit que `vm.jobs` (miroir MainActor de types Core) — jamais l'actor ni
/// JarvisServices, pour préserver la frontière L2 (voir ModuleBoundaryTests).
/// Type public : instanciée par ChatView ; ne s'affiche que s'il y a des jobs
/// actifs, pour ne pas changer la mise en page quand le socle est inactif.
public struct JobsView: View {
    @Environment(AppViewModel.self) private var vm

    public init() {}

    /// Jobs non terminés uniquement : l'historique (terminé/échoué/annulé)
    /// reste dans vm.jobs pour debug, mais n'encombre pas le chat.
    private var activeJobs: [JobRecord] {
        vm.jobs.filter { !$0.status.isTerminal }
    }

    public var body: some View {
        if !activeJobs.isEmpty {
            VStack(spacing: 4) {
                ForEach(activeJobs) { job in
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.2")
                            .foregroundStyle(JarvisTheme.amber)
                            .font(.caption2)
                        Text(job.title)
                            .font(JarvisTheme.mono(10, weight: .medium))
                            .foregroundStyle(JarvisTheme.textSecondary)
                            .lineLimit(1)
                        Text(job.status.displayLabel)
                            .font(JarvisTheme.mono(10))
                            .foregroundStyle(JarvisTheme.amber)
                        Spacer()
                        Button(action: { vm.cancelJob(job.id) }) {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(JarvisTheme.textTertiary)
                        .accessibilityLabel("Annuler le job \(job.title)")
                        .help("Annuler ce job d'arrière-plan")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
            .background(JarvisTheme.amber.opacity(0.06))
        }
    }
}
