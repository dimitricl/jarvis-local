# JarvisLocal

Assistant IA personnel pour macOS, 100% local — dans l'esprit du JARVIS d'Iron Man.

## Prérequis

- macOS 14.0+
- [Ollama](https://ollama.ai) avec un modèle compatible (gemma4, llama3, etc.)
- Optionnel : `edge-tts` pour la synthèse vocale améliorée (`pip install edge-tts`)

## Installation

```bash
git clone https://github.com/dimitricl/jarvis-local.git
cd jarvis-local/JarvisLocal
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
- MCP (optionnel, désactivé par défaut) : iMCP pour Calendrier/Rappels/Contacts/Messages — voir « MCP » ci-dessous

## MCP (iMCP, optionnel)

```bash
brew install --cask mattt/tap/iMCP
```

Activez les services dans l'app iMCP (menu bar), approuvez JarvisLocal, puis cochez **Réglages > MCP > Activer MCP** et redémarrez. Délégués : calendrier, rappels, recherche de contacts ; restent natifs : envoi iMessage, Plans, AppleScript, captures, presse-papiers, recherche web. Si les rappels répondent « not authorized » malgré les cases cochées : quittez et relancez iMCP.

## Fonctionnalités

- Chat avec LLM local (outils : recherche web, météo, Apple Notes, Rappels, Calendrier, iMessage, Shortcuts, etc.)
- Mémoire de faits personnels (reconnus automatiquement, confirmés par l'utilisateur)
- Mode vocal mains-libres avec barge-in
- Recherche plein-texte dans toutes les conversations (`/search` ou bouton loupe)
- Export de conversation en Markdown ou JSON
- Routines (ex. routine "morning" : météo + calendrier + infos système)
- Capture d'écran, presse-papiers, recherche Spotlight
- Contrôle du Mac (veille, verrouillage, extinction, redémarrage)

### Commandes slash

| Commande | Effet |
|---|---|
| `/help` | Affiche la liste des commandes |
| `/clear` | Nouvelle conversation |
| `/facts` | Affiche/masque la mémoire de faits |
| `/search <texte>` | Recherche dans toutes les conversations |
| `/export md` | Exporte la conversation courante en Markdown |
| `/export json` | Exporte la conversation courante en JSON |

## Architecture

```
JarvisLocal/
├── Models/        # Structures de données (Message, Conversation, Tool, Fact)
├── ViewModels/    # Logique métier (AppViewModel + FactExtractor pur)
├── Services/      # Ollama, ToolService (façade), Tools/ (par domaine), Web/, MCP/, SQLite, audio, settings
├── Helpers/       # Thème, extensions, utilitaires
└── Views/         # Interface SwiftUI
```

## Tests

```bash
swift test
```

251 tests couvrant : modèles, base de données, services (Ollama, recherche web, tools, audio, STT, MCP sans binaire réel), ViewModel (conversations, extraction de faits, recherche, export) et sécurité des outils sensibles.

## Licence

Voir LICENSE.
