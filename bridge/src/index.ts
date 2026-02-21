import "dotenv/config";
import express from "express";
import http from "http";
import { WebSocketServer, WebSocket } from "ws";
import cors from "cors";
import { STTClient } from "./stt";
import { TTSClient } from "./tts";
import { OpenClawClient } from "./openclaw";

// ── Config ──────────────────────────────────────────────────────────
const PORT = Number(process.env.PORT) || 3001;
const SMALLEST_AI_KEY = process.env.SMALLEST_AI_KEY!;
const SIMLI_API_KEY = process.env.SIMLI_API_KEY!;
const SIMLI_FACE_ID =
  process.env.SIMLI_FACE_ID || "d2a5c7c6-fed9-4f55-bcb3-062f7cd20103";
const OPENCLAW_HOST = process.env.OPENCLAW_HOST || "127.0.0.1";
const OPENCLAW_PORT = Number(process.env.OPENCLAW_PORT) || 18789;
const OPENCLAW_TOKEN = process.env.OPENCLAW_TOKEN || "";

// ── Express ─────────────────────────────────────────────────────────
const app = express();
app.use(cors());
app.use(express.json());

const server = http.createServer(app);

// ── Simli Session Cache ─────────────────────────────────────────────
let simliSessionToken: string | null = null;
let simliSessionExpiry = 0;

async function getSimliSession(): Promise<string> {
  // Reuse token if not expired (refresh every 25 minutes)
  if (simliSessionToken && Date.now() < simliSessionExpiry) {
    return simliSessionToken;
  }

  console.log("[Simli] Creating new session...");
  const res = await fetch("https://api.simli.ai/startAudioToVideoSession", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-simli-api-key": SIMLI_API_KEY,
    },
    body: JSON.stringify({
      faceId: SIMLI_FACE_ID,
      handleSilence: true,
      syncAudio: true,
      maxSessionLength: 1800,
      maxIdleTime: 600,
    }),
  });

  const data = (await res.json()) as { session_token?: string };
  if (!data.session_token || data.session_token === "FAIL TOKEN") {
    throw new Error(`Simli session failed: ${JSON.stringify(data)}`);
  }

  simliSessionToken = data.session_token;
  simliSessionExpiry = Date.now() + 25 * 60 * 1000;
  console.log(`[Simli] Session token: ${simliSessionToken.substring(0, 12)}...`);
  return simliSessionToken;
}

// ── REST Endpoints ──────────────────────────────────────────────────
app.get("/health", (_req, res) => {
  res.json({
    ok: true,
    openclaw: openclaw.isConnected,
  });
});

app.get("/api/simli-session", async (_req, res) => {
  try {
    const sessionToken = await getSimliSession();
    res.json({ sessionToken });
  } catch (err: any) {
    console.error("[Simli] Session error:", err.message);
    res.status(500).json({ error: err.message });
  }
});

// ── OpenClaw Gateway ────────────────────────────────────────────────
const openclaw = new OpenClawClient(OPENCLAW_HOST, OPENCLAW_PORT, OPENCLAW_TOKEN);

// When OpenClaw responds, synthesize speech and send to iOS
openclaw.onResponse = (text) => {
  console.log(`[Vera] "${text.substring(0, 80)}..."`);

  // Send text to all connected iOS clients
  broadcastJSON({ type: "vera_response", text });

  // Synthesize speech
  tts.speak(text);
};

// When OpenClaw triggers a tool call (e.g., make_call)
openclaw.onToolCall = (tool, params) => {
  console.log(`[OpenClaw] Tool call: ${tool}`, params);

  if (tool === "make_call" || tool === "call" || tool === "phone_call") {
    const phone = (params.phone || params.phone_number || params.number) as string;
    const name = (params.name || params.contact_name || "Unknown") as string;
    broadcastJSON({ type: "call", phone, name });
  }
};

openclaw.connect();

// ── STT ─────────────────────────────────────────────────────────────
const stt = new STTClient(SMALLEST_AI_KEY);

stt.onTranscript = (text, isFinal) => {
  // Send partial/final transcripts to iOS for display
  broadcastJSON({ type: "transcript", text, isFinal });

  // When transcription is final, forward to OpenClaw
  if (isFinal && text.trim()) {
    openclaw.sendMessage(text.trim());
  }
};

stt.connect();

// ── TTS ─────────────────────────────────────────────────────────────
const tts = new TTSClient(SMALLEST_AI_KEY);

tts.onSpeakingStart = () => {
  broadcastJSON({ type: "speaking_start" });
};

tts.onAudioChunk = (pcm16) => {
  // Send raw PCM16 audio to all iOS clients (for speaker playback + Simli lip-sync)
  broadcastBinary(pcm16);
};

tts.onSpeakingEnd = () => {
  broadcastJSON({ type: "speaking_end" });
};

// ── WebSocket Server (iOS clients) ─────────────────────────────────
const wss = new WebSocketServer({ server, path: "/ws" });
const clients = new Set<WebSocket>();

wss.on("connection", (ws) => {
  console.log("[WS] iOS client connected");
  clients.add(ws);

  ws.on("message", (data, isBinary) => {
    if (isBinary) {
      // Raw PCM16 audio from iOS mic → forward to STT
      stt.sendAudio(Buffer.from(data as ArrayBuffer));
    } else {
      // JSON control messages
      try {
        const msg = JSON.parse(data.toString());
        if (msg.type === "end_speech") {
          stt.endSpeech();
        }
      } catch {
        // ignore
      }
    }
  });

  ws.on("close", () => {
    console.log("[WS] iOS client disconnected");
    clients.delete(ws);
  });
});

function broadcastJSON(obj: unknown) {
  const str = JSON.stringify(obj);
  for (const ws of clients) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(str);
    }
  }
}

function broadcastBinary(buf: Buffer) {
  for (const ws of clients) {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(buf);
    }
  }
}

// ── Start ───────────────────────────────────────────────────────────
server.listen(PORT, "0.0.0.0", () => {
  console.log(`\n🔥 Vera Bridge running on port ${PORT}`);
  console.log(`   WebSocket: ws://0.0.0.0:${PORT}/ws`);
  console.log(`   Simli:     http://0.0.0.0:${PORT}/api/simli-session`);
  console.log(`   OpenClaw:  ws://${OPENCLAW_HOST}:${OPENCLAW_PORT}`);
  console.log();
});
