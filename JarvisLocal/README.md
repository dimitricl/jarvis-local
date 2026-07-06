# JarvisLocal

Assistant IA personnel pour macOS, 100% local — dans l'esprit du JARVIS d'Iron Man.

## Prérequis

- macOS 14.0+
- [Ollama](https://ollama.ai) avec un modèle compatible (gemma4, llama3, etc.)
- Optionnel : `edge-tts` pour la synthèse vocale améliorée (`pip install edge-tts`)

## Installation

```bash
git clone https://github.com/votre-compte/JarvisLocal.git
cd JarvisLocal
./run.sh
```

Le script compile le projet et le copie dans `/Applications/JarvisLocal.app`.

## Permissions requises

L'application demande l'accès à :
- Microphone et reconnaissance vocale (mode vocal)
- Calendriers et Rappels (gestion d'événements)
- Contacts (envoi de messages)
- Accessibilité/Automatisation (AppleScript, Shortcuts)
- Capture d'écran

## Configuration

Depuis l'icône ⚙️ dans l'interface :
- URL du serveur Ollama (défaut : `http://localhost:11434`)
- Modèle LLM
- Synthèse vocale : système (AVSpeechSynthesizer) ou edge-tts
- Reconnaissance vocale (français)
- Barge-in (interruption du TTS par la parole)

## Fonctionnalités

- Chat avec LLM local (outils : recherche web, météo, Apple Notes, Rappels, Calendrier, iMessage, Shortcuts, etc.)
- Mémoire de faits personnels (reconnus automatiquement, confirmés par l'utilisateur)
- Mode vocal mains-libres avec barge-in
- Routines (ex. routine "morning" : météo + calendrier + infos système)
- Capture d'écran, presse-papiers, recherche Spotlight
- Contrôle du Mac (veille, verrouillage, extinction, redémarrage)

## Architecture

```
JarvisLocal/
├── Models/        # Structures de données (Message, Conversation, Tool, Fact)
├── ViewModels/    # Logique métier (AppViewModel)
├── Services/      # Ollama, outils macOS, base SQLite, audio, settings
├── Helpers/       # Thème, extensions, utilitaires
└── Views/         # Interface SwiftUI
```

## Tests

```bash
swift test
```

## Licence

Voir LICENSE.
