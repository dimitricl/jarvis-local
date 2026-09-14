# Changelog

## [0.5.0] - 2026-09-14

### Ajouts
- **Barre de menu** (waveform) : mode vocal, afficher, quitter sans fenêtre ouverte
- **Lancement au démarrage** (SMAppService, Réglages > Général) + **notification**
  quand une réponse longue (> 8 s) se termine en arrière-plan
- **Accessibilité** : labels VoiceOver sur tous les boutons icônes et champs
- **Migrations DB versionnées** (`PRAGMA user_version`, v1 tables, v2 index + orphelins)
- **Énergie** : keep-alive Ollama suspendu en low-power/thermal critique ;
  `beginActivity` anti-sommeil pendant le TTS
- **Release distribuable** : CI assemble le `.app`, notarise + agrafe (secrets),
  publie le zip en artefact

## [Non publié]

### Corrections
- **Troncature post-tool** — défaut `maxTokens` 8192 → 32768 ; cause précise non
  identifiée (pas de raisonnement caché mesuré), piste `/api/chat` + `think:false`
  documentée si récidive
- **Audit sécurité/concurrence** — outil `applescript` générique SUPPRIMÉ (RCE par
  concaténation) → `PowerAction` typée + templates figés ; `create_note`/`open_app`/
  `get_clipboard` en confirmation ; outils MCP héritent du statut sensible natif ;
  `read_url` wrappée + anti-SSRF (LAN, `file://`, rebinding — aussi sur `search_web`) ;
  ATS restreint à `localhost`, warning Ollama distant ; edge-tts supprimé (TTS on-device,
  `Logger`) ; synthé via MainActor (restart corrigé) ; diag SSE `/tmp` retirée ;
  DB WAL + FK + index ; CI lint strict + release signée hardened + entitlements
  (261 tests : 252 XCTest + 9 Swift Testing)

### Diagnostics (sans code)
- **« Succès mensongers »** — cause = `qwen3.5:9b`, retour `gemma4:e4b` requis ;
  transport et MCP exonérés
- **MCP validé en réel** (iMCP v1.4.1) : lecture + créations calendrier/rappels,
  contacts/messages en lecture ; `send_message` et `search_maps` restent natifs ;
  Rappels exige parfois un `killall iMCP` (permission non effective)

### Docs
- **README** (racine + paquet) à jour : MCP opt-in, archi `Tools/`, 251 tests

## [0.4.1] - 2026-09-13

### Corrections
- **Transport MCP** (validé en réel contre iMCP v1.4.1) — `notifications/initialized`
  après `initialize`, settle 1 s pour le relais Bonjour, timeout 60 s
- **Délégation recalée sur les vrais noms iMCP** (`events_*`, `calendars_list`,
  `reminders_*`, `contacts_search`) — les noms précédents ne matchaient rien
- **`send_message` et `search_maps` redeviennent natifs** (iMCP = read-only sur
  ces domaines)
- **`effectiveToolDefs()` masque les natifs remplacés** (fini les outils concurrents)

### Validation réelle
- Calendrier (lecture + création), rappels (listes + création + lecture),
  contacts (lecture), messages (lecture) le 13/09. `mcpEnabled` reste désactivé
  par défaut ; diagnostic Rappels : permission accordée mais non effective sans
  relance de l'app (`killall iMCP`)

## [0.4.0] - 2026-09-13

### Ajouts
- **Recherche web robuste** — cascade API officielle DuckDuckGo Instant Answer → parsing
  DOM SwiftSoup → fallback regex legacy avec mention de mode dégradé (`WebSearchService`)
- **Découpage ToolService** — `execute(name:args:)` route vers `CalendarTools`,
  `RemindersTools`, `MessagingTools`, `SystemTools`, `WebTools`, `NotesTools`,
  `MemoryTools` ; extraction des faits en `FactExtractor` pur et testable
- **Client MCP (EXPÉRIMENTAL, désactivé par défaut, NON VALIDÉ en réel)** —
  `MCPToolProvider` (stdio JSON-RPC) fusionne les outils iMCP et route `execute()` ;
  commande serveur résolue dynamiquement (jamais en dur — iMCP = un unique
  `imcp-server` dans `iMCP.app`) ; flag `mcpEnabled` + champ `imcpPath` dans Réglages ;
  outils sensibles/rapides (`sleep_mac`, `applescript`, captures, presse-papiers,
  `search_web`) restent natifs. Tests unitaires verts sans le vrai binaire, mais
  l'aller-retour réel n'a pas pu être testé (iMCP non installé : `brew install
  --cask mattt/tap/iMCP`, macOS 15.3+, activation manuelle des services).
  Ne pas activer en usage réel avant validation manuelle.

## [0.3.1] - 2026-09-12

### Corrections
- **Synthèse vocale** — stop fiable en pleine lecture (plus de voix qui continue malgré
  le stop ni de TTS muet ensuite)
- **Copier-coller** — messages sélectionnables + menu contextuel « Copier » et bouton
  copiant le message ENTIER
- **Mémoire** — `remember_fact` propage l'erreur DB au lieu d'un succès mensonger ;
  fait identique déjà stocké auto-approuvé (fini la double popup)
- **Outils** — dédupe par appel (le batch n'est plus jeté pour un seul doublon),
  refus/échecs formulés explicitement + règle système anti-hallucination
- **Blocage** — Stop pendant une confirmation la résout en refus ; `resolve` idempotent
- **Mémoire « je suis Dimitri »** — heuristique `je suis / moi c'est / c'est moi /
  mon prénom est` + filtre anti-bruit + élagage des liaisons finales
- **Auditabilité web** — `search_web`/`read_url` renvoient la Source URL, ligne
  « Sources : » exigée puis ajoutée d'office si oubliée
- **Audit persistant** — table `tool_runs` + commande `/tools`
- **Température LLM réglable** (Réglages, 0–2, défaut 0,7)

## [0.3.0] - 2026-09-12

### Corrections
- **SQLite critique** — `SQLITE_TRANSIENT` + ids liés en INTEGER (risque de corruption
  mémoire sur chaînes longues/unicode)
- **Thread-safety STTService** — état mutable sérialisé sur file unique
- **Contexte** — plafond d'historique dérivé de `num_ctx` + troncature des résultats
  « tool » en 3 passes + réparation d'appariement assistant/tool_calls

### Ajouts
- **Sécurité** — `take_screenshot` rejoint les `sensitiveTools`
- **Repo** — prototype Bun/TS déplacé dans `legacy/` avec README (projet actif = Swift)

## [0.2.2] - 2026-09-12

### Corrections
- **Anti-crash Swift** — `colText` NULL guard, `bindArgs` Double/Int64,
  `stripThinking` multiline, `try!` → `try?`, double-resume `CheckedContinuation`
- **Serveur** — validation `PORT`/`NUM_CTX`, fallback `EDGE_TTS_BIN`, fix path traversal,
  validation API (400/404), purge leak rate-limit, TTS hybride robuste
- **Web** — `wss` auto, `JSON.parse` guard, fix streaming `onclose`, XSS strip,
  `SILENCE 700→1200`, anti double PATCH rename
- **Sécurité** — purge `memory.db` de l'historique git, `.env.example` documenté

## [0.2.1] - 2026-09-04

### Ajouts
- **Fiabilité réseau Ollama** — la fonction de `warmUp` (maintien du modèle chargé) réessaie automatiquement avec un backoff exponentiel (jusqu'à 3 tentatives) en cas d'échec réseau transitoire
- **Throttling de la vérification de mises à jour** — `checkForUpdates` ne contacte plus GitHub qu'une fois toutes les 24h (date mémorisée dans UserDefaults), pour réduire la charge et les limites de requêtes
- **Barre de recherche** — nouveau panneau de recherche plein-texte (`/search` ou bouton loupe)
- **Aide contextuelle** (`/help`) — panneau listant les commandes slash
- **Tests étoffés** — suite de tests étendue (Ollama, Settings, Search/Export, Audio, STT, AppViewModel, ToolService)

### Corrections
- **Champ de saisie** — bug corrigé où une saisie rapide pouvait effacer les derniers caractères ou faire sauter le curseur (`AutoResizingTextView`)
- **Synthèse vocale** — normalisation du texte avant TTS (suppression markdown/émojis, abréviations)
- **Base de données** — requêtes et gestion d'erreurs plus robustes
- **Conflits de noms de classes de test** résolus pour permettre l'exécution complète de la suite

## [0.2.0] - 2026-07-06

### Ajouts
- **Champ de saisie multi‑lignes** — TextEditor remplace TextField, Entrée = nouvelle ligne, Cmd+Entrée = envoyer
- **Scroll auto** au‑delà de 80pt de hauteur
- **Annulation d'écho (AEC)** — `setVoiceProcessingEnabled(true)` sur le micro, réduit le larsen haut‑parleur → micro
- **Barge‑in renforcé** — fenêtre de grâce de 600ms après le début du TTS, debounce sur 2 partials consécutifs
- **`remember_fact`** classé outil sensible (confirmation utilisateur obligatoire)
- **Tests `sensitiveTools`** — les tests lisent la vraie liste du ViewModel (`internal` au lieu de `private`) + garde‑fou listant tous les outils à effet de bord connus

### Corrections
- Seuil de transcription vocale repassé de 2 caractères à ≥ 2 mots (moins de faux déclenchements par souffle/bruit)
- `bargeInEnabled` remis à `true` par défaut (protégé par grace period + debounce)

## [0.1.0] - 2026-07-06

### Ajouts
- Interface macOS native (SwiftUI)
- Chat avec LLM local via Ollama (gemma4, etc.)
- Outils : search_web, read_url, apple_script, send_message, create_note
- Reconnaissance vocale (STT) via Apple Speech Framework
- Synthèse vocale (TTS) : Apple AVSpeechSynthesizer + edge-tts (optionnel)
- Barge-in : interrompre le TTS en parlant
- Mode vocal complet (mains-libres)
- Recherche web via DuckDuckGo
- Gestion de faits (contexte récurrent)
- Système de mise à jour via GitHub Releases
- CI/CD : GitHub Actions (build + test)
- Script de build `run.sh` avec version dynamique depuis le tag git

### Corrections
- Crash fixed : `edgeTTSAvailable` passée de computed property à stored property
- Reconnaissance vocale : silence timer 2.5s → 4s, buffer audio 4096 → 16384
- Reconnaissance vocale : utilise les serveurs Apple (plus précis que on-device)
- Toggle mode vocal : coupe aussi la requête LLM en cours
- `checkForUpdates` : meilleurs messages d'erreur (code HTTP)
- Version tag : gère les préfixes `v` et `V`
- Prompt renforcé : outils mieux décrits, barge-in désactivé par défaut
