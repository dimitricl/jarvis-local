# Setup serveur d'inférence (Mac mini M4)

Le maintien en mémoire est une responsabilité du **serveur**, pas d'un ping
client (le keep-alive client toutes les 4 min est supprimé en phase 3 : coût
réseau, inefficace quand le client dort).

## Config Ollama recommandée

```bash
# Garder le modèle chargé en permanence (pas d'expiration) :
OLLAMA_KEEP_ALIVE=-1
# Lier à l'interface Tailscale UNIQUEMENT, jamais 0.0.0.0 :
OLLAMA_HOST=<interface-tailscale-uniquement>
# Contexte max tenable (mesuré via /api/ps, cf. eval-baseline) :
# OLLAMA_CONTEXT_LENGTH / num_ctx par requête, puis vérifier
# context_length réel (tronqué silencieusement au-delà du possible).
OLLAMA_FLASH_ATTENTION=1
```

Les valeurs d'hôte/adresses passent par l'environnement de la machine
serveur — **jamais** dans le repo (ni code, ni docs, ni YAML).

## Service permanent

- Service `launchd` (`KeepAlive`, `RunAtLoad`) pour Ollama.
- Empêcher la veille (`caffeinate` / réglages Énergie) : une mise en veille
  rend le lien indisponible — état normal côté client (`serveur
  injoignable`, mode dégradé local), mais à éviter en usage nominal.

## Côté client (phase 3)

- Au lancement et sur événement réseau : **un** préchauffage si le modèle
  n'est pas résident (`GET /api/ps`), pas de boucle de ping.
- Timeouts distincts : connexion court (~3 s), premier token long
  (chargement à froid), inter-tokens court. Un timeout n'est jamais un échec
  silencieux.
- Si un reverse proxy avec jeton est placé devant Ollama, le jeton passe en
  en-tête configuré (réglages/Keychain), jamais dans le repo.
