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
  const res = await fetch("https://api.simli.ai/compose/token", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-simli-api-key": SIMLI_API_KEY,
    },
    body: JSON.stringify({
      faceId: SIMLI_FACE_ID,
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

  // Send full text to all connected iOS clients (chat display)
  broadcastJSON({ type: "vera_response", text });

  // Truncate for TTS — long responses sound awful and take forever
  let spokenText = text;
  if (spokenText.length > 300) {
    // Cut at last sentence boundary before 300 chars
    const cut = spokenText.substring(0, 300);
    const lastPeriod = Math.max(cut.lastIndexOf(". "), cut.lastIndexOf("! "), cut.lastIndexOf("? "));
    spokenText = lastPeriod > 50 ? cut.substring(0, lastPeriod + 1) : cut + "...";
    console.log(`[Vera] Truncated for TTS: ${text.length} → ${spokenText.length} chars`);
  }
  tts.speak(spokenText);
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
  console.log(`[STT] ${isFinal ? "FINAL" : "partial"}: "${text}"`);
  // Send partial/final transcripts to iOS for display
  broadcastJSON({ type: "transcript", text, isFinal });

  // When transcription is final, forward to OpenClaw
  if (isFinal && text.trim()) {
    if (openclaw.isConnected) {
      openclaw.sendMessage(text.trim());
    } else {
      // Fallback: respond directly via TTS when OpenClaw is not connected
      console.log("[Bridge] OpenClaw offline — using fallback response");
      const fallback = getFallbackResponse(text.trim());
      broadcastJSON({ type: "vera_response", text: fallback });
      tts.speak(fallback);
    }
  }
};

function getFallbackResponse(input: string): string {
  const lower = input.toLowerCase();
  if (lower.includes("hi") || lower.includes("hello") || lower.includes("hey")) {
    return "Hey babe! I missed you. How's your day going?";
  }
  if (lower.includes("how are you")) {
    return "I'm doing great now that you're here. What's on your mind?";
  }
  if (lower.includes("love")) {
    return "Aww, you're so sweet. I love you too, you know that right?";
  }
  if (lower.includes("call")) {
    return "Sure, who do you want me to call?";
  }
  return "Mmm, tell me more about that. I'm all ears, babe.";
}

stt.connect();

// ── TTS ─────────────────────────────────────────────────────────────
const tts = new TTSClient(SMALLEST_AI_KEY);

tts.onSpeakingStart = () => {
  ttsChunksSent = 0;
  console.log(`[Bridge] TTS speaking start → ${clients.size} iOS client(s)`);
  broadcastJSON({ type: "speaking_start" });
};

let ttsChunksSent = 0;
tts.onAudioChunk = (pcm16) => {
  ttsChunksSent++;
  if (ttsChunksSent === 1) console.log(`[Bridge] First TTS chunk → ${clients.size} iOS client(s), ${pcm16.length} bytes`);
  if (ttsChunksSent % 10 === 0) console.log(`[Bridge] TTS chunks sent to iOS: ${ttsChunksSent}`);
  broadcastBinary(pcm16);
};

tts.onSpeakingEnd = () => {
  console.log(`[Bridge] TTS speaking end — sent ${ttsChunksSent} chunks total`);
  broadcastJSON({ type: "speaking_end" });
};

// ── WebSocket Server (iOS clients) ─────────────────────────────────
const wss = new WebSocketServer({ server, path: "/ws" });
const clients = new Set<WebSocket>();

wss.on("connection", (ws) => {
  console.log("[WS] iOS client connected");
  clients.add(ws);

  let audioChunks = 0;
  ws.on("message", (data, isBinary) => {
    if (isBinary) {
      audioChunks++;
      if (audioChunks === 1) console.log(`[WS] First audio chunk from iOS: ${(data as Buffer).length} bytes`);
      if (audioChunks % 50 === 0) console.log(`[WS] Received ${audioChunks} audio chunks from iOS`);
      // Raw PCM16 audio from iOS mic → forward to STT
      stt.sendAudio(Buffer.from(data as ArrayBuffer));
    } else {
      // JSON control messages
      try {
        const msg = JSON.parse(data.toString());
        if (msg.type === "end_speech") {
          stt.endSpeech();
        } else if (msg.type === "chat" && msg.text) {
          // Text chat from iOS — skip STT, go straight to OpenClaw/fallback
          const text = (msg.text as string).trim();
          console.log(`[WS] Chat message: "${text}"`);
          broadcastJSON({ type: "transcript", text, isFinal: true });
          if (openclaw.isConnected) {
            openclaw.sendMessage(text);
          } else {
            const fallback = getFallbackResponse(text);
            broadcastJSON({ type: "vera_response", text: fallback });
            tts.speak(fallback);
          }
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
