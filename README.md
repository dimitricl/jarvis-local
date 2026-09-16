# JarvisLocal

[![CI](https://github.com/dimitricl/jarvis-local/actions/workflows/ci.yml/badge.svg)](https://github.com/dimitricl/jarvis-local/actions/workflows/ci.yml)
![macOS](https://img.shields.io/badge/macOS-26+-blue)
![Swift](https://img.shields.io/badge/Swift-6.2-orange)

Ce projet utilise Ollama en local pour le traitement du langage naturel.

Assistant IA personnel pour macOS — dans l'esprit de Jarvis d'Iron Man. Tourne en local via [Ollama](https://ollama.com), respecte votre vie privée, et contrôle votre Mac (Notes, Rappels, Calendrier, iMessage, AppleScript, etc.).

## Prérequis

- **macOS 26+** (Liquid Glass requis pour l'interface)
- **Xcode 26+** — pour compiler depuis les sources
- **Ollama** installé et lancé (`ollama serve`) avec un modèle compatible :

```bash
ollama pull gemma4    # recommandé
ollama pull llama3.2  # alternative plus légère
```

- TTS 100 % on-device (AVSpeechSynthesizer, voix FR Enhanced/Premium via Réglages Système). L'ancien moteur cloud edge-tts a été supprimé.

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
| Audit des outils      | Tapez `/tools` (journal persisté des exécutions) |
| Vérifier les mises à jour | Réglages > Mise à jour             |
| Quitter le mode vocal | Bouton rouge "Quitter"                 |

### Fonctionnalités

- **Chat local** avec Ollama — local par défaut (`http://localhost:11434`). Réseau réel, à connaître :
  - `search_web` → DuckDuckGo (requête envoyée), `get_weather` → Open-Meteo (ville envoyée),
    `read_url` → la page demandée (uniquement http/https publique : localhost, LAN et
    `file://` refusés par le garde anti-SSRF), vérification de mise à jour → api.github.com.
  - Si tu configures une **URL Ollama distante**, tout l'historique et les faits y sont envoyés
    (avertissement affiché dans les Réglages). ATS restreint : seul `localhost` en HTTP est autorisé.
- **23+ outils natifs** : recherche web (cascade API DuckDuckGo → DOM → fallback), lecture d'URL avec citation des sources, météo Open-Meteo, Apple Notes, Rappels, Calendrier, iMessage, presse-papiers, capture d'écran, AppleScript, Raccourcis, Sleep du Mac, etc.
- **Client MCP (opt-in, désactivé par défaut)** : via [iMCP](https://github.com/mattt/iMCP) — calendrier, rappels, contacts et messages en lecture/création. Voir « MCP » ci-dessous.
- **Mémoire persistante** (`/facts`) — Jarvis retient vos informations personnelles entre les sessions
- **Mode vocal mains-libres** — reconnaissance Apple Speech + synthèse 100 % on-device (AVSpeechSynthesizer)
- **Barre de menu + lancement au démarrage** — pilote Jarvis sans fenêtre ouverte
- **Barge-in** — interrompez Jarvis pendant qu'il parle
- **Sécurité** — confirmation avant toute action sensible (écriture, envoi, AppleScript)
- **Mise à jour intégrée** — détection automatique des nouvelles releases GitHub
- **CI/CD** — GitHub Actions compile et teste chaque commit

## Sécurité : tests des outils sensibles

Les outils à effet de bord sont protégés par une **double vérification** automatique :

1. `testSensitiveToolsHaveConfirmationInViewModel()` : lit la vraie liste `sensitiveTools` (rendue `internal`) du ViewModel et vérifie que chaque outil existe dans `ToolService`
2. `testKnownSideEffectToolsAreAllMarkedSensitive()` : liste explicitement tous les outils à effet de bord connus ; si un nouvel outil est ajouté sans être classé "sensible", le test échoue

Cela évite la dérive silencieuse entre la liste réelle et une copie obsolète dans les tests.

## MCP (iMCP, optionnel, désactivé par défaut)

Jarvis peut déléguer Calendrier, Rappels, Contacts et Messages (lecture) au serveur MCP local [iMCP](https://github.com/mattt/iMCP), validé en réel contre iMCP v1.4.1 :

```bash
brew install --cask mattt/tap/iMCP
```

Puis : ouvrez iMCP, activez chaque service (menu bar), approuvez JarvisLocal (« Always trust this client »), et cochez **Réglages > MCP > Activer MCP** dans Jarvis (redémarrez l'app). Le chemin du serveur est résolu automatiquement (`/Applications/iMCP.app/Contents/MacOS/imcp-server`), modifiable dans le même panneau.

Délégués quand MCP est en ligne : `events_create`, `events_fetch`, `calendars_list`, `reminders_*`, `contacts_search` (les équivalents natifs sont alors masqués au modèle, mais restent en fallback). **Restent toujours natifs** : envoi iMessage (`send_message`, iMCP = lecture seule), `search_maps`, `sleep_mac`, `applescript`, captures, presse-papiers, `search_web`.

> Si `reminders_*` répond « not authorized » alors que tout est coché : quittez et relancez iMCP (`killall iMCP`) — la permission accordée n'est parfois pas effective dans le process en cours.

## Architecture

MVVM avec `actor` Swift pour la sécurité des threads :

```
JarvisLocal/
├── Models/          # Structures de données (Message, Conversation, Fact, ToolDef)
├── ViewModels/      # Logique métier (AppViewModel + FactExtractor pur)
├── Views/           # Interface SwiftUI (ChatView, SettingsView, InputBarView)
├── Services/        # Ollama, STT, Database, ToolService (façade), Tools/ (par domaine), Web/, MCP/
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
| `MCPToolProvider` | `actor`  | Client MCP stdio (iMCP, opt-in)         |
| `WebSearchService`| `actor`  | Recherche web cascade (API → DOM → regex) |

Les outils sont découpés par domaine (`Services/Tools/` : Calendar, Reminders,
Messaging, System, Web, Notes, Memory) derrière un seul point d'entrée
`ToolService.execute(name:args:)` ; la liste envoyée à Ollama fusionne le natif
et les outils MCP distants quand iMCP est connecté (`effectiveToolDefs()`).

## Legacy (ancien prototype, non maintenu)

Le dossier `legacy/` contient le premier prototype Bun/TypeScript (`server.ts`,
`public/`, `memory.db`) — conservé **à titre d'archive historique uniquement**.
Il n'est ni compilé ni testé par la CI (seule `JarvisLocal/` l'est : `swift build`
/ `swift test` depuis `JarvisLocal/`). Les correctifs et les nouvelles
fonctionnalités vont dans l'app Swift, pas ici. Voir `legacy/README.md` pour le
relancer (`bun run server.ts`). `node_modules/` n'est pas versionné.

## Développement

### Tests

```bash
cd JarvisLocal
swift test
```

251 tests couvrent : modèles, base de données, appels Ollama, recherche web (DOM + fallback), routage des outils, extraction de faits, client MCP (sans binaire réel) et sécurité.

### Ajouter un outil

1. Déclarez le `ToolDef` dans `ToolService.toolDefs`
2. Implémentez la logique dans le sous-service du domaine (`Services/Tools/`) et routez-la dans `execute(name:args:)` (point d'entrée unique)
3. Ajoutez le nom dans `sensitiveTools` du `AppViewModel` s'il a un effet de bord
4. Mettez à jour l'invariant `sideEffectTools` dans les tests

## Release

```bash
# 1. Documenter la version aux DEUX endroits (le hook CI l'exige)
# 2. Vérifier : sh JarvisLocal/Scripts/check-changelog.sh vX.Y.Z
git add CHANGELOG.md JarvisLocal/CHANGELOG.md && git commit -m "Changelog pour vX.Y.Z"
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin main --tags
gh release create vX.Y.Z --title "vX.Y.Z" --notes-file CHANGELOG.md
```

Un tag poussé sans entrée CHANGELOG correspondante fait échouer la CI (`changelog-guard.yml`).

## Licence

MIT
