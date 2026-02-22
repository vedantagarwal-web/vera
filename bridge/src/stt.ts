import WebSocket from "ws";

/**
 * Smallest AI Pulse STT — real-time speech-to-text.
 * Streams PCM16 audio in, receives JSON transcription events out.
 */
export class STTClient {
  private ws: WebSocket | null = null;
  private apiKey: string;
  private reconnectAttempts = 0;
  private maxReconnects = 10;

  onTranscript: (text: string, isFinal: boolean) => void = () => {};

  constructor(apiKey: string) {
    this.apiKey = apiKey;
  }

  connect() {
    // Config goes in query params, not JSON message
    const url =
      "wss://waves-api.smallest.ai/api/v1/pulse/get_text?language=en&sample_rate=16000&encoding=linear16";
    this.ws = new WebSocket(url, {
      headers: { Authorization: `Bearer ${this.apiKey}` },
    });

    this.ws.on("open", () => {
      console.log("[STT] Connected to Smallest AI Pulse");
      this.reconnectAttempts = 0;
    });

    this.ws.on("message", (data) => {
      try {
        const msg = JSON.parse(data.toString());
        // API uses "transcript" field, not "text"
        const text = msg.transcript || msg.text || "";
        if (text) {
          const isFinal = msg.is_final === true;
          this.onTranscript(text, isFinal);
        }
      } catch {
        console.log("[STT] Non-JSON message:", data.toString().substring(0, 80));
      }
    });

    this.ws.on("close", (code, reason) => {
      console.log(`[STT] Disconnected (code: ${code}, reason: ${reason.toString() || "none"})`);
      this.maybeReconnect();
    });

    this.ws.on("error", (err) => {
      console.error("[STT] Error:", err.message);
    });
  }

  /** Send raw PCM16 audio bytes for transcription */
  sendAudio(pcm16: Buffer) {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(pcm16);
    }
  }

  /** Signal end of speech */
  endSpeech() {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: "finalize" }));
    }
  }

  private maybeReconnect() {
    if (this.reconnectAttempts < this.maxReconnects) {
      this.reconnectAttempts++;
      const delay = Math.min(1000 * 2 ** this.reconnectAttempts, 10000);
      console.log(`[STT] Reconnecting in ${delay}ms...`);
      setTimeout(() => this.connect(), delay);
    }
  }

  close() {
    this.reconnectAttempts = this.maxReconnects; // prevent reconnect
    this.ws?.close();
  }
}
