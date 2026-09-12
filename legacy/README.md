# Legacy — prototype Bun/TypeScript (archivé, non maintenu)

> **Le projet actif est l'app native Swift/SwiftUI dans `../JarvisLocal/`**
> (compilée et testée par la CI : `swift build` / `swift test` depuis `JarvisLocal/`).
> Ce dossier n'est ni compilé ni testé par la CI — il est conservé à titre d'archive
> pour l'historique (première itération de Jarvis : serveur Bun + WebSocket + `public/index.html`).

## Contenu

| Fichier | Rôle d'origine |
|---|---|
| `server.ts` | Serveur Bun : WebSocket, SQLite (`memory.db`), outils, TTS, appels Ollama |
| `public/index.html` | Client web du prototype |
| `package.json` / `bun.lock` | Dépendances Bun |
| `tsconfig.json` | Config TypeScript |
| `.env` / `.env.example` | Config locale du prototype (URL Ollama, modèle, voix TTS…) |
| `memory.db` / `memory.db.bak` | Base SQLite du prototype |
| `node_modules/` | Dépendances installées (relançable sans `bun install`) |

## Relancer le prototype (si besoin)

```bash
cd legacy
cp .env.example .env   # ou réutiliser le .env déjà présent
bun run server.ts      # écoute sur $PORT (3000 par défaut)
```

Nécessite [Bun](https://bun.sh), Ollama en local (`ollama serve`), et `edge-tts`
pour la synthèse vocale. Sans garantie : les correctifs et les nouvelles
fonctionnalités vont dans l'app Swift, pas ici.
