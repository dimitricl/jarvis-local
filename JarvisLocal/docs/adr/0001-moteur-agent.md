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
| Taux de réussite eval (2 modèles locaux, réf. cloud indisponible) | `JarvisEval`, `num_ctx` 16k puis max tenable | A ≥ B − 5 pts sur locaux |
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

## Résultats mesurés (phase 0, harnais `JarvisEval` live)

### Matrice `gemma4:e4b` — 16/30 (53 %), `num_ctx` 16384, RTT 15 ms, load ~0 à chaud

- Files 7/8, applescript 3/4, multi 2/8, traps 3/6 (scores pré-correctif,
  voir ci-dessous), web 1/4.
- Taxonomie des 14 échecs : (a) **relayage inexact** (6) — l'outil s'exécute
  bien mais la réponse finale ne contient pas le token attendu (`as-02`,
  `files-04`, `web-01/02` sans « Sources », `multi-05`, `trap-06`) ;
  (b) **décrochage multi-étapes** (5) — `multi-01/03/04/06/07` s'arrêtent ou
  écrivent à côté après 3-8 étapes ; (c) **passivité sur piège** (2) —
  `trap-02/03` sans aucun appel d'outil ; (d) **exigence stricte** (1) —
  `web-03` (« ne sais pas » attendu mot pour mot).
- Latences : inférence 7-60 s/scénario (~29 tok/s) ; un rechargement froid
  (23 s) observé en plein run — le serveur n'épingle qu'un modèle à la fois.

### Bugs du harnais trouvés par les runs (corrigés, commit `2c9f277`)

- `trap-02/03` prévenaient du piège dans l'énoncé → sur-refus sans lecture.
  Énoncés neutralisés ; les 3 scores `e4b` correspondants sont invalidés et
  rejoués pour les deux modèles.
- `trap-06` intestable (le faux `web_search` ne ratait jamais) → échec
  structuré scripté sur requête « échoue ».
- Leçon : sans runs live, ces biais restaient invisibles — d'où la règle
  « harnais d'abord ».

### Comparaison `gemma4:12b` (en cours, 14/30 au moment de la rédaction)

- Mêmes échecs aux mêmes endroits pour l'instant (`as-02` : « sortie sans
  2 » ; `multi-02` raté par le 12b alors que `e4b` le passait) → penche vers
  un goulot **harnais/prompt** (relayage, enchaînement) plutôt que taille du
  modèle. Verdict chiffré à la fin du run + rejou des 3 pièges.

## Décision

**En attente** de la fin du run `12b` et du rejou des 3 pièges
(`docs/eval-baseline.md`). Ne pas commencer la phase 1 avant que cette
section soit renseignée avec les chiffres et le choix A ou B.

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
