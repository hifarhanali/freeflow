# FreeFlow (Motive Internal Build)

A Mac dictation app that runs entirely on-device and on approved infrastructure — no external API keys required.

- **Speech-to-text:** [WhisperKit](https://github.com/argmaxinc/WhisperKit) running locally on Apple Neural Engine / CPU
- **AI cleanup:** AWS Bedrock (Claude) via Motive's internal gateway

---

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon **or** Intel Mac
- Xcode Command Line Tools (`xcode-select --install`)
- AWS Bedrock bearer token (`AWS_BEARER_TOKEN_BEDROCK`)

---

## Build & Run

### 1. Install Xcode Command Line Tools

```bash
xcode-select --install
```

### 2. Clone the repo

```bash
git clone https://github.com/hifarhanali/freeflow.git
cd freeflow
```

### 3. Set your Bedrock credentials

Add to `~/.zshrc` (or `~/.bash_profile` on Intel):

```bash
export AWS_BEARER_TOKEN_BEDROCK="your-token-here"

# Optional: override the default Bedrock gateway URL
export BEDROCK_GATEWAY_URL="https://your-internal-gateway/v1"
```

Reload: `source ~/.zshrc`

### 4. Build

```bash
# Apple Silicon (M1 / M2 / M3 / M4)
make

# Intel Mac
make ARCH=x86_64

# Universal binary — runs on both
make ARCH=universal
```

The app is built at `build/FreeFlow Dev.app`.

### 5. Run

```bash
make run
```

Or double-click `build/FreeFlow Dev.app` in Finder.

### 6. Grant permissions on first launch

macOS will prompt for:

| Permission | Why |
|---|---|
| **Microphone** | Record your voice |
| **Accessibility** | Type transcribed text at your cursor |
| **Screen Recording** | Optional — improves context-aware cleanup |

For **Accessibility**: go to System Settings → Privacy & Security → Accessibility and toggle **FreeFlow Dev** on. The app detects the grant automatically within a few seconds — no restart needed.

---

## Usage

| Action | What happens |
|---|---|
| Hold **Right Option ⌥** | Records while held; transcribes on release |
| Select text + hold shortcut | Transforms selected text with your voice |

Shortcuts can be changed in **Settings → Dictation Shortcuts**.

---

## First-Run Model Download

On first dictation, WhisperKit downloads the speech model to:

```
~/Library/Application Support/huggingface/models/argmaxinc/whisperkit-coreml/
```

This is a one-time download. The default is **Base English (~140 MB)**. Larger models can be selected in **Settings → AI Models**:

| Model | Size | Notes |
|---|---|---|
| Base · English-only | ~140 MB | Default, fastest |
| Small · English-only | ~480 MB | More accurate |
| Large Turbo · multilingual | ~800 MB | Recommended for non-English |
| Large v3 · multilingual | ~950 MB | Best accuracy |

---

## Settings

Click the menu bar icon → **Settings**:

- **AI Models** — Whisper model size, Bedrock model ID
- **Dictation Shortcuts** — hold and toggle keys
- **Edit Mode** — transform selected text with voice commands
- **Custom Vocabulary** — names, acronyms, and jargon to preserve exactly
- **Custom Prompt** — override the default cleanup behaviour

---

## Rebuilding After Code Changes

```bash
pkill -x "FreeFlow Dev"; make run
```

Settings, shortcuts, and permissions are preserved across rebuilds — they are stored by bundle ID, not binary path.

---

## Privacy

- Audio is processed **entirely on-device** by WhisperKit and never leaves your Mac.
- Only the transcribed text is sent to AWS Bedrock for cleanup.
- No telemetry, no analytics, no third-party services.
