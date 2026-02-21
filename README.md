# Vera

An AI avatar skin for [OpenClaw](https://github.com/openclaw/openclaw) that gives it a face, voice, and the ability to make real phone calls from your iPhone.

Vera turns OpenClaw into a voice-first AI companion with a lip-synced avatar you can talk to naturally. OpenClaw handles all intelligence, tools, and memory — Vera adds the human interface.

## Architecture

```
┌─────────────────────┐                       ┌─────────────────────┐
│   iOS App           │   WebSocket (PCM16)   │   Vera Bridge       │
│                     │◄────────────────────►│   (Node.js :3001)   │
│  Simli Avatar       │                       │                     │
│  (WKWebView+WebRTC) │                       │  ┌───────────────┐  │
│                     │                       │  │ OpenClaw GW   │  │
│  Mic + Speaker      │                       │  │ (Ed25519 auth)│  │
│  (AVAudioEngine)    │                       │  └───────────────┘  │
│                     │                       │                     │
│  CallKit            │                       │  ┌───────────────┐  │
│  (native dialer)    │                       │  │ Smallest AI   │  │
│                     │                       │  │ STT + TTS     │  │
└─────────────────────┘                       │  └───────────────┘  │
                                              │                     │
                                              │  ┌───────────────┐  │
                                              │  │ Simli         │  │
                                              │  │ (avatar)      │  │
                                              │  └───────────────┘  │
                                              └─────────────────────┘
```

**How it works:**

1. You speak into your iPhone mic
2. Bridge streams audio to Smallest AI for real-time transcription
3. Transcribed text goes to your OpenClaw instance as a user message
4. OpenClaw responds with text — bridge synthesizes speech via Smallest AI TTS
5. Audio streams back to iPhone for playback + Simli lip-sync renders a talking avatar
6. If OpenClaw decides to call someone, it triggers CallKit on your iPhone — a real phone call from your number

## Components

| Component | Location | Purpose |
|-----------|----------|---------|
| **Bridge Server** | `bridge/` | Node.js proxy between iOS and OpenClaw. Handles voice I/O, avatar sessions, and the gateway handshake. |
| **iOS App** | `ios/` | SwiftUI app — fullscreen avatar face, mic button, CallKit integration. Zero local intelligence. |
| **OpenClaw Config** | `openclaw/` | Personality prompt (SOUL.md) to give OpenClaw Vera's character. |

## Prerequisites

- iPhone running iOS 17+
- Mac with Xcode 15+ (to build the app)
- [OpenClaw](https://github.com/openclaw/openclaw) running on a reachable machine (LAN or Tailscale)
- [Smallest AI](https://smallest.ai) API key (voice)
- [Simli](https://simli.com) API key (avatar)
- Node.js 18+

## Setup

### 1. Configure OpenClaw

Copy Vera's personality to your OpenClaw workspace:

```bash
cp openclaw/SOUL.md ~/.openclaw/workspace/SOUL.md
```

Make sure your gateway is accessible (bound to LAN or Tailscale) with auth enabled:

```bash
openclaw gateway status
```

### 2. Start the Bridge

```bash
cd bridge
cp .env.example .env
# Fill in your API keys and OpenClaw gateway details in .env
npm install
npm run dev
```

The bridge will connect to OpenClaw and prompt you to approve the device pairing:

```bash
openclaw devices list
openclaw devices approve <request-id>
```

### 3. Build the iOS App

```bash
cd ios
brew install xcodegen  # if not installed
xcodegen generate
open Vera.xcodeproj
```

In Xcode:
1. Set your signing team (Signing & Capabilities)
2. Update `Config.swift` with your bridge server's IP
3. Connect your iPhone and hit Cmd+R

## Tech Stack

- **iOS**: Swift, SwiftUI, AVAudioEngine, CallKit, WKWebView (WebRTC)
- **Bridge**: TypeScript, Express, WebSocket, Node.js crypto (Ed25519)
- **Voice**: Smallest AI Pulse (STT) + Lightning (TTS)
- **Avatar**: Simli audio-to-video lip-sync via WebRTC
- **Intelligence**: OpenClaw (not bundled — runs on your own machine)

## License

MIT
