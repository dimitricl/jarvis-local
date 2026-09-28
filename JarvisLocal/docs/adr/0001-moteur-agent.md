# ADR 0001 — Moteur d'agent : maison (Swift) vs existant (opencode headless)

- Statut : **proposé** (runs d'eval en attente — phase 1 NON démarrée).
- Date : 2026-09-28.
- Contexte : mission v1.0 — passer d'un chatbot (boucle dans JarvisUI,
  ~30 outils métier, modèle edge faible compensé par rustines) à un agent
  omniprésent (hotkey, HUD, voix), avec LLM distant (Mac mini M4 via
  Tailscale, contexte réel plafonné ~16k, chargement à froid ~20 s).

## Option A — Moteur d'agent maison en Swift (phases 1-2 du plan)

- Boucle headless dans `JarvisAgent` (L1, sans UI) : `stream → tool_calls →
  permission → execute → append`, transcript persisté, compaction par résumé,
  budget de contexte explicite, `AsyncStream<AgentEvent>`.
- Outils généraux (~15) + MCP + permissions déclaratives + taint tracking.

## Option B — Moteur existant (opencode en mode serveur headless sur le Mac mini)

- Le MacBook ne garde que shell/HUD/voix/outils locaux (exposés via MCP) ;
  la boucle d'agent, la compaction et les permissions tournent côté serveur.
- Les phases 1-2 sont remplacées par un adaptateur `AgentBackend` + tests
  de contrat ; les phases 3-4 restent identiques.

## Critères chiffrés (mesurés par `JarvisEval` sur les 30 scénarios, §5 mission)

| Critère | Comment mesurer | Seuil indicatif pro-A |
|---|---|---|
| Taux de réussite eval (≥ 2 modèles locaux + 1 réf. cloud) | `JarvisEval`, `num_ctx` 16k puis max tenable | A ≥ B − 5 pts sur locaux |
| Latence bout en bout hotkey → premier token (chaud / après 30 min idle) | sonde RTT (`/api/tags`) séparée de `load_duration` + `eval_duration` | A p95 ≤ B p95 + 20 % |
| Surface de code à maintenir | `cloc` modules agent | A ≤ ~3 kLOC |
| Comportement lien tombé | Mac mini éteint puis rallumé : HUD `serveur injoignable`, outils locaux OK | A dégrade proprement sans B |
| Sécurité (permissions + taint tracking appliqués où ?) | test d'injection eval : aucune exfiltration/écriture sans confirmation | exigible des deux ; sinon éliminatoire |

## Règle de décision

- Cas général : si un modèle cloud réussit et le local échoue sur les mêmes
  scénarios : le goulot est le **modèle**, pas le harnais → privilégier B
  (moteur éprouvé) ou changer de modèle local, pas réécrire un moteur.
- **Adaptation 2026-09-28 (local-only : pas de clé API cloud disponible)** :
  la référence cloud est remplacée par une comparaison inter-modèles locaux
  (`gemma4:e4b` × `gemma4:12b`). Si le 12b réussit là où le petit échoue →
  goulot **modèle**. Si les deux échouent aux mêmes endroits → goulot
  **harnais**. Critère moins tranchant qu'une réf. cloud (noté comme limite),
  mais suffisant pour orienter A vs B.
- Si les deux échouent : le goulot est le **harnais** → corriger le harnais
  avant tout choix de moteur.
- Si B gagne : écrire l'adaptateur `AgentBackend` + tests de contrat, et
  archiver les phases 1-2 (pas de code maison jetable).
- Si A gagne : lancer phases 1-2.

## Décision

**En attente** des runs (`docs/eval-baseline.md`). Ne pas commencer la
phase 1 avant que cette section soit renseignée avec les chiffres et le
choix A ou B.

## Notes structurantes déjà tranchées (non remises en cause sans preuve)

- Budget de contexte = ressource gérée (compté en tokens via
  `prompt_eval_count`, schémas d'outils comptés, `tool_search`/`skill` à la
  demande), pas troncature aveugle en caractères.
- Maintien en mémoire = responsabilité serveur (`OLLAMA_KEEP_ALIVE=-1`,
  `docs/server-setup.md`), pas ping client.
- Lien indisponible = état normal affiché (`serveur injoignable`), mode
  dégradé local, jamais d'échec silencieux ni bascule auto de modèle.
- HTTP clair UNIQUEMENT vers hôte local / `100.64.0.0/10` / `*.ts.net`,
  sinon HTTPS ; aucun hôte en dur dans le repo.
