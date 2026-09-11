# Changelog

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
