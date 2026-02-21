# Vera — OpenClaw Personality Config

Copy these files into your OpenClaw workspace to give it Vera's personality.

## Setup

1. Copy the personality prompt:
   ```bash
   cp SOUL.md ~/.openclaw/workspace/SOUL.md
   ```

2. Set the model to Claude Opus in `~/.openclaw/openclaw.json`:
   ```json
   {
     "model": "anthropic/claude-opus-4-6"
   }
   ```

3. Restart OpenClaw:
   ```bash
   openclaw gateway restart
   ```

That's it. OpenClaw now responds as Vera.
