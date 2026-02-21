import WebSocket from "ws";

/**
 * Smallest AI Pulse STT — real-time speech-to-text.
 * Streams PCM16 audio in, receives JSON transcription events out.
 */
export class STTClient {
  private ws: WebSocket | null = null;
  private apiKey: string;
  private reconnectAttempts = 0;
  private maxReconnects = 5;

  onTranscript: (text: string, isFinal: boolean) => void = () => {};

  constructor(apiKey: string) {
    this.apiKey = apiKey;
  }

  connect() {
    const url = "wss://waves-api.smallest.ai/api/v1/pulse/get_text";
    this.ws = new WebSocket(url, {
      headers: { Authorization: `Bearer ${this.apiKey}` },
    });

    this.ws.on("open", () => {
      console.log("[STT] Connected to Smallest AI Pulse");
      this.reconnectAttempts = 0;

      // Send initial config
      this.ws?.send(
        JSON.stringify({
          type: "config",
          sample_rate: 16000,
          language: "en",
        })
      );
    });

    this.ws.on("message", (data) => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.text) {
          this.onTranscript(msg.text, msg.is_final === true);
        }
      } catch {
        // ignore non-JSON messages
      }
    });

    this.ws.on("close", () => {
      console.log("[STT] Disconnected");
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
      this.ws.send(JSON.stringify({ type: "end" }));
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
