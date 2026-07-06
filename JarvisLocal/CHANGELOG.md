# Changelog

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
