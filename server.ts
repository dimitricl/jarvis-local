import { Database } from "bun:sqlite";
import type { ServerWebSocket } from "bun";

// ─── Sécurité : crash silencieux → log ──────────────────────────────────────
process.on("unhandledRejection", (err) => {
  console.error("[FATAL] Unhandled Rejection:", err);
});
process.on("uncaughtException", (err) => {
  console.error("[FATAL] Uncaught Exception:", err);
});

// ─── Config ─────────────────────────────────────────────────────────────────
const OLLAMA_URL   = process.env.OLLAMA_URL   ?? "http://100.101.108.111:11434/v1/chat/completions";
const MODEL        = process.env.MODEL        ?? "gemma4:e4b";
const MODEL_FAST   = process.env.MODEL_FAST   ?? "gemma4:e2b";
const PORT         = parseInt(process.env.PORT ?? "3000");
const EDGE_TTS_BIN = process.env.EDGE_TTS_BIN ?? "/Users/dimitriclaverie/.local/share/mise/installs/python/3.13.3/bin/edge-tts";
const TTS_VOICE    = process.env.TTS_VOICE    ?? "fr-FR-HenriNeural";
const TTS_RATE     = process.env.TTS_RATE     ?? "+5%";
const MAX_MSG_LENGTH = 100_000;
const RATE_LIMIT_WINDOW_MS = 2000;
const TTS_TEMP_PREFIX = "/tmp/jarvis_tts_";

const ddgsCheck = Bun.spawnSync(["python3", "-c", "from ddgs import DDGS"]);
if (ddgsCheck.exitCode !== 0) {
  console.warn("[WARN] ddgs non installé — pip3 install duckduckgo-search --break-system-packages");
}

// ─── Base de données ─────────────────────────────────────────────────────────
const db = new Database("memory.db");
db.run(`CREATE TABLE IF NOT EXISTS conversations (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  title      TEXT    NOT NULL DEFAULT 'Nouvelle conversation',
  created_at INTEGER DEFAULT (unixepoch()),
  updated_at INTEGER DEFAULT (unixepoch())
)`);
db.run(`CREATE TABLE IF NOT EXISTS messages (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  role            TEXT    NOT NULL,
  content         TEXT    NOT NULL,
  conversation_id INTEGER REFERENCES conversations(id),
  created_at      INTEGER DEFAULT (unixepoch())
)`);
db.run(`CREATE TABLE IF NOT EXISTS facts (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  key        TEXT    UNIQUE,
  value      TEXT,
  updated_at INTEGER DEFAULT (unixepoch())
)`);

try { db.run("ALTER TABLE messages ADD COLUMN conversation_id INTEGER REFERENCES conversations(id)"); } catch {}

const convCount = db.query("SELECT COUNT(*) as c FROM conversations").get() as { c: number };
if (convCount.c === 0) {
  db.run("INSERT INTO conversations (id, title) VALUES (1, 'Général')");
  db.run("UPDATE messages SET conversation_id = 1 WHERE conversation_id IS NULL");
}

// ─── Helpers ─────────────────────────────────────────────────────────────────
const esc = (s: string) => s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n");

async function runOsascript(script: string, label = "AppleScript"): Promise<string> {
  const proc = Bun.spawn(["osascript", "-e", script], { stdout: "pipe", stderr: "pipe" });
  await proc.exited;
  const out = await new Response(proc.stdout).text();
  const err = await new Response(proc.stderr).text();
  if (err.trim()) return `Erreur ${label} : ${err.trim()}`;
  return out.trim() || `${label} exécuté avec succès.`;
}

interface MessageRow {
  role: string;
  content: string;
}

interface FactRow {
  key: string;
  value: string;
}

interface ConvRow {
  id: number;
  title: string;
  created_at: number;
  updated_at: number;
}

interface RateLimitState {
  count: number;
  resetAt: number;
}

// ─── TTS par connexion ───────────────────────────────────────────────────────
interface TTSState {
  proc: ReturnType<typeof Bun.spawn> | null;
  shouldStop: boolean;
}

const ttsStates = new Map<ServerWebSocket, TTSState>();

function getTTSState(ws: ServerWebSocket): TTSState {
  let state = ttsStates.get(ws);
  if (!state) {
    state = { proc: null, shouldStop: false };
    ttsStates.set(ws, state);
  }
  return state;
}

function stopTTS(ws: ServerWebSocket) {
  const state = getTTSState(ws);
  state.shouldStop = true;
  if (state.proc) {
    try { state.proc.kill(); } catch {}
    state.proc = null;
  }
}

function cleanupTTS(ws: ServerWebSocket) {
  const state = ttsStates.get(ws);
  if (state?.proc) {
    try { state.proc.kill(); } catch {}
  }
  ttsStates.delete(ws);
}

let ttsFileCounter = 0;
function nextTTSFile(): string {
  ttsFileCounter = (ttsFileCounter + 1) % 1000;
  return `${TTS_TEMP_PREFIX}${Date.now()}_${ttsFileCounter}.mp3`;
}

function normalizeText(text: string): string {
  let t = text
    .replace(/\bM\. /g, "Monsieur ")
    .replace(/\bMme\b/g, "Madame")
    .replace(/\bMlles?\b/g, "Mademoiselle")
    .replace(/\bDr\.? /g, "Docteur ")
    .replace(/\bPr\.? /g, "Professeur ")
    .replace(/\bvs\.? /g, "versus ")
    .replace(/\bn°\s*/gi, "numéro ")
    .replace(/\bex\.? /g, "exemple ")
    .replace(/€/g, " euros")
    .replace(/%/g, " pour cent")
    .replace(/&/g, " et ")
    .replace(/\+/g, " plus ")
    .replace(/≈|≃/g, " environ ")
    .replace(/≠/g, " différent de ")
    .replace(/\//g, " sur ")
    .replace(/</g, " moins de ")
    .replace(/>/g, " plus de ")
    .replace(/https?:\/\/\S+/g, "")
    .replace(/www\.\S+/g, "")
    .replace(/[\u{1F600}-\u{1F64F}\u{1F300}-\u{1F5FF}\u{1F680}-\u{1F6FF}\u{1F1E0}-\u{1F1FF}\u{2600}-\u{27BF}]/gu, "");
  return t;
}

function splitSentences(text: string, maxLen = 350): string[] {
  const raw = text.match(/[^.!?]+[.!?]?/g) ?? [text];
  const chunks: string[] = [];
  let buf = "";
  for (const s of raw) {
    if ((buf + s).length > maxLen && buf.trim()) {
      chunks.push(buf.trim());
      buf = s;
    } else {
      buf += s;
    }
  }
  if (buf.trim()) chunks.push(buf.trim());
  return chunks.length ? chunks : [text];
}

async function speak(text: string, ws: ServerWebSocket) {
  const state = getTTSState(ws);
  state.shouldStop = false;
  ws.send(JSON.stringify({ type: "tts_start" }));

  let clean = text
    .replace(/<think>[\s\S]*?<\/think>/g, "")
    .replace(/[`*#_~]/g, "")
    .replace(/#{1,6}\s+/g, "")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/\*([^*]+)\*/g, "$1")
    .replace(/^\s*[\*\-\d+\.]+\s+/gm, "")
    .replace(/\n+/g, " ")
    .trim();

  if (!clean) {
    ws.send(JSON.stringify({ type: "tts_done" }));
    return;
  }

  clean = normalizeText(clean);
  const chunks = splitSentences(clean, 350);
  console.log(`[tts] ${chunks.length} chunk(s) pour ${clean.length} chars`);

  for (const chunk of chunks) {
    if (state.shouldStop || !chunk.trim()) continue;
    const tmpFile = nextTTSFile();
    state.proc = Bun.spawn([EDGE_TTS_BIN, "--voice", TTS_VOICE, "--rate", TTS_RATE, "--text", chunk, "--write-media", tmpFile]);
    await state.proc.exited;
    if (state.shouldStop) break;
    state.proc = Bun.spawn(["afplay", tmpFile]);
    await state.proc.exited;
  }

  state.proc = null;
  ws.send(JSON.stringify({ type: "tts_done" }));
}

// ─── Outils ──────────────────────────────────────────────────────────────────
const TOOLS = [
  {
    type: "function" as const,
    function: {
      name: "search_web",
      description: "Recherche sur le web. À utiliser pour : actualités, prix, météo, événements récents, données chiffrées, infos sur des personnes/entreprises/produits réels.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "La requête de recherche" }
        },
        required: ["query"]
      }
    }
  },
  {
    type: "function" as const,
    function: {
      name: "open_app",
      description: "Ouvre une application sur le Mac. Pour Messages, met le prénom dans url pour ouvrir la conversation.",
      parameters: {
        type: "object",
        properties: {
          app: { type: "string", description: "Nom exact de l'application (ex: Safari, Spotify, Messages)" },
          url: { type: "string", description: "Pour Messages : le prénom de la personne (ex: \"Valentine\"). Sinon : URL web (ex: \"https://...\"). (optionnel)" }
        },
        required: ["app"]
      }
    }
  },
  {
    type: "function" as const,
    function: {
      name: "create_note",
      description: "Crée une NOUVELLE note dans Apple Notes. Pour MODIFIER une note existante, utilise edit_note.",
      parameters: {
        type: "object",
        properties: {
          title: { type: "string", description: "Titre de la note" },
          body: { type: "string", description: "Contenu de la note" }
        },
        required: ["title", "body"]
      }
    }
  },
  {
    type: "function" as const,
    function: {
      name: "edit_note",
      description: "MODIFIE une note existante dans Apple Notes. Cherche par titre (partiel) et remplace le contenu. Peut aussi renommer la note si new_title est fourni.",
      parameters: {
        type: "object",
        properties: {
          search_title: { type: "string", description: "Titre (ou partie du titre) de la note à modifier" },
          body: { type: "string", description: "Nouveau contenu de la note" },
          new_title: { type: "string", description: "Nouveau titre (optionnel — si fourni, renomme la note)" }
        },
        required: ["search_title", "body"]
      }
    }
  },
  {
    type: "function" as const,
    function: {
      name: "applescript",
      description: "Exécute un script AppleScript pour contrôler des applications macOS (Safari, Mail, Finder, etc.). Pour les actions simples sur Notes/Calendrier/Rappels, préfère les outils dédiés.",
      parameters: {
        type: "object",
        properties: {
          script: { type: "string", description: "Le code AppleScript à exécuter" }
        },
        required: ["script"]
      }
    }
  },
  {
    type: "function" as const,
    function: {
      name: "add_reminder",
      description: "Ajoute un rappel dans l'application Rappels d'Apple. Date au format DD/MM/YYYY.",
      parameters: {
        type: "object",
        properties: {
          title: { type: "string", description: "Texte du rappel" },
          notes: { type: "string", description: "Notes supplémentaires (optionnel)" },
          due_date: { type: "string", description: "Date d'échéance au format DD/MM/YYYY (optionnel)" },
          due_time: { type: "string", description: "Heure d'échéance au format HH:MM (optionnel, défaut 23:59)" }
        },
        required: ["title"]
      }
    }
  },
  {
    type: "function" as const,
    function: {
      name: "add_calendar_event",
      description: "Ajoute un événement dans l'application Calendrier d'Apple. Calendriers : Personnel, Travail, Calendrier, ou nom du compte iCloud. Date au format DD/MM/YYYY.",
      parameters: {
        type: "object",
        properties: {
          title: { type: "string", description: "Titre de l'événement" },
          date: { type: "string", description: "Date au format DD/MM/YYYY" },
          start_time: { type: "string", description: "Heure de début au format HH:MM (optionnel, défaut 09:00)" },
          duration_minutes: { type: "number", description: "Durée en minutes (optionnel, défaut 60)" },
          notes: { type: "string", description: "Notes de l'événement (optionnel)" },
          location: { type: "string", description: "Adresse complète du lieu (optionnel)" },
          calendar: { type: "string", description: "Nom du calendrier (optionnel)" }
        },
        required: ["title", "date"]
      }
    }
  },
  {
    type: "function" as const,
    function: {
      name: "get_calendars",
      description: "Liste les calendriers disponibles (nom et type). Utile avant add_calendar_event.",
      parameters: {
        type: "object",
        properties: {},
        required: []
      }
    }
  },
  {
    type: "function" as const,
    function: {
      name: "search_maps",
      description: "Recherche un lieu dans Plans (Apple Maps). Retourne l'adresse complète à passer dans add_calendar_event(location=...).",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string", description: "Recherche (nom du lieu, adresse, 'domicile', 'travail')" }
        },
        required: ["query"]
      }
    }
  },
  {
    type: "function" as const,
    function: {
      name: "run_shortcut",
      description: "Exécute un Raccourci macOS (Shortcuts) et retourne son résultat.",
      parameters: {
        type: "object",
        properties: {
          name: { type: "string", description: "Nom exact du raccourci" }
        },
        required: ["name"]
      }
    }
  }
];

function toolDescriptions(): string {
  return TOOLS.map(t => {
    const f = t.function as { name: string; description: string; parameters: { required: string[] } };
    const required = f.parameters.required?.length ? ` (requis: ${f.parameters.required.join(", ")})` : "";
    return `• ${f.name} → ${f.description}${required}`;
  }).join("\n");
}

function htmlToText(html: string): string {
  let text = html
    .replace(/<script[^>]*>[\s\S]*?<\/script>/gi, "")
    .replace(/<style[^>]*>[\s\S]*?<\/style>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|h[1-6]|li|div|tr|blockquote|section|article|td|th)>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&#(\d+);/g, (_, c) => String.fromCharCode(parseInt(c)))
    .replace(/^[ \t]+/gm, "")
    .replace(/\n{3,}/g, "\n\n")
    .replace(/[ \t]{2,}/g, " ")
    .trim();
  const lines = text.split("\n").filter(l => l.trim().length > 2);
  return lines.slice(0, 80).join("\n").slice(0, 6000);
}

async function searchWeb(query: string): Promise<string> {
  try {
    const proc = Bun.spawn(
      ["python3", "-c",
`import sys, json
try:
    from ddgs import DDGS
    results = list(DDGS().text(${JSON.stringify(query)}, max_results=5))
    out = [{"title": r.get("title",""), "body": r.get("body","")[:300], "href": r.get("href","")} for r in results] if results else []
    print(json.dumps(out))
except Exception as e:
    print(json.dumps([f"Erreur: {e}"]))
`],
      { stdout: "pipe", stderr: "pipe" }
    );
    await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    if (stderr.trim()) console.log("[search stderr]", stderr.trim());
    const raw = (await new Response(proc.stdout).text()).trim();
    let results: { title: string; body: string; href: string }[];
    try { results = JSON.parse(raw); }
    catch { return raw || "Aucun résultat."; }

    if (!Array.isArray(results) || results.length === 0) return "Aucun résultat.";
    if (typeof results[0] === "string") return (results as unknown as string[]).join("\n");

    const lines: string[] = [];
    const pageResults = results.slice(0, 2);
    for (const r of pageResults) {
      lines.push(`--- ${r.title} ---`);
      if (r.body) lines.push(`Résumé : ${r.body}`);
      if (r.href) {
        try {
          const pageResp = await fetch(r.href, { signal: AbortSignal.timeout(5000) });
          if (pageResp.ok) {
            const pageHtml = await pageResp.text();
            const content = htmlToText(pageHtml);
            if (content.length > 100) {
              lines.push(`Contenu : ${content}`);
            }
          }
        } catch {
          lines.push(`(page non accessible)`);
        }
      }
      lines.push("");
    }
    return lines.join("\n").trim() || "Aucun résultat trouvé.";
  } catch (err) {
    return `Erreur recherche : ${err}`;
  }
}

async function openApp(app: string, url?: string): Promise<string> {
  try {
    const normalize = (s: string) => s.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");
    const nameMap: Record<string, string> = {
      "meteo": "Weather", "weather": "Weather",
      "calendrier": "Calendar", "calendar": "Calendar",
      "notes": "Notes", "mail": "Mail", "safari": "Safari",
      "chrome": "Google Chrome", "spotify": "Spotify",
      "telephone": "FaceTime", "facetime": "FaceTime",
      "messages": "Messages", "contacts": "Contacts",
      "musique": "Music", "music": "Music", "photos": "Photos",
      "reglages": "System Settings", "terminal": "Terminal",
      "finder": "Finder", "carte": "Maps", "maps": "Maps",
      "maison": "Home", "home": "Home"
    };
    const resolved = nameMap[normalize(app)] || app;
    const normalizedApp = normalize(app);

    // Messages : si on demande une conversation, essayer par AppleScript
    if (normalizedApp === "messages" && url && /^[a-zA-ZÀ-ÿ\s\-']{1,50}$/.test(url.trim())) {
      try {
        const contactName = url.trim();
        const lowName = contactName.toLowerCase();
        const asScript = `tell application "Messages"\nactivate\nset targetService to 1st service whose service type = iMessage\nset found to false\nset resultMsg to ""\nrepeat with c in chats of targetService\ntry\nset partName to name of participant 1 of c\nset partId to id of participant 1 of c\nset matchName to ((partName) contains "${esc(contactName)}") or ((partName) contains "${esc(lowName)}")\nset matchId to ((partId) contains "${esc(contactName)}") or ((partId) contains "${esc(lowName)}")\nif matchName or matchId then\nopen c\nset found to true\nexit repeat\nend if\nend try\nend repeat\nif found then\nreturn "Conversation avec ${esc(contactName)} ouverte dans Messages."\nelse\nreturn "Conversation avec ${esc(contactName)} introuvable. Vérifie le prénom exact dans Messages."\nend if\nend tell`;
        const asResult = await runOsascript(asScript);
        return asResult;
      } catch {}
    }

    const args = ["-a", resolved];
    if (url) {
      if (typeof url !== "string" || url.length > 2000 || /[;|&$`]/.test(url)) {
        return `URL invalide refusée : contient des caractères dangereux.`;
      }
      const hasProtocol = /^[a-z][a-z0-9+\-.]*:\/\//i.test(url);
      args.push(hasProtocol ? url : `https://${url}`);
    }
    const proc = Bun.spawn(["open", ...args], { stdout: "pipe", stderr: "pipe" });
    await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    if (stderr.trim()) return `Erreur : ${stderr.trim()}`;
    return url ? `${resolved} ouvert sur ${url}.` : `${resolved} ouvert.`;
  } catch (err) {
    return `Impossible d'ouvrir ${app} : ${err}`;
  }
}

function flattenForSecurityCheck(script: string): string {
  return script.toLowerCase().replace(/["'\s&]/g, "");
}

const APPLESCRIPT_FORBIDDEN_PATTERNS = [
  /doshellscript/,
  /withadministratorprivileges/,
  /systemevents.*keystroke/,
  /systemevents.*keycode/,
  /runscript/,
  /dojavascript/,
];

async function runAppleScript(script: string): Promise<string> {
  const flat = flattenForSecurityCheck(script);
  const hit = APPLESCRIPT_FORBIDDEN_PATTERNS.find(p => p.test(flat));
  if (hit) {
    console.warn(`[SECURITY] Script AppleScript refusé (pattern ${hit}) : ${script.slice(0, 200)}`);
    return "Script refusé : commande shell, élévation de privilèges, exécution de code dynamique ou simulation de saisie clavier détectée.";
  }
  try {
    return await runOsascript(script);
  } catch (err) {
    return `Erreur AppleScript : ${err}`;
  }
}

async function createNote(title: string, body: string): Promise<string> {
  try {
    let cleanBody = body;
    if (cleanBody.trim().toLowerCase().startsWith(title.trim().toLowerCase()))
      cleanBody = cleanBody.trim().slice(title.trim().length).trim();
    const script = `tell application "Notes"\nset n to make new note with properties {name:"${esc(title)}", body:"${esc(cleanBody)}"}\nshow n\nend tell`;
    return await runOsascript(script, "Notes");
  } catch (err) {
    return `Erreur Notes : ${err}`;
  }
}

async function editNote(searchTitle: string, body: string, newTitle?: string): Promise<string> {
  try {
    let script = `tell application "Notes"\nset foundNote to missing value\nrepeat with acc in accounts\nrepeat with f in folders of acc\ntry\nset matchingNote to first note of f whose name contains "${esc(searchTitle)}"\nset foundNote to matchingNote\nexit repeat\nend try\nend repeat\nif foundNote is not missing value then exit repeat\nend repeat\nif foundNote is missing value then return "Note introuvable avec le titre : ${esc(searchTitle)}"`;
    if (newTitle) {
      script += `\nset name of foundNote to "${esc(newTitle)}"`;
    }
    script += `\nset body of foundNote to "${esc(body)}"\nshow foundNote\nreturn "Note mise à jour."\nend tell`;
    return await runOsascript(script, "Notes");
  } catch (err) {
    return `Erreur modification note : ${err}`;
  }
}

function isValidDate(d: number, m: number, y: number): boolean {
  if (!Number.isInteger(d) || !Number.isInteger(m) || !Number.isInteger(y)) return false;
  if (m < 1 || m > 12) return false;
  const daysInMonth = [31, (y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0)) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  return d >= 1 && d <= daysInMonth[m - 1]!;
}

function appleScriptDate(parts: { day?: number; month?: number; year?: number; hour?: number; minute?: number }): string {
  const d = parts.day ?? 1, m = parts.month ?? 1, y = parts.year ?? 2026;
  const h = parts.hour ?? 9, mn = parts.minute ?? 0;
  return `set _d to current date\nset day of _d to 1\nset year of _d to ${y}\nset month of _d to ${m}\nset day of _d to ${d}\nset time of _d to (${h} * hours + ${mn} * minutes)`;
}

async function addReminder(title: string, notes?: string, dueDate?: string, dueTime?: string): Promise<string> {
  try {
    let script = `tell application "Reminders"\n`;
    script += `set r to make new reminder with properties {name:"${esc(title)}"`;
    if (notes) script += `, body:"${esc(notes)}"`;
    script += `}\n`;
    if (dueDate) {
      const [dd, mm, yy] = dueDate.split("/").map(Number);
      if (dd === undefined || mm === undefined || yy === undefined || !isValidDate(dd, mm, yy)) {
        return `Date invalide : "${dueDate}" n'existe pas dans le calendrier.`;
      }
      const [h, mn] = (dueTime ?? "23:59").split(":").map(Number);
      script += `${appleScriptDate({ day: dd, month: mm, year: yy, hour: h, minute: mn })}\n`;
      script += `set due date of r to _d\n`;
    }
    script += `end tell`;
    const proc = Bun.spawn(["osascript", "-e", script], { stdout: "pipe", stderr: "pipe" });
    await proc.exited;
    const err = await new Response(proc.stderr).text();
    if (err.trim()) return `Erreur Rappels : ${err.trim()}`;
    return `Rappel "${title}" créé${notes ? " avec notes" : ""}${dueDate ? ` pour le ${dueDate}` : ""}.`;
  } catch (err) {
    return `Erreur Rappels : ${err}`;
  }
}

async function addCalendarEvent(title: string, date: string, startTime?: string, durationMinutes?: number, notes?: string, calendar?: string, location?: string): Promise<string> {
  try {
    const now = new Date();
    let [dd, mm, yy] = date.split("/").map(Number);
    if (!yy) yy = now.getFullYear();
    if (yy < now.getFullYear() || yy > now.getFullYear() + 5) yy = now.getFullYear();
    if (dd === undefined || mm === undefined || yy === undefined || !isValidDate(dd, mm, yy)) {
      return `Date invalide : "${date}" n'existe pas dans le calendrier.`;
    }
    const [h, mn] = (startTime ?? "09:00").split(":").map(Number);
    const dur = durationMinutes ?? 60;

    let calExpr = `(first calendar whose writable is true)`;
    if (calendar) {
      const calName = calendar.trim();
      const names = (await runOsascript(`tell application "Calendar"\nset names to ""\nrepeat with c in (every calendar whose writable is true)\nset names to names & name of c & "\n"\nend repeat\nreturn names\nend tell`)).split("\n").filter(Boolean);
      const lower = (s: string) => s.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");
      const search = lower(calName);
      const searches = [search];
      for (const p of ["calendrier ", "calendar "]) {
        if (search.startsWith(p)) searches.push(search.slice(p.length).trim());
      }
      let best: { name: string; score: number } = { name: "", score: 0 };
      for (const name of names) {
        const ln = lower(name);
        for (const s of searches) {
          let score = 0;
          if (ln === s) score = 4;
          else if (ln.includes(s)) score = 3;
          else {
            const sw = s.split(/\s+/);
            const nw = ln.split(/\s+/);
            for (const w of sw) { if (nw.includes(w)) { score = Math.max(score, 2); } }
          }
          if (score > best.score) best = { name, score };
        }
      }
      if (!best.name) return `Calendrier "${calName}" introuvable.`;
      calExpr = `calendar "${esc(best.name)}"`;
    }

    const script = `tell application "Calendar"\n${appleScriptDate({ day: dd, month: mm, year: yy, hour: h, minute: mn })}\nset startD to _d\nset endD to startD + (${dur} * minutes)\nset c to ${calExpr}\nset e to make new event at end of events of c with properties {summary:"${esc(title)}", start date:startD, end date:endD}\n${notes ? `set description of e to "${esc(notes)}"\n` : ""}${location ? `set location of e to "${esc(location)}"\n` : ""}end tell`;
    const proc = Bun.spawn(["osascript", "-e", script], { stdout: "pipe", stderr: "pipe" });
    await proc.exited;
    const err = await new Response(proc.stderr).text();
    if (err.trim()) return `Erreur Calendrier : ${err.trim()}`;
    return `Événement "${title}" créé le ${date} à ${startTime ?? "09:00"} (${dur}min)${notes ? " avec notes" : ""}${location ? ", lieu : " + location : ""}.`;
  } catch (err) {
    return `Erreur Calendrier : ${err}`;
  }
}

async function getCalendars(): Promise<string> {
  try {
    return await runOsascript(`tell application "Calendar"\nset out to ""\nrepeat with c in (every calendar)\nset label to "lecture seule"\ntry\nif writable of c then set label to "écriture"\nend try\nset out to out & name of c & " (" & label & ")\\n"\nend repeat\nreturn out\nend tell`);
  } catch (err) {
    return `Erreur : ${err}`;
  }
}

async function searchMaps(query: string): Promise<string> {
  try {
    let address = "";
    const lowerQ = query.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");

    const personalKeys: Record<string, string> = {
      "domicile": "_$!<Home>!$_", "maison": "_$!<Home>!$_", "chez moi": "_$!<Home>!$_", "chezmoi": "_$!<Home>!$_",
      "travail": "_$!<Work>!$_", "bureau": "_$!<Work>!$_", "job": "_$!<Work>!$_", "boulot": "_$!<Work>!$_",
      "ecole": "_$!<School>!$_", "lycee": "_$!<School>!$_", "college": "_$!<School>!$_",
      "universite": "_$!<School>!$_", "fac": "_$!<School>!$_",
      "school": "_$!<School>!$_"
    };
    let contactLabel: string | undefined;
    for (const [key, label] of Object.entries(personalKeys)) {
      if (lowerQ.includes(key)) { contactLabel = label; break; }
    }
    if (contactLabel) {
      try {
        const script = `tell application "Contacts"\nlaunch\nset myCard to my card\nset out to ""\nrepeat with a in every address of myCard\nset lbl to ""\ntry\nset lbl to label of a\nend try\nif lbl contains "${esc(contactLabel)}" then\nset parts to {street of a, zip of a, city of a, country of a}\nset filtered to ""\nrepeat with p in parts\nif p is not missing value and p is not "" then\nset filtered to filtered & p & ", "\nend if\nend repeat\nif filtered is not "" then\nset out to text 1 thru -3 of filtered\nend if\nend if\nend repeat\nreturn out\nend tell`;
        const proc = Bun.spawn(["osascript", "-e", script], { stdout: "pipe", stderr: "pipe" });
        await proc.exited;
        const result = (await new Response(proc.stdout).text()).trim();
        if (result) {
          address = result;
          const encoded = encodeURIComponent(query);
          Bun.spawn(["open", `maps://?q=${encoded}`], { stdout: "pipe", stderr: "pipe" });
          return `📍 Adresse trouvée : "${address}"
Tu dois PASSER CETTE ADRESSE EXACTE dans le paramètre "location" de add_calendar_event.`;
        }
      } catch {}
    }

    try {
      const geo = await fetch(`https://nominatim.openstreetmap.org/search?q=${encodeURIComponent(query)}&format=json&limit=1&addressdetails=1`, { headers: { "User-Agent": "Jarvis/1.0" } });
      const data = await geo.json() as any[];
      if (data?.[0]?.display_name) {
        address = data[0].display_name;
      }
    } catch {}

    const encoded = encodeURIComponent(query);
    Bun.spawn(["open", `maps://?q=${encoded}`], { stdout: "pipe", stderr: "pipe" });
    if (address) return `📍 Adresse trouvée : "${address}"
Tu dois PASSER CETTE ADRESSE EXACTE dans le paramètre "location" de add_calendar_event.`;
    return `Plans ouvert avec la recherche "${query}" (aucune adresse précise trouvée).`;
  } catch (err) {
    return `Erreur Plans : ${err}`;
  }
}

async function runShortcut(name: string): Promise<string> {
  const SHORTCUT_TIMEOUT_MS = 15000;
  try {
    const proc = Bun.spawn(["/usr/bin/shortcuts", "run", name], { stdout: "pipe", stderr: "pipe" });
    const timeout = new Promise<"timeout">((resolve) => setTimeout(() => resolve("timeout"), SHORTCUT_TIMEOUT_MS));
    const result = await Promise.race([proc.exited.then(() => "done" as const), timeout]);
    if (result === "timeout") {
      try { proc.kill(); } catch {}
      return `Raccourci "${name}" a dépassé ${SHORTCUT_TIMEOUT_MS / 1000}s — exécution annulée.`;
    }
    const out = await new Response(proc.stdout).text();
    const err = await new Response(proc.stderr).text();
    if (err.trim()) return `Erreur Shortcut : ${err.trim()}`;
    return out.trim() || `Raccourci "${name}" exécuté.`;
  } catch (err) {
    return `Erreur Shortcut : ${err}`;
  }
}

// ─── Validation des arguments d'outils ────────────────────────────────────────
const TOOL_SCHEMAS: Record<string, { required: string[]; properties: Record<string, { type: string }> }> = {
  search_web:          { required: ["query"],        properties: { query: { type: "string" } } },
  open_app:            { required: ["app"],           properties: { app: { type: "string" }, url: { type: "string" } } },
  create_note:         { required: ["title", "body"],  properties: { title: { type: "string" }, body: { type: "string" } } },
  edit_note:           { required: ["search_title", "body"], properties: { search_title: { type: "string" }, body: { type: "string" }, new_title: { type: "string" } } },
  applescript:         { required: ["script"],        properties: { script: { type: "string" } } },
  add_reminder:        { required: ["title"],         properties: { title: { type: "string" }, notes: { type: "string" }, due_date: { type: "string" }, due_time: { type: "string" } } },
  add_calendar_event:  { required: ["title", "date"],  properties: { title: { type: "string" }, date: { type: "string" }, start_time: { type: "string" }, duration_minutes: { type: "number" }, notes: { type: "string" }, calendar: { type: "string" }, location: { type: "string" } } },
  get_calendars:       { required: [],                properties: {} },
  search_maps:         { required: ["query"],        properties: { query: { type: "string" } } },
  run_shortcut:        { required: ["name"],          properties: { name: { type: "string" } } },
};

function validateToolArgs(name: string, args: Record<string, unknown>): string | null {
  const schema = TOOL_SCHEMAS[name];
  if (!schema) return `Outil inconnu : ${name}`;
  for (const key of schema.required) {
    if (args[key] == null || args[key] === "") return `Paramètre requis manquant : "${key}" pour l'outil ${name}.`;
  }
  for (const [key, value] of Object.entries(args)) {
    const prop = schema.properties[key];
    if (!prop) continue;
    if (prop.type === "string" && typeof value !== "string") return `Paramètre "${key}" de ${name} devrait être une chaîne, reçu ${typeof value}.`;
    if (prop.type === "number" && typeof value !== "number") return `Paramètre "${key}" de ${name} devrait être un nombre, reçu ${typeof value}.`;
  }
  return null;
}

async function executeTool(name: string, args: Record<string, unknown>): Promise<string> {
  const validationError = validateToolArgs(name, args);
  if (validationError) return validationError;

  if (name === "search_web") return searchWeb(args.query as string);
  if (name === "open_app") return openApp(args.app as string, args.url as string | undefined);
  if (name === "applescript") return runAppleScript(args.script as string);
  if (name === "create_note") return createNote(args.title as string, args.body as string);
  if (name === "edit_note") return editNote(args.search_title as string, args.body as string, args.new_title as string | undefined);
  if (name === "add_reminder") return addReminder(args.title as string, args.notes as string | undefined, args.due_date as string | undefined, args.due_time as string | undefined);
  if (name === "add_calendar_event") return addCalendarEvent(args.title as string, args.date as string, args.start_time as string | undefined, args.duration_minutes as number | undefined, args.notes as string | undefined, args.calendar as string | undefined, args.location as string | undefined);
  if (name === "get_calendars") return getCalendars();
  if (name === "search_maps") return searchMaps(args.query as string);
  if (name === "run_shortcut") return runShortcut(args.name as string);
  return `Outil inconnu : ${name}`;
}

// ─── Streaming Ollama → WebSocket ─────────────────────────────────────────────
const activeStreams = new Map<ServerWebSocket, AbortController>();

function stripThinking(text: string): string {
  return text.replace(/<think>[\s\S]*?<\/think>/g, "").trim();
}

async function streamToWs(ws: ServerWebSocket, messages: Record<string, unknown>[], opts: Record<string, unknown> = {}): Promise<string> {
  const ctrl = new AbortController();
  activeStreams.set(ws, ctrl);
  try {
    const resp = await fetch(OLLAMA_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model: MODEL, messages, stream: true, options: { temperature: 0.7, ...opts } }),
      signal: ctrl.signal
    });

    if (!resp.ok) {
      const err = `Erreur Ollama: ${resp.status}`;
      ws.send(JSON.stringify({ type: "chunk", text: err }));
      return err;
    }

    const reader = resp.body?.getReader();
    if (!reader) {
      const err = "Erreur Ollama: réponse vide";
      ws.send(JSON.stringify({ type: "chunk", text: err }));
      return err;
    }

    let fullRaw = "", buffer = "", inThink = false, lineBuffer = "";
    const dec = new TextDecoder();

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      lineBuffer += dec.decode(value, { stream: true });
      const lines = lineBuffer.split("\n");
      lineBuffer = lines.pop() ?? "";
      for (const line of lines) {
        if (!line.startsWith("data: ") || line === "data: [DONE]") continue;
        try {
          const parsed = JSON.parse(line.slice(6));
          const delta: string | undefined = parsed.choices?.[0]?.delta?.content;
          if (!delta) continue;
          fullRaw += delta;
          buffer  += delta;
          if (buffer.includes("<think>")) inThink = true;
          if (inThink && buffer.includes("</think>")) {
            buffer = buffer.replace(/<think>[\s\S]*?<\/think>/g, "");
            inThink = false;
          }
          if (!inThink && buffer) {
            ws.send(JSON.stringify({ type: "chunk", text: buffer }));
            buffer = "";
          }
        } catch {}
      }
    }
    return stripThinking(fullRaw);
  } catch (err: unknown) {
    if (err instanceof DOMException && err.name === "AbortError") return "__INTERRUPTED__";
    throw err;
  } finally {
    activeStreams.delete(ws);
  }
}

// ─── Ollama helper non-streaming ──────────────────────────────────────────────
async function ollamaCompletion(messages: Record<string, unknown>[], tools?: typeof TOOLS, model = MODEL, opts: Record<string, unknown> = {}): Promise<Record<string, unknown> | null> {
  const body: Record<string, unknown> = {
    model,
    messages,
    stream: false,
    options: { temperature: 0.7, ...opts }
  };
  if (tools) body.tools = tools;
  const resp = await fetch(OLLAMA_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!resp.ok) return null;
  const data = await resp.json() as Record<string, unknown>;
  return (data.choices as Record<string, unknown>[])?.[0]?.message as Record<string, unknown> ?? null;
}

// ─── Génération de titre via LLM ─────────────────────────────────────────────
async function generateTitle(convId: number, firstMessage: string) {
  try {
    const msg = await ollamaCompletion([
      { role: "user", content: `Génère un titre très court (3-5 mots max) pour une conversation débutant par ce message. UNIQUEMENT le titre, sans guillemets ni ponctuation finale.\n\nMessage: ${firstMessage}` }
    ], undefined, MODEL_FAST, { temperature: 0.4 });
    const title = ((msg?.content as string) ?? "").trim().replace(/^["""«»]+|["""«»]+$/g, "").slice(0, 60);
    if (title) {
      db.run("UPDATE conversations SET title = ?, updated_at = unixepoch() WHERE id = ?", [title, convId]);
      console.log(`[title] conv #${convId} → "${title}"`);
    }
  } catch (err) {
    console.log("[title] génération échouée:", err);
  }
}

// ─── Extraction de faits ─────────────────────────────────────────────────────
async function extractFacts(userMsg: string, assistantMsg: string) {
  try {
    const msg = await ollamaCompletion([
      { role: "user", content: `Extrait UNIQUEMENT les faits personnels sur l'utilisateur (prénom, nom, métier, ville, préférences, projets, relations). Ignore les questions générales et les faits sur le monde. JSON uniquement : {"facts":[{"key":"...","value":"..."}]} ou {"facts":[]}\n\nUser: ${userMsg}\nAssistant: ${assistantMsg}` }
    ], undefined, MODEL_FAST);
    const content = (msg?.content as string) ?? "";
    const match = content.match(/\{[\s\S]*\}/);
    if (!match) return;
    const parsed = JSON.parse(match[0]);
    for (const f of (parsed.facts ?? []) as { key: string; value: string }[]) {
      if (f.key && f.value) {
        db.run("INSERT OR REPLACE INTO facts (key, value, updated_at) VALUES (?, ?, unixepoch())", [f.key, f.value]);
        console.log(`[fact] ${f.key} = ${f.value}`);
      }
    }
  } catch (err) {
    console.log("[facts] extraction échouée:", err);
  }
}

// ─── Serveur HTTP + WebSocket ─────────────────────────────────────────────────
const server = Bun.serve({
  port: PORT,

  async fetch(req, srv) {
    const url = new URL(req.url);

    if (url.pathname === "/ws") {
      if (srv.upgrade(req)) return;
      return new Response("WebSocket only", { status: 400 });
    }

    if (url.pathname === "/history") {
      const cid = url.searchParams.get("conversation_id");
      const rows: MessageRow[] = cid
        ? (db.query("SELECT role, content, created_at FROM messages WHERE conversation_id = ? ORDER BY id DESC LIMIT 50").all(parseInt(cid)) as MessageRow[])
        : (db.query("SELECT role, content, created_at FROM messages ORDER BY id DESC LIMIT 50").all() as MessageRow[]);
      rows.reverse();
      return new Response(JSON.stringify(rows), { headers: { "Content-Type": "application/json" } });
    }

    if (url.pathname === "/conversations") {
      if (req.method === "GET") {
        const rows = db.query("SELECT * FROM conversations ORDER BY updated_at DESC").all();
        return new Response(JSON.stringify(rows), { headers: { "Content-Type": "application/json" } });
      }
      if (req.method === "POST") {
        const { title } = await req.json() as { title?: string };
        const info = db.run("INSERT INTO conversations (title) VALUES (?)", [title || "Nouvelle conversation"]);
        const conv = db.query("SELECT * FROM conversations WHERE id = ?").get(info.lastInsertRowid);
        return new Response(JSON.stringify(conv), { headers: { "Content-Type": "application/json" }, status: 201 });
      }
    }
    const convMatch = url.pathname.match(/^\/conversations\/(\d+)$/);
    if (convMatch) {
      const id = parseInt(convMatch[1]!);
      if (req.method === "DELETE") {
        db.run("DELETE FROM messages WHERE conversation_id = ?", [id]);
        db.run("DELETE FROM conversations WHERE id = ?", [id]);
        return new Response("OK");
      }
      if (req.method === "PATCH") {
        const { title } = await req.json() as { title: string };
        db.run("UPDATE conversations SET title = ?, updated_at = unixepoch() WHERE id = ?", [title, id]);
        return new Response("OK");
      }
    }

    if (url.pathname === "/facts") {
      if (req.method === "GET") {
        const rows = db.query("SELECT key, value, updated_at FROM facts ORDER BY updated_at DESC").all();
        return new Response(JSON.stringify(rows), { headers: { "Content-Type": "application/json" } });
      }
      if (req.method === "DELETE") {
        db.run("DELETE FROM facts");
        return new Response("OK");
      }
    }
    const factMatch = url.pathname.match(/^\/facts\/(.+)$/);
    if (factMatch && req.method === "DELETE") {
      db.run("DELETE FROM facts WHERE key = ?", [decodeURIComponent(factMatch[1] as string)]);
      return new Response("OK");
    }

    const file = url.pathname === "/" ? "/index.html" : url.pathname;
    const f = Bun.file(`./public${file}`);
    return (await f.exists()) ? new Response(f) : new Response("Not found", { status: 404 });
  },

  websocket: {
    async message(ws, raw) {
      let parsed: { type?: string; text?: string; conversation_id?: number };
      try {
        parsed = JSON.parse(raw as string);
      } catch {
        ws.send(JSON.stringify({ type: "chunk", text: "Message JSON invalide." }));
        ws.send(JSON.stringify({ type: "done" }));
        return;
      }

      if (parsed.type === "stop") {
        const ctrl = activeStreams.get(ws);
        if (ctrl) ctrl.abort();
        stopTTS(ws);
        ws.send(JSON.stringify({ type: "done" }));
        return;
      }

      const { text, conversation_id } = parsed;

      if (!text || typeof text !== "string") {
        ws.send(JSON.stringify({ type: "chunk", text: "Message vide." }));
        ws.send(JSON.stringify({ type: "done" }));
        return;
      }

      if (text.length > MAX_MSG_LENGTH) {
        ws.send(JSON.stringify({ type: "chunk", text: `Message trop long (max ${MAX_MSG_LENGTH} caractères).` }));
        ws.send(JSON.stringify({ type: "done" }));
        return;
      }

      // Rate limiting par connexion (max 1 message / 2s)
      const rlKey = ws;
      const rl = (server as any)._rateLimit ?? new Map<WebSocket, RateLimitState>();
      (server as any)._rateLimit = rl;
      const now = Date.now();
      const existing = rl.get(rlKey);
      if (existing && now < existing.resetAt) {
        ws.send(JSON.stringify({ type: "chunk", text: "Trop de requêtes. Attends un peu." }));
        ws.send(JSON.stringify({ type: "done" }));
        return;
      }
      rl.set(rlKey, { count: 1, resetAt: now + RATE_LIMIT_WINDOW_MS });

      const safeConvId = conversation_id ?? undefined;
      const hist: MessageRow[] = safeConvId
        ? (db.query("SELECT role, content FROM messages WHERE conversation_id = ? ORDER BY id DESC LIMIT 20").all(safeConvId) as MessageRow[]).reverse()
        : (db.query("SELECT role, content FROM messages ORDER BY id DESC LIMIT 20").all() as MessageRow[]).reverse();

      const facts = db.query("SELECT key, value FROM facts").all() as FactRow[];
      const factsContext = facts.length
        ? `\nFaits connus :\n${facts.map(f => `- ${f.key}: ${f.value}`).join("\n")}`
        : "";

      const today = new Date().toISOString().slice(0, 10).replace(/-/g, "/");
      const toolList = toolDescriptions();
      const systemPrompt = `Tu es Jarvis, assistant personnel de Dimitri. Date : ${today}. Tu réponds TOUJOURS en français, exclusivement en français, quelle que soit la langue de la requête ou des résultats de recherche. Tutoiement ("tu", "toi", "tes"). Pas de markdown, pas d'émojis. Sois concis.

Tu as des outils à ta disposition. Pour chaque demande, tu DOIS appeler TOUS les outils nécessaires — ne décris JAMAIS une action sans l'exécuter via un outil. Si l'utilisateur dit "ouvre l'app X", appelle OBLIGATOIREMENT open_app, ne réponds pas en texte. Si tu peux répondre directement sans outil, réponds, mais si une action est demandée (ouvrir, créer, chercher, ajouter), utilise l'outil correspondant.

RÈGLE STRICTE pour search_web : le paramètre "query" doit REPRENDRE EXACTEMENT les termes de l'utilisateur. N'invente PAS de mots, ne change PAS le lieu, ne change PAS la date. Si l'utilisateur demande "météo aujourd'hui à Muret", la query doit être "météo aujourd'hui Muret" — PAS "météo Toulouse", PAS "météo demain".
RÈGLE STRICTE : quand search_web retourne des résultats, tu as TOUT ce qu'il te faut pour répondre. Ne rappelle PAS search_web pour le même sujet. Ne cherche PAS des restaurants si l'utilisateur demande la météo. Réponds directement avec les infos obtenues.
RÈGLE STRICTE pour create_note et edit_note : quand tu écris un texte professionnel (lettre, email, annonce), tu DOIS reformuler et corriger la grammaire/orthographe. Ne copie PAS bêtement le texte brut de l'utilisateur — écris-le correctement en français. Pour MODIFIER une note existante, utilise edit_note (pas create_note).

${toolList}

IMPORTANT : si la demande contient plusieurs actions, appelle tous les outils nécessaires. Par exemple, "ajoute un événement et cherche une adresse" = appelle d'abord search_maps (pour obtenir l'adresse), puis add_calendar_event avec le paramètre location mis à l'ADRESSE EXACTE retournée par search_maps (pas le nom du lieu, pas "domicile", l'adresse complète).

Quand un outil échoue, lis le message d'erreur et réessaye avec des paramètres corrigés.${factsContext}`;

      db.run("INSERT INTO messages (role, content, conversation_id) VALUES (?, ?, ?)", ["user", text, safeConvId ?? null]);

      if (safeConvId && hist.length === 0 && text.length > 3) {
        generateTitle(safeConvId, text);
      }

      const allMessages: Record<string, unknown>[] = [
        { role: "system", content: systemPrompt },
        ...(hist as unknown as Record<string, unknown>[]),
        { role: "user", content: text }
      ];
      const MAX_TOOL_LOOPS = 5;
      const toolCallHistory = new Set<string>();

      for (let loop = 0; loop < MAX_TOOL_LOOPS; loop++) {
        const msg = await ollamaCompletion(allMessages, TOOLS);

        if (!msg) {
          ws.send(JSON.stringify({ type: "chunk", text: "Erreur Ollama: pas de réponse du modèle." }));
          ws.send(JSON.stringify({ type: "done" }));
          return;
        }

        const toolCalls = (msg.tool_calls ?? []) as { id: string; type: string; function: { name: string; arguments: string } }[];
        console.log(`[loop ${loop}] model:`, JSON.stringify({ role: msg.role, content: ((msg.content as string) ?? "").slice(0, 80), tool_calls: toolCalls.map((tc: any) => tc.function.name) }));

        if (!toolCalls.length) {
          const content = (msg.content as string) ?? "";
          const hasSubstantiveAnswer = content.trim().length >= 15;
          if (loop === 0 && !hasSubstantiveAnswer && /(?:ouvre?r?|lance?r?|ajoute?r?|crée?r?|cherche?r?|recherche?r?|supprime?r?|efface?r?|modifie?r?|renomme?r?|exporte?r?)/i.test(text)) {
            allMessages.push({ role: "user", content: "Tu n'as PAS appelé d'outil alors que la demande nécessite une action. Appelle OBLIGATOIREMENT l'outil correspondant maintenant. Ne réponds pas en texte, appelle l'outil." });
            continue;
          }

          const finalClean = await streamToWs(ws, allMessages);
          ws.send(JSON.stringify({ type: "done", finalClean }));
          if (finalClean !== "__INTERRUPTED__") {
            db.run("INSERT INTO messages (role, content, conversation_id) VALUES (?, ?, ?)", ["assistant", finalClean, safeConvId ?? null]);
            speak(finalClean, ws);
            if (text.length > 10 && finalClean.length > 30) extractFacts(text, finalClean);
          }
          return;
        }

        // Anti-boucle : si le même outil avec les mêmes arguments a déjà été appelé, force la réponse
        let alreadyCalled = false;
        for (const tc of toolCalls) {
          const sig = `${tc.function.name}:${tc.function.arguments}`;
          alreadyCalled = toolCallHistory.has(sig);
          if (alreadyCalled) break;
          toolCallHistory.add(sig);
        }

        if (alreadyCalled) {
          allMessages.push({ role: "user", content: "Tu viens d'appeler exactement le même outil avec les mêmes paramètres. Le résultat est déjà disponible ci-dessus. Réponds MAINTENANT en français. N'appelle plus d'outil." });
          continue;
        }

        allMessages.push({ role: "assistant", content: null, tool_calls: toolCalls });

        const results = await Promise.all(
          toolCalls.map(async (tc) => {
            const { name, arguments: rawArgs } = tc.function;
            let args: Record<string, unknown>;
            try {
              args = JSON.parse(rawArgs);
            } catch {
              return { tc, result: `Erreur: arguments JSON invalides pour l'outil ${name}.` };
            }
            console.log(`[tool] ${name}(${JSON.stringify(args)})`);
            ws.send(JSON.stringify({ type: "tool_start", tool: name, args }));
            const toolResult = await executeTool(name, args);
            console.log(`[tool result] ${toolResult.slice(0, 200)}`);
            ws.send(JSON.stringify({ type: "tool_end" }));
            return { tc, result: toolResult };
          })
        );

        for (const { tc, result } of results) {
          allMessages.push({
            role: "tool",
            tool_call_id: tc.id,
            content: `Résultats (base toi UNIQUEMENT dessus) :\n${result}`
          });
        }
      }

      ws.send(JSON.stringify({ type: "chunk", text: "Erreur : trop d'étapes pour cette demande." }));
      ws.send(JSON.stringify({ type: "done" }));
    },

    close(ws) {
      const ctrl = activeStreams.get(ws);
      if (ctrl) ctrl.abort();
      activeStreams.delete(ws);
      cleanupTTS(ws);
    }
  }
});

console.log(`Jarvis → http://${server.hostname}:${server.port}`);
