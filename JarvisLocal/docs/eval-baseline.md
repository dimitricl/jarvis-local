# Baseline d'évaluation agent (Phase 0)

Point zéro du pipeline **v0.9.1** puis cible **v1.0** (§7 mission : v1.0 >
v0.9.1 sur les 30 scénarios, ≥ 2 modèles locaux + 1 référence cloud).

## Lancer la matrice

```bash
cd JarvisLocal
# Sonde seule (RTT pur + allocation réelle) :
swift run JarvisEval --base-url "$JARVIS_EVAL_BASE_URL" --model gemma4:e4b --probe-only
# Run complet (exécution live branchée à l'itération suivante) :
swift run JarvisEval --base-url "$JARVIS_EVAL_BASE_URL" --model gemma4:e4b --num-ctx 16384
# Référence cloud :
ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" swift run JarvisEval \
  --provider anthropic --model <ref> --base-url https://api.anthropic.com
```

Matrice minimale : (modèle actuel `gemma4:e4b`) × (un modèle local plus
capable en tool-calling, `Capabilities: tools`, ≥ 24k de contexte dans la RAM
du Mac mini) × (référence cloud `--provider anthropic`), mêmes 30 scénarios,
`num_ctx` = 16k puis maximum tenable.

Jamais d'IP/host en dur : `--base-url` ou `JARVIS_EVAL_BASE_URL`. HTTP clair
refusé hors `localhost` / `100.64.0.0/10` / `*.ts.net` (testé).

## Lire un rapport

- **RTT** = réseau pur (`GET /api/tags`, sans inférence). **Load** =
  `load_duration` (chargement à froid). **Inférence** = `prompt_eval_duration
  + eval_duration`. Un hotkey « lent » se diagnostique dans cet ordre.
- **Alertes en tête** : modèle partiellement hors GPU (`size_vram < size`) ou
  `context_length` < `num_ctx` demandé (troncation silencieuse) invalident
  toute comparaison — refaire le run après `docs/server-setup.md`.
- **Tokens** : `prompt_eval_count` quand renvoyé (calibré), sinon `~N`
  (~4 car/token, borne documentée).

## Mesures sonde 2026-09-28 (serveur Mac mini via Tailscale, `--probe-only` + `/api/chat`)

- RTT réseau pur : **39 ms** (`GET /api/tags` via `JarvisEval`, sans inférence).
- Avant les runs, le modèle résident était `mistral-nemo:latest` (ctx 4096,
  100 % VRAM) — pas le modèle configuré : le serveur ne retient qu'**un**
  modèle à la fois (chaque changement de modèle évince le précédent).
- `gemma4:e4b`, `num_ctx`=16384, consigne tool `probe_ping` : wall 12,8 s =
  load **7,7 s** (froid) + prompt_eval 0,39 s (80 tok) + eval 4,61 s
  (133 tok, ~29 tok/s). `tool_calls` **OK**. `/api/ps` : ctx 16384 honoré,
  100 % VRAM. Le plafond 16k tient sur ce modèle.
- `gemma4:12b`, `num_ctx`=16384, même sonde : wall 22,7 s = load **13,5 s**
  + prompt_eval 0,91 s + eval 8,21 s (108 tok, ~13 tok/s). `tool_calls` OK,
  100 % VRAM.
- `gemma4:12b` à chaud (résident, load 0,01 s) : 58 s pour 747 tok (~13 tok/s),
  modèle verbeux sans garde-fous (appel brut, sans `reasoning_effort` ni
  `num_predict` — l'app les pose déjà).
- Inventaire : 22 modèles ; capables `tools` + ≥ 24k ctx : `gemma4:12b`
  (7,6 Go), `qwen3:14b`, `gpt-oss:20b`, `mistral-nemo` (ctx 1M annoncé),
  `qwen3.5:9b/16k`, `granite4.1:8b`. `Nanbeige4.2-3B` = `completion` seule,
  hors matrice tool-calling.
- Conclusion provisoire : le réseau (39 ms) est négligeable ; la latence vient
  du **chargement à froid** (8-14 s) et du **débit d'inférence** (13-29 tok/s).
  Le maintien en mémoire côté serveur (`docs/server-setup.md`) est le levier
  n° 1 pour le hotkey. Prochaine étape : runs des 30 scénarios sur
  `gemma4:e4b` × `gemma4:12b` × réf. cloud.

## Tableau comparatif

| Pipeline | Modèle | num_ctx | Réussite | Étapes méd. | RTT méd. | Load | Inférence méd. | Notes |
|---|---|---|---|---|---|---|---|---|
| v0.9.1 (sonde, pas de scénario) | gemma4:e4b | 16k | n/a (sonde `probe_ping` OK) | n/a | 39 ms | 7,7 s | 5,0 s | ctx réel = demandé, 100 % VRAM |
| v0.9.1 (sonde) | gemma4:12b | 16k | n/a (sonde `probe_ping` OK) | n/a | 39 ms | 13,5 s | 9,1 s | ~13 tok/s, verbeux à chaud |
| harnais live (30 scénarios) | gemma4:e4b | 16k | **19/30 (63 %)** | 2 (méd.) | 11-15 ms | ~0 à chaud | ~15 s/scén. | échecs = relayage (6) + multi-étapes (5) + strict (1) ; 0 exfiltration |
| harnais live (30 scénarios) | gemma4:12b | 16k | **15/30 (50 %)** | 2-3 | 11-17 ms | ~0 à chaud | ~25 s/scén. | mêmes modes d'échec + 2 timeouts ; 0 exfiltration |
| **nouveau moteur** (`AgentLoop`+`JarvisTools`, grille `AgentEval`) | gemma4:e4b | 16k | **22/30 (73 %) — GATE PASS** | 2-3 | ~15 ms | ~0 à chaud | ~20 s/scén. | échecs résiduels = variance relayage (as-02/03, web-01/02/03, multi-03/06, trap-01) ; 0 exfiltration vraie (2 faux positifs taint corrigés en cours de route) |
| v0.9.1 | modèle local capable | 16k → max | — | — | — | — | — | à mesurer |
| v0.9.1 | réf. cloud | n/a | — | — | — | — | — | goulot modèle vs harnais |
| v1.0 (cible) | idem | idem | **> v0.9.1** | — | — | — | — | §7.2 mission |

## Mesures d'usage à consigner ici (§7.5–7.6)

- Latence hotkey → premier token, à chaud et après 30 min d'inactivité.
- Comportement Mac mini éteint puis rallumé (HUD `serveur injoignable` → reprise).
- Contexte réel utilisé sur scénario long avec compaction.
- CPU/RAM au repos, fenêtres fermées (app `LSUIElement` toujours vivante).
