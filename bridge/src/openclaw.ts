import WebSocket from "ws";
import crypto from "crypto";
import fs from "fs";
import path from "path";

// ── Device Keypair Persistence ───────────────────────────────────────
const KEYPAIR_PATH = path.join(__dirname, "..", ".device-keypair.json");

interface StoredKeypair {
  publicKeyBase64Url: string;
  privateKeyPem: string;
}

function getOrCreateKeypair(): {
  publicKeyRaw: Buffer;
  publicKeyBase64Url: string;
  privateKey: crypto.KeyObject;
} {
  try {
    const data: StoredKeypair = JSON.parse(
      fs.readFileSync(KEYPAIR_PATH, "utf-8")
    );
    const privateKey = crypto.createPrivateKey(data.privateKeyPem);
    const raw = base64UrlDecode(data.publicKeyBase64Url);
    return {
      publicKeyRaw: raw,
      publicKeyBase64Url: data.publicKeyBase64Url,
      privateKey,
    };
  } catch {
    // Generate new Ed25519 keypair using Node crypto
    const { publicKey, privateKey } = crypto.generateKeyPairSync("ed25519");

    // Export raw 32-byte public key
    const spkiDer = publicKey.export({ type: "spki", format: "der" });
    // Ed25519 SPKI DER has a 12-byte prefix before the 32-byte key
    const raw = spkiDer.subarray(spkiDer.length - 32);
    const publicKeyBase64Url = base64UrlEncode(raw);

    const privateKeyPem = privateKey
      .export({ type: "pkcs8", format: "pem" })
      .toString();

    fs.writeFileSync(
      KEYPAIR_PATH,
      JSON.stringify({ publicKeyBase64Url, privateKeyPem })
    );
    console.log("[OpenClaw] Generated new device keypair");

    return { publicKeyRaw: raw, publicKeyBase64Url, privateKey };
  }
}

function base64UrlEncode(buf: Buffer): string {
  return buf
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function base64UrlDecode(str: string): Buffer {
  let b64 = str.replace(/-/g, "+").replace(/_/g, "/");
  while (b64.length % 4 !== 0) b64 += "=";
  return Buffer.from(b64, "base64");
}

/** Device ID = SHA-256(raw 32-byte public key) as hex */
function deriveDeviceId(publicKeyRaw: Buffer): string {
  return crypto.createHash("sha256").update(publicKeyRaw).digest("hex");
}

// ── OpenClaw Gateway Client ──────────────────────────────────────────

export class OpenClawClient {
  private ws: WebSocket | null = null;
  private host: string;
  private port: number;
  private token: string;
  private requestId = 0;
  private connected = false;
  private keypair: ReturnType<typeof getOrCreateKeypair>;
  private deviceToken: string | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;

  onResponse: (text: string) => void = () => {};
  onToolCall: (tool: string, params: Record<string, unknown>) => void =
    () => {};

  constructor(host: string, port: number, token: string) {
    this.host = host;
    this.port = port;
    this.token = token;
    this.keypair = getOrCreateKeypair();
    console.log(
      `[OpenClaw] Device ID: ${deriveDeviceId(this.keypair.publicKeyRaw)}`
    );
  }

  connect() {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }

    const url = `ws://${this.host}:${this.port}`;
    console.log(`[OpenClaw] Connecting to ${url}...`);

    this.ws = new WebSocket(url);

    this.ws.on("open", () => {
      console.log("[OpenClaw] WebSocket open, waiting for challenge...");
    });

    this.ws.on("message", (raw) => {
      try {
        const msg = JSON.parse(raw.toString());
        this.handleMessage(msg);
      } catch {
        // ignore non-JSON
      }
    });

    this.ws.on("close", () => {
      console.log("[OpenClaw] Disconnected");
      this.connected = false;
      this.reconnectTimer = setTimeout(() => this.connect(), 3000);
    });

    this.ws.on("error", (err) => {
      console.error("[OpenClaw] Error:", err.message);
    });
  }

  private handleMessage(msg: Record<string, unknown>) {
    const type = msg.type as string;

    // Step 1: Challenge → build structured payload → sign → send connect
    if (type === "event" && msg.event === "connect.challenge") {
      const challenge = msg.payload as { nonce: string; ts: number };
      console.log("[OpenClaw] Received challenge, building auth payload...");

      const deviceId = deriveDeviceId(this.keypair.publicKeyRaw);
      const clientId = "gateway-client";
      const clientMode = "backend";
      const role = "operator";
      const scopes = ["operator.read", "operator.write"];
      const signedAt = Date.now();

      // Build structured payload: v2|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce
      const authPayload = [
        "v2",
        deviceId,
        clientId,
        clientMode,
        role,
        scopes.join(","),
        String(signedAt),
        this.token,
        challenge.nonce,
      ].join("|");

      // Ed25519 sign using Node crypto (same lib as gateway verification)
      const signature = crypto.sign(
        null,
        Buffer.from(authPayload, "utf-8"),
        this.keypair.privateKey
      );

      console.log(
        `[OpenClaw] Signed payload (${authPayload.length} bytes)`
      );

      this.sendJSON({
        type: "req",
        id: String(++this.requestId),
        method: "connect",
        params: {
          minProtocol: 3,
          maxProtocol: 3,
          role,
          scopes,
          caps: [],
          commands: [],
          permissions: {},
          auth: {
            token: this.token,
            ...(this.deviceToken ? { deviceToken: this.deviceToken } : {}),
          },
          client: {
            id: clientId,
            version: "1.0.0",
            platform: "node",
            mode: clientMode,
          },
          device: {
            id: deviceId,
            publicKey: this.keypair.publicKeyBase64Url,
            signature: base64UrlEncode(signature),
            signedAt,
            nonce: challenge.nonce,
          },
          locale: "en-US",
          userAgent: "vera-bridge/1.0.0",
        },
      });
      return;
    }

    // Step 2: Handle hello-ok
    if (type === "res") {
      const payload = msg.payload as Record<string, unknown> | undefined;

      if ((msg as any).ok === true && payload?.type === "hello-ok") {
        const auth = payload.auth as { deviceToken?: string } | undefined;
        if (auth?.deviceToken) {
          this.deviceToken = auth.deviceToken;
          console.log(
            `[OpenClaw] Device token received: ${this.deviceToken.substring(0, 16)}...`
          );
        }
        console.log("[OpenClaw] Connected and authenticated!");
        this.connected = true;
        return;
      }

      // Handle error response
      if ((msg as any).ok === false) {
        console.error(
          "[OpenClaw] Auth failed:",
          (msg as any).error || JSON.stringify(payload)
        );
        return;
      }
    }

    // Step 3: Handle agent response events
    if (type === "event") {
      const event = msg.event as string;
      const payload = msg.payload as Record<string, unknown> | undefined;

      if (
        event === "message.responded" ||
        event === "agent.message" ||
        event === "message.created"
      ) {
        const text = (payload?.text || payload?.content || "") as string;
        if (text) {
          this.onResponse(text);
        }

        // Check for tool calls (e.g., phone calls)
        const toolCalls = payload?.toolCalls as
          | Array<Record<string, unknown>>
          | undefined;
        if (toolCalls) {
          for (const tc of toolCalls) {
            const name = (tc.name || tc.function) as string;
            const params = (tc.params || tc.arguments || {}) as Record<
              string,
              unknown
            >;
            this.onToolCall(name, params);
          }
        }
      }
    }
  }

  /** Send a user message to OpenClaw */
  sendMessage(text: string) {
    if (!this.connected) {
      console.warn("[OpenClaw] Not connected, dropping message:", text);
      return;
    }

    console.log(`[OpenClaw] Sending: "${text.substring(0, 60)}..."`);
    this.sendJSON({
      type: "req",
      id: String(++this.requestId),
      method: "message.send",
      params: {
        session: "main",
        text,
      },
    });
  }

  get isConnected() {
    return this.connected;
  }

  private sendJSON(obj: unknown) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(obj));
    }
  }

  close() {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws?.close();
  }
}
