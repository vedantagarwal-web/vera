import WebSocket from "ws";

/**
 * Smallest AI Waves TTS — real-time text-to-speech.
 * Sends text, receives PCM16 audio chunks back.
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

    let receivedAudio = false;

    ws.on("open", () => {
      console.log(`[TTS] Speaking: "${text.substring(0, 60)}..."`);
      ws.send(
        JSON.stringify({
          text,
          voice_id: "emily",
          sample_rate: 16000,
          language: "en",
          add_wav_header: false,
        })
      );
    });

    ws.on("message", (data) => {
      if (Buffer.isBuffer(data) || data instanceof ArrayBuffer) {
        const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
        if (!receivedAudio) {
          receivedAudio = true;
          this.onSpeakingStart();
        }
        this.onAudioChunk(buf);
      }
    });

    ws.on("close", () => {
      if (receivedAudio) {
        this.onSpeakingEnd();
      }
    });

    ws.on("error", (err) => {
      console.error("[TTS] Error:", err.message);
      if (receivedAudio) {
        this.onSpeakingEnd();
      }
    });

    // Safety timeout
    setTimeout(() => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.close();
      }
    }, 30000);
  }
}
