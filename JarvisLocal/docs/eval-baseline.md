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

## Tableau comparatif (runs en attente du Mac mini)

| Pipeline | Modèle | num_ctx | Réussite | Étapes méd. | RTT méd. | Load | Inférence méd. | Notes |
|---|---|---|---|---|---|---|---|---|
| v0.9.1 (point zéro) | gemma4:e4b | 16k | — | — | — | — | — | à mesurer |
| v0.9.1 | modèle local capable | 16k → max | — | — | — | — | — | à mesurer |
| v0.9.1 | réf. cloud | n/a | — | — | — | — | — | goulot modèle vs harnais |
| v1.0 (cible) | idem | idem | **> v0.9.1** | — | — | — | — | §7.2 mission |

## Mesures d'usage à consigner ici (§7.5–7.6)

- Latence hotkey → premier token, à chaud et après 30 min d'inactivité.
- Comportement Mac mini éteint puis rallumé (HUD `serveur injoignable` → reprise).
- Contexte réel utilisé sur scénario long avec compaction.
- CPU/RAM au repos, fenêtres fermées (app `LSUIElement` toujours vivante).
