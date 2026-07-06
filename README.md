# JarvisLocal

[![CI](https://github.com/dimitricl/jarvis-local/actions/workflows/ci.yml/badge.svg)](https://github.com/dimitricl/jarvis-local/actions/workflows/ci.yml)
![macOS](https://img.shields.io/badge/macOS-14+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)

Assistant IA personnel pour macOS — dans l'esprit de Jarvis d'Iron Man. Tourne en local via [Ollama](https://ollama.com), respecte votre vie privée, et contrôle votre Mac (Notes, Rappels, Calendrier, iMessage, AppleScript, etc.).

## Prérequis

- **macOS 14+** (Sonoma)
- **Xcode 15+** — pour compiler depuis les sources
- **Ollama** installé et lancé (`ollama serve`) avec un modèle compatible :

```bash
ollama pull gemma4    # recommandé
ollama pull llama3.2  # alternative plus légère
```

- **edge-tts** (optionnel) — voix TTS de meilleure qualité :

```bash
pip install edge-tts
```

## Installation

```bash
git clone https://github.com/dimitricl/jarvis-local.git
cd JarvisLocal
./run.sh
```

Le script compile le projet, injecte la version depuis le dernier tag git, copie l'application dans `/Applications` et la lance. Pour une version release optimisée :

```bash
./run.sh --release
```

## Utilisation

| Action                | Raccourci / Méthode                    |
|-----------------------|----------------------------------------|
| Envoyer un message    | `Cmd + Entrée` (ou bouton ➚)          |
| Nouvelle ligne        | `Entrée`                               |
| Mode vocal            | Cliquez sur 🎤                         |
| Vider l'historique    | Tapez `/clear`                         |
| Gérer les faits       | Tapez `/facts`                         |
| Vérifier les mises à jour | Réglages > Mise à jour             |
| Quitter le mode vocal | Bouton rouge "Quitter"                 |

### Fonctionnalités

- **Chat local** avec Ollama — aucune donnée envoyée sur le cloud
- **23+ outils** : recherche web (DuckDuckGo), lecture d'URL, Apple Notes, Rappels, Calendrier, iMessage, presse-papiers, capture d'écran, AppleScript, Raccourcis, Sleep du Mac, etc.
- **Mémoire persistante** (`/facts`) — Jarvis retient vos informations personnelles entre les sessions
- **Mode vocal mains-libres** — reconnaissance Apple Speech + synthèse (AVSpeechSynthesizer ou edge-tts)
- **Barge-in** — interrompez Jarvis pendant qu'il parle
- **Sécurité** — confirmation avant toute action sensible (écriture, envoi, AppleScript)
- **Mise à jour intégrée** — détection automatique des nouvelles releases GitHub
- **CI/CD** — GitHub Actions compile et teste chaque commit

## Sécurité : tests des outils sensibles

Les outils à effet de bord sont protégés par une **double vérification** automatique :

1. `testSensitiveToolsHaveConfirmationInViewModel()` : lit la vraie liste `sensitiveTools` (rendue `internal`) du ViewModel et vérifie que chaque outil existe dans `ToolService`
2. `testKnownSideEffectToolsAreAllMarkedSensitive()` : liste explicitement tous les outils à effet de bord connus ; si un nouvel outil est ajouté sans être classé "sensible", le test échoue

Cela évite la dérive silencieuse entre la liste réelle et une copie obsolète dans les tests.

## Architecture

MVVM avec `actor` Swift pour la sécurité des threads :

```
JarvisLocal/
├── Models/          # Structures de données (Message, Conversation, Fact, ToolDef)
├── ViewModels/      # Logique métier (AppViewModel)
├── Views/           # Interface SwiftUI (ChatView, SettingsView, InputBarView)
├── Services/        # Services système (Ollama, STT, Tool, Database)
└── Helpers/         # Extensions et utilitaires
```

### Services

| Service           | Type     | Rôle                                    |
|-------------------|----------|-----------------------------------------|
| `OllamaService`   | `actor`  | Communication avec Ollama (stream + tools) |
| `ToolService`     | `actor`  | Définition et exécution des outils      |
| `DatabaseService` | `actor`  | SQLite (conversations, messages, faits) |
| `STTService`      | class    | Reconnaissance vocale Apple Speech      |
| `AudioService`    | class    | Synthèse vocale (TTS)                   |

## Développement

### Tests

```bash
cd JarvisLocal
swift test
```

45 tests couvrent : modèles, base de données, appels Ollama, outils et sécurité.

### Ajouter un outil

1. Déclarez le `ToolDef` dans `ToolService.toolDefs`
2. Implémentez la méthode dans `executeTool()`
3. Ajoutez le nom dans `sensitiveTools` du `AppViewModel` s'il a un effet de bord
4. Mettez à jour l'invariant `sideEffectTools` dans les tests

## Release

```bash
# Mettre à jour CHANGELOG.md
git add CHANGELOG.md && git commit -m "Changelog pour vX.Y.Z"
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin main --tags
gh release create vX.Y.Z --title "vX.Y.Z" --notes-file CHANGELOG.md
```

## Licence

MIT
