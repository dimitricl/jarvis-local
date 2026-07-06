# JarvisLocal

Assistant IA personnel pour macOS — inspiré de Jarvis d'Iron Man.

## Prérequis

- macOS 14+ (Sonoma)
- [Ollama](https://ollama.com) installé et lancé avec un modèle compatible (ex: `gemma4`, `llama3`)
- Xcode 15+ (pour compiler depuis les sources)

## Installation

```bash
git clone https://github.com/votre-compte/JarvisLocal.git
cd JarvisLocal
./run.sh
```

Le script compile le projet, le copie dans `/Applications` et le lance.

## Utilisation

1. Lancez Ollama : `ollama serve`
2. Ouvrez JarvisLocal
3. Commencez à discuter avec Jarvis dans la barre de saisie

### Fonctionnalités

- **Chat local** avec Ollama (API OpenAI-compatible)
- **23 outils** : recherche web, Apple Notes, Rappels, Calendrier, iMessage, presse-papiers, capture d'écran, AppleScript, Raccourcis, etc.
- **Mémoire persistante** : Jarvis se souvient de vos informations personnelles
- **Mode vocal** : reconnaissance vocale + synthèse (macOS ou edge-tts)
- **Barge-in** : interrompez Jarvis pendant qu'il parle
- **Sécurité** : confirmation utilisateur avant toute action sensible

## Dépendances externes

- [Ollama](https://ollama.com) — serveur LLM local
- `edge-tts` (optionnel) — voix TTS de meilleure qualité : `pip install edge-tts`

## Architecture

Le projet suit une architecture MVVM :

```
JarvisLocal/
├── Models/          # Structures de données (Message, Conversation, Fact, Tool)
├── ViewModels/      # Logique métier (AppViewModel)
├── Views/           # Interface SwiftUI
├── Services/        # Services système (Ollama, Base de données, Audio, Outils)
└── Helpers/         # Extensions et utilitaires
```

Tous les services sont des singletons (`shared`). `DatabaseService` et `ToolService` sont des `actor` Swift pour la sécurité des threads.
