# Changelog

## Non publié

## 0.4.0 (2026-09-13)

- `search_web` robuste : cascade API officielle DuckDuckGo Instant Answer
  → parsing DOM SwiftSoup (`lite.duckduckgo.com`) → fallback regex legacy avec mention
  de mode dégradé ; nouveau `WebSearchService` (actor) + `formatSearchResults` conservé
  comme alias de compat ; dépendance SwiftSoup dans `Package.swift`
- Découpage `ToolService` : un seul point d'entrée `execute(name:args:)`
  qui route vers `CalendarTools`, `RemindersTools`, `MessagingTools`, `SystemTools`,
  `WebTools`, `NotesTools`, `MemoryTools` (contexte `ToolContext` + `ProcessRunner`
  partagés) ; logique d'extraction de faits extraite en `FactExtractor` pur et testable,
  `AppViewModel` ne fait que déléguer (comportement identique, 247 tests verts)
- Client MCP (EXPÉRIMENTAL, désactivé par défaut, NON VALIDÉ en conditions réelles) :
  nouveau `MCPToolProvider` (actor, transport stdio JSON-RPC minimal) qui fusionne les
  outils iMCP dans la liste Ollama et route `execute()` vers le bon transport ; commande
  serveur résolue dynamiquement (env `JARVIS_IMCP_PATH` > Réglages > bundle iMCP.app >
  `which imcp-server`, jamais en dur — iMCP expose un unique `imcp-server`, pas de
  binaire à sous-commandes) ; flag `mcpEnabled` (désactivé par défaut, aucun impact
  tant qu'inactif) + champ `imcpPath` dans Réglages ; `sleep_mac`, `applescript`,
  captures, presse-papiers et `search_web` restent natifs. Code couvert par tests
  unitaires (aucun ne requiert le vrai binaire), mais l'aller-retour réel contre iMCP
  (calendrier, rappels, message) n'a PAS pu être testé — iMCP non installé sur la
  machine de dev (`brew install --cask mattt/tap/iMCP`, macOS 15.3+, activation manuelle
  des services dans l'app). Ne pas activer en usage réel avant validation manuelle.
- Fix copier-coller : les messages utilisateur sont de nouveau sélectionnables, chaque bulle
  a un menu contextuel « Copier » + un bouton copier qui copie le message ENTIER (le rendu
  riche découpe le texte en N vues entre lesquelles la sélection ne traverse pas)
- Fix mémoire : `remember_fact` ne prétend plus avoir mémorisé quand l'écriture DB échoue
  (erreur propagée au modèle au lieu du `try?` silencieux + succès mensonger) ; idem pour
  la confirmation heuristique (erreur visible au lieu d'être avalée) ; un `remember_fact`
  identique à un fait déjà stocké est auto-approuvé (fini la double popup)
- Fix outils : le garde anti-doublon ne jette plus tout le batch quand un seul appel est
  un doublon — les appels inédits s'exécutent, seuls les vrais doublons sont refusés (avec
  réponse `tool` pour garder l'appariement appel ↔ résultat) ; refus et échecs d'outils
  formulés explicitement (« tu n'as RIEN exécuté ») + règle système anti-hallucination
  (ne jamais affirmer une action sans l'avoir appelée)
- Fix blocage : Stop pendant une confirmation en attente la résout en refus au lieu de
  laisser le tour suspendu pour toujours ; `ToolConfirmationRequest.resolve` idempotent
  (double clic/dismiss = une seule reprise de continuation)
- Tests : dédupe par appel, resolve unique, Stop libère la confirmation, `remember_fact`
  vide rejeté (202 verts)
- Fix mémoire (cas réel « je suis dimitri ») : l'heuristique capte désormais « je suis X »,
  « moi c'est X », « c'est moi X », « mon prénom est X » — avec filtre anti-bruit (états,
  métiers, locutions : « d'accord », « en retard », « développeur »…) et élagage des mots
  de liaison finaux (« Dimitri et toi » → « Dimitri ») ; consigne modèle explicite :
  jamais de « c'est noté / je m'en souviendrai » sans appel `remember_fact` (206 verts)
- Fix auditabilité web (cas réel iPhone 18 Pro : prix/dates exacts mais chiffres CPU/GPU/
  autonomie brodés) : `search_web` et `read_url` renvoient désormais la Source URL au modèle,
  et le prompt exige une ligne « Sources : » avec ces URL uniquement + d'avouer les chiffres
  manquants au lieu de les deviner
- Citation garantie : si le modèle oublie les sources après un search_web/read_url, l'app les
  ajoute d'office en fin de réponse (jamais lues à voix haute par le TTS)
- Audit persistant des outils : chaque exécution (réussie, refusée, échouée, ignorée) est
  journalisée en base (table `tool_runs`) et consultable via la nouvelle commande `/tools`
  — fini le « il l'a vraiment fait ? » invérifiable
- Température LLM réglable (Réglages, curseur 0–2, défaut 0,7) : baisser (~0,2) limite les
  chiffres inventés dans les réponses factuelles (214 verts)

## 0.3.1 (2026-09-12)

- Fix synthèse vocale : correctif d'un blocage rare lors d'une interruption en pleine lecture
  (la voix pouvait continuer malgré le stop, ou rester muette par la suite) — la lecture
  s'arrête désormais de façon fiable et ne redémarre plus toute seule
- Tests : `stopSpeaking()` en tearDown des tests TTS pour ne plus laisser de parole en cours
  fuiter d'un test à l'autre

## 0.3.0 (2026-09-12)

- Fix critique SQLite : `sqlite3_bind_text` utilisait `nil` (SQLITE_STATIC) sur des pointeurs
  NSString temporaires → passage à SQLITE_TRANSIENT dans `exec` et `bindArgs` (risque de
  corruption mémoire sur chaînes longues/unicode) ; `exec` accepte désormais `[Any?]` et les
  id sont liés en INTEGER (`updateConversationTitle`, `deleteConversation`, `insertMessage`
  ne convertissent plus en String)
- Fix thread-safety `STTService` : tout l'état mutable (`isRecording`, `recognitionRequest`,
  `silenceTimer`, `restartCount`, continuation, `onPartialResult`) est sérialisé sur une file
  unique — la closure Speech (thread arbitraire), MainActor et le timer ne se marchent plus dessus
- Sécurité : `take_screenshot` rejoint les `sensitiveTools` (capture plein écran = contenu privé,
  fichier PNG ouvert aussitôt) avec un résumé de confirmation dédié
- Robustesse contexte : plafond d'historique dérivé de `num_ctx` (réserve génération + marge,
  plancher 4000 car.) appliqué avant chaque appel modèle ; troncature des résultats "tool"
  anciens en 3 passes (extrait marqué → résumé 1 ligne → suppression) + réparation systématique
  d'appariement assistant/tool_calls ↔ tool (aucun `tool_call_id` orphelin, sinon rejet backend)
- Nettoyage repo : prototype Bun/TS (`server.ts`, `public/`, `package.json`, `bun.lock`,
  `tsconfig.json`, `.env`, `memory.db`) déplacé dans `legacy/` avec README (projet actif =
  app Swift, seule cible de la CI) ; commentaire dupliqué supprimé dans `AppViewModel`
- Note : `testIsSpeakingProperty` est sensible au timing (singleton TTS réel + délai de 5 s) et
  peut flaker en suite complète — vert en isolé, sans lien avec cette session

## 0.2.2 (2026-09-12)

- Fix anti-crash Swift : `DatabaseService.colText` NULL guard, `bindArgs` Double/Int64
- Fix `stripThinking` multiline (`dotMatchesLineSeparators`) via `NSRegularExpression`
- Fix `try!` → `try?` dans `StringExtensions` et `MessageBubbleView`
- Fix double-resume `CheckedContinuation` dans `AudioService` (TTS) et barge-in
- Serveur : validation `PORT`/`NUM_CTX`, fallback `EDGE_TTS_BIN=edge-tts`, fix path traversal `public/`, validation `history`/`conversations`/`facts` (400/404), purge leak rate-limit `close()`, TTS hybride robuste (tmp cleanup, `which` resolve)
- Web : `wss` auto, `JSON.parse` guard, `onclose` streaming fix, XSS strip, `SILENCE 700→1200`, anti double PATCH rename
- Sécurité : purge `memory.db` de l'historique git (filter-repo), `.env.example` localhost documenté

## 0.2.1 (2026-09-04)

- Fiabilité réseau Ollama : `warmUp` avec backoff exponentiel (3 tentatives)
- Throttling `checkForUpdates` (1 fois / 24 h via UserDefaults)
- Barre de recherche plein-texte (`/search`), aide contextuelle (`/help`)
- Corrections : champ de saisie (curseur), normalisation TTS, requêtes DB robustes,
  conflits de noms de classes de test
- (Détail complet dans `JarvisLocal/CHANGELOG.md`)

## 1.0.0 (2026-07-06)

- Chat avec Ollama (streaming, tool calls)
- 23 outils système (web, notes, rappels, calendrier, messages, AppleScript, etc.)
- Mémoire persistante (faits clé/valeur)
- Mode vocal (STF Apple + TTS macOS/edge-tts)
- Barge-in (interruption vocale)
- Confirmation utilisateur pour les outils sensibles
- Protection anti-injection de prompt (search_web)
- Filtre de sécurité AppleScript (anti-obfuscation)
