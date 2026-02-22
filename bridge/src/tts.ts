import WebSocket from "ws";

/**
 * Smallest AI Waves TTS — real-time text-to-speech.
 * Sends text as JSON, receives JSON chunks with base64-encoded PCM16 audio.
 */
export class TTSClient {
  private apiKey: string;

  onAudioChunk: (pcm16: Buffer) => void = () => {};
  onSpeakingStart: () => void = () => {};
  onSpeakingEnd: () => void = () => {};

  constructor(apiKey: string) {
    this.apiKey = apiKey;
  }

  /** Synthesize text to speech. Opens a fresh WebSocket per utterance. */
  speak(text: string) {
    const url =
      "wss://waves-api.smallest.ai/api/v1/lightning-v2/get_speech/stream";

    const ws = new WebSocket(url, {
      headers: { Authorization: `Bearer ${this.apiKey}` },
    });

    let chunkCount = 0;
    let ended = false;

    ws.on("open", () => {
      console.log(`[TTS] Speaking: "${text.substring(0, 60)}..."`);
      ws.send(
        JSON.stringify({
          text,
          voice_id: "ashley",
          sample_rate: 16000,
          language: "en",
          add_wav_header: false,
        })
      );
    });

    ws.on("message", (data) => {
      const msg = data.toString();
      try {
        const json = JSON.parse(msg);

        if (json.status === "error") {
          console.error(`[TTS] API error: ${json.message}`);
          return;
        }

        if (json.status === "chunk" && json.data?.audio) {
          const pcm16 = Buffer.from(json.data.audio, "base64");
          chunkCount++;
          if (chunkCount === 1) {
            console.log(`[TTS] First audio chunk: ${pcm16.length} bytes`);
            this.onSpeakingStart();
          }
          if (chunkCount % 10 === 0) {
            console.log(`[TTS] Sent ${chunkCount} audio chunks`);
          }
          this.onAudioChunk(pcm16);
        }

        if (json.status === "complete") {
          console.log(`[TTS] Complete — ${chunkCount} chunks`);
          if (!ended) { ended = true; this.onSpeakingEnd(); }
          ws.close();
        }
      } catch {
        console.log(`[TTS] Non-JSON message: ${msg.substring(0, 80)}`);
      }
    });

    ws.on("close", () => {
      if (chunkCount > 0 && !ended) {
        ended = true;
        this.onSpeakingEnd();
      } else if (chunkCount === 0) {
        console.log("[TTS] Closed with no audio received");
      }
    });

    ws.on("error", (err) => {
      console.error("[TTS] Error:", err.message);
    });

    // Safety timeout
    setTimeout(() => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.close();
      }
    }, 30000);
  }
}
