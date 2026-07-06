# Changelog

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
