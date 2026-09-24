# Changelog

## [0.8.2] - 2026-09-24

### Sécurité MCP, diagnostic et suivi du tour
- **MCP verrouillé** — une politique locale centrale limite les capacités
  déléguables aux outils iMCP explicitement approuvés ; une configuration peut
  retirer une capacité, jamais en ajouter une. Les outils inconnus ou sensibles
  restent refusés à la découverte comme à l'exécution.
- **Diagnostic sans fuite de contenu** — journal OS structuré pour le début/la
  fin des tours et des outils (durée + issue), sans prompt, réponse, argument
  ni résultat ; visible dans Console.app sous `conversation-turn` et
  `tool-execution`.
- **État de conversation explicite** — le bandeau distingue confirmation
  requise, outil en cours, réflexion et réponse en cours. Un outil terminé ne
  reste plus affiché comme actif jusqu'à la fin du tour.
- **Tests modernisés** — la suite MCP utilise désormais Swift Testing et reste
  sérialisée autour du singleton d'outils.

### Découpage AppViewModel — même comportement, responsabilités séparées
- **Fini le god-object** — `AppViewModel` (1243 → ~850 lignes) délègue à trois
  composants à responsabilité unique dans
  `Sources/JarvisUI/ViewModels/Conversation/` : `FactsExtractionCoordinator`
  (extraction + confirmation + CRUD faits), `ToolCallLoop` (filtres anti-boucle,
  confirmation sensible, exécution isolée, wrap web) et `ConversationTurnRunner`
  (orchestration d'un tour : prompt système, streaming, boucle de tools)
- **Zéro changement observable** — prompt système vérifié identique au caractère
  près (hors indentation source, retirée par Swift dans les deux cas), mêmes
  libellés de tool-calling, mêmes signatures publiques ; les forwarders
  historiques restent pour compatibilité, aucune nouvelle dépendance
  JarvisUI → JarvisServices (frontière vérifiée par `ModuleBoundaryTests`)
- **Tests** — 20 nouveaux (8 coordinator, 8 tool loop, 4 runner : tour complet
  sur fakes sans DB ni LLM réel), 93 dans le bundle UI, suite 100 % verte

## [0.8.1] - 2026-09-23

### Réseau borné et annulation propre
- **Fin des pics mémoire réseau** — `read_url`, `search_web` et la météo
  plafonnent chaque réponse pendant le transfert (2 Mo pages, 512 Ko JSON) et
  annulent explicitement la requête au plafond : un lien vers un gros fichier
  ne peut plus faire gonfler l'app à plusieurs Go
- **Annulation qui annule vraiment** — interrompre pendant un téléchargement
  coupe la requête et termine en annulation, jamais en succès ; la course
  annulation/plafond est tranchée atomiquement (résultat validé conservé,
  sinon `CancellationError`)
- **En-têtes menteurs neutralisés** — un `Content-Length` incohérent ne masque
  plus les erreurs réseau et ne fabrique plus de fausse troncation (signalée
  explicitement) ; binaires refusés dans `read_url`, coupures UTF-8 réparées,
  mention « contenu tronqué » quand le plafond est atteint
- **Tests** — 16 nouveaux déterministes sans réseau réel (session simulée),
  389 au total, suite 100 % verte

## [0.8.0] - 2026-09-23

### Socle tâches de fond (agents) — fondation, pas encore visible
- **Jobs en arrière-plan** — nouveau registre d'exécution : un travail peut
  tourner pendant que l'utilisateur continue à utiliser l'app, avec suivi
  (en attente / en cours / terminé / échoué / annulé) et bouton d'annulation
  dans le chat
- **Aucun changement visible pour l'instant** — aucun outil n'est encore branché
  sur ce socle (le branchement « un tool call devient un job » est l'itération
  suivante) : si aucun job ne tourne, l'interface est strictement identique
- **Comportement garanti** — un travail trop long bascule en échec explicite
  (timeout configurable) au lieu de rester bloqué ; un arrêt demandé affiche
  « Annulé », jamais « Échoué » ; arrêter un job déjà fini est sans effet
- **Tests** — 10 nouveaux (9 socle : exécution, annulation, timeout,
  concurrence, flux + 1 gel du miroir à l'arrêt de l'observation), 373 au total,
  suite 100 % verte

## [0.7.1] - 2026-09-16

### Pipeline release
- **Release réparée** — le workflow ne se déclenchait jamais sur les tags
  (`branches: [main]` uniquement) et ne créait aucune GitHub Release (artefact
  seul) ; trigger `tags: ['v*']` + étape `gh release create` idempotente
  (le garde tag ↔ CHANGELOG exige cette entrée aux deux endroits)

### Outils : extraction stricte + CRUD + fichiers sandboxés
- **Dispatcher durci** — fini les `args["x"] as? String ?? ""` silencieux : un
  paramètre manquant ou mal typé renvoie « Paramètre 'x' manquant ou de type
  invalide pour l'outil 'y' » au lieu d'exécuter une action non demandée ;
  couvert par tests pour CHAQUE outil (manquant + mal typé)
- **CRUD outils** — `complete_reminder`/`delete_reminder`,
  `edit_calendar_event`/`delete_calendar_event`, `search_notes`/`read_note`
  (même format ToolDef que `add_reminder`/`list_reminders`) ; `list_reminders`
  et `get_upcoming_events` exposent désormais les `[id:]` — jamais d'action
  sur identifiant deviné ou titre approximatif, les 4 actions destructives
  exigent confirmation (`sensitiveTools` + résumés dédiés)
- **Fichiers sandboxés** — nouveau `FileTools` (`list_directory`/`read_file`),
  seuls les chemins résolus sous ~/Documents, ~/Desktop, ~/Downloads sont
  acceptés (symlink, `..`, absolu ailleurs = refus explicite fail-closed comme
  `URLSafety.isBlocked`) ; lecture plafonnée à 200 Ko (même pattern que
  `WebTools.maxPageBytes`), binaires (UTF-8 raté) refusés
- **Test `testSleepMacActions` désamorcé** — `sleep`/`shutdown`/`restart`
  exécutaient réellement la veille/l'extinction/le reboot du Mac lanceur ;
  seul `lock` reste (verrouille réellement l'écran : à lancer en connaissance
  de cause)

## [0.7.0] - 2026-09-16

### Interface Apple classique + verre dosé
- Thème sémantique : textes `.primary/.secondary/.tertiary`, fonds base/élevé,
  accent cyan → bleu système, suivi auto clair/sombre (vérifié par screenshots
  des deux modes) ; plus aucune couleur hardcodée
- Bulles façon Messages (bleu/blanc + gris système), saisie en material texte,
  sheets en base/élevé, boutons `.glass`/`.glassProminent`, morphing envoi/stop
  (ID partagé + matchedGeometry), sidebar `List` native, toolbar unifiée
- Plancher macOS 26 (outils 6.2, mode langage Swift 5 conservé), CI `macos-26`

### Filet DB post-incident
- Backup horodaté avant migration (rétention 3) + `os_log` des suppressions
- Fix migration v3 : `ADD COLUMN` sans défaut SQL (non-constant refusé en prod)

### Architecture (déjà livrée en 0.6.0, incluse)
- Couches Core/Services/UI, LLM découplé (factory), faits v3, budget anti-boucle

## [0.6.0] - 2026-09-15

### Architecture en couches (4 chantiers)
- Frontières vérifiables par le compilateur : JarvisCore (models + protocols
  purs), JarvisServices (actors + I/O, seul à toucher SQLite), JarvisUI
  (Views + ViewModels, dépend de Core uniquement) ; tests par module
  (CoreTests/ServicesTests/LocalTests) + garde-fous de frontière
- LLM découplé : protocol LLMProvider + `LLMProviderKind` + factory (Ollama =
  1re implémentation, pas de second provider) ; configuration injectée via
  protocol, keep-alive sur l'instance retenue par l'app
- Mémoire : faits enrichis (message source, confiance 0-1, created_at, statut
  actif/remplacé) + migration DB v3 rejouable (backfill, données préservées) ;
  FactExtractor intact
- Budget anti-boucle : max d'invocations d'un même outil par tour (défaut 4,
  clamp 1-10, Réglages > Boucle d'outils) ; boucle `search_web` prouvée coupée
  par test

## [0.5.1] - 2026-09-14

### Correctifs mémoire (pics à 40+ Go)
- Plafonds : downloads web 2 Mo, sorties process 512 Ko, buffer MCP 10 Mo,
  file TTS 50 items / 20k caractères
- Streaming Ollama throttlé (fini le O(n²) par delta) ; dictée max 120s/prise ;
  stderr MCP drainé ; race timeout `ProcessRunner` corrigée
- Fix build `batteryInfo` (`IOPSCopyPowerSourcesList`)

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

### Refonte visuelle native — identité plus distinctive dans le cadre System
- **Accent teal adaptatif** — le bleu système des actions devient un teal système,
  adaptatif en modes clair/sombre et contraste augmenté ; amber et danger restent
  inchangés pour préserver strictement la sémantique de couleur
- **Réponses assistant en layout log** — fond de bulle retiré au profit d'une icône
  CPU compacte, d'un liseré vertical teal de 2 pt et d'un timestamp mono toujours
  visible sous le texte ; la bulle utilisateur pleine reste immédiatement lisible
- **Trace d'outils contextualisée** — les entrées `ToolTraceEntry` inchangées (nom
  + statut …/✓/✗) sont rendues en style mono sous le tour concerné, plus lisiblement
  intégrées au flux qu'une barre flottante séparée, sans modifier l'ordre VoiceOver
- **Sélection sidebar teal** — barre verticale de 2,5 pt sur la ligne active, avec
  `List` sidebar native conservée pour le clavier, l'accessibilité et le comportement
  système ; aucun fond custom opaque, glow, néon ou changement de comportement
- Suite complète et frontière `ModuleBoundaryTests` vertes, sans nouvelle dépendance
  JarvisUI → JarvisServices

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
