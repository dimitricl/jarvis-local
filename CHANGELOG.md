# Changelog

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

## 1.0.0 (2026-07-06)

- Chat avec Ollama (streaming, tool calls)
- 23 outils système (web, notes, rappels, calendrier, messages, AppleScript, etc.)
- Mémoire persistante (faits clé/valeur)
- Mode vocal (STF Apple + TTS macOS/edge-tts)
- Barge-in (interruption vocale)
- Confirmation utilisateur pour les outils sensibles
- Protection anti-injection de prompt (search_web)
- Filtre de sécurité AppleScript (anti-obfuscation)
