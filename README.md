# Theia

Theia is a privacy-conscious macOS menu-bar assistant that understands the active window and suggests useful next steps. It combines native screen capture and OCR with local Qwen models served by Ollama, using fast templates for recognizable tasks and direct visual reasoning for screens that do not fit a predefined category.

> Status: **Beta v1.0.0**. The project is under active development and its interfaces and local data formats may change.

## What Theia does

- Captures the frontmost macOS window with `⌘⇧A`.
- Extracts salient headings, body text, values, and the active browser URL while suppressing inactive tabs and unrelated chrome.
- Classifies shopping, travel, learning, coding, productivity, and other common activities through a rules/BERT/Qwen cascade.
- Uses fast prompt templates for clear, predefined tasks.
- Keeps the classification as **Other** for miscellaneous tasks, then asks Qwen3-VL to understand the screenshot and generate task-specific information and predictive next steps.
- Detects visual artifacts that OCR cannot adequately represent and can route them to Qwen3-VL.
- Expands prompts into direct answers or named recommendations with individual links when a list is genuinely useful.
- Supports local Qwen chat, safe live streaming for text chat, screenshot chat through Qwen3-VL, and clean prompt-to-chat continuation.
- Keeps Qwen reasoning hidden from the standard interface; diagnostics are available only through the optional Developer UI.
- Integrates with Siri and Shortcuts without keeping Theia's microphone open.
- Supports resizable, movable, optionally always-on-top windows and remembers window placement.

## Privacy model

Screen capture, OCR, classification, prompt generation, and chat are local by default. Qwen requests are sent to the configured Ollama endpoint, which defaults to `http://127.0.0.1:11434`.

Theia can optionally perform web research for answers that require current sources. Internet access is controlled in Settings and can be configured to ask first, remain offline, or use the selected policy. A web-grounded answer may send a generated search query to the configured search provider. The screenshot itself is not sent to a web search provider.

Local state includes preferences, prompt templates, analysis output, intent memory, and chat history. Do not commit local screen captures or runtime data; the repository's `.gitignore` excludes the known generated locations and screen-specific benchmark artifacts.

## Requirements

- A Mac running macOS 14 Sonoma or newer. The Xcode target supports macOS 13, but Ollama's current macOS distribution requires macOS 14 or newer.
- Apple silicon is recommended. Ollama also supports Intel Macs using CPU inference.
- Xcode with the macOS SDK for source builds.
- [Ollama](https://docs.ollama.com/macos) 0.12.7 or newer for Qwen3-VL.
- Several gigabytes of free storage for local models.

The default models occupy roughly 6 GB combined, plus Ollama runtime and cache overhead:

| Purpose | Default model | Approximate download |
| --- | --- | ---: |
| Text classification, prompting, and chat | `qwen3:4b` | About 2.5 GB |
| Screenshot understanding | `qwen3-vl:4b-instruct` | About 3.3 GB |

Smaller text options (`qwen3:0.6b` and `qwen3:1.7b`) are available in Theia Settings.

## Install Ollama and Qwen

### 1. Install Ollama on macOS

1. Download Ollama from the [official macOS download page](https://ollama.com/download/mac).
2. Open the disk image and drag **Ollama.app** into `/Applications`.
3. Launch Ollama once. If prompted, allow it to add the `ollama` command to `/usr/local/bin`.
4. Confirm the installation:

```bash
ollama --version
```

If `ollama` is not in your shell path, use its bundled executable directly:

```bash
/Applications/Ollama.app/Contents/Resources/ollama --version
```

Ollama's official macOS guide lists current system requirements and storage locations: [docs.ollama.com/macos](https://docs.ollama.com/macos).

### 2. Download the default Qwen models

Start Ollama, then pre-download Theia's default text and vision models:

```bash
ollama pull qwen3:4b
ollama pull qwen3-vl:4b-instruct
```

Qwen3-VL requires Ollama 0.12.7 or newer. Available sizes and current download details are listed in the [official Qwen3-VL model library](https://ollama.com/library/qwen3-vl).

Theia can also download a selected missing model automatically. Manual pulls are recommended because they make first launch faster and expose download errors directly in Terminal.

Optional faster text models:

```bash
ollama pull qwen3:0.6b
ollama pull qwen3:1.7b
```

Verify the installed models and local server:

```bash
ollama list
curl http://127.0.0.1:11434/api/tags
```

If you run Ollama at another local address, update **Settings → Ollama address** in Theia.

## Build and run Theia

### Xcode

1. Clone the repository and open `Theia.xcodeproj`.
2. Select the **Theia** scheme and **My Mac** destination.
3. Set a development team under **Signing & Capabilities** if Xcode requests one.
4. Build and run with `⌘R`.
5. On first analysis, grant Screen Recording access under **System Settings → Privacy & Security → Screen Recording**.
6. Restart Theia after changing Screen Recording permission.

### Command line release build

```bash
xcodebuild \
  -project Theia.xcodeproj \
  -scheme Theia \
  -configuration Release \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

codesign --force --deep --sign - \
  .build/DerivedData/Build/Products/Release/Theia.app
```

The ad-hoc signature is suitable for local development. Distribution builds should use a Developer ID certificate, hardened runtime, notarization, and an explicit release process.

To install the local build:

```bash
ditto .build/DerivedData/Build/Products/Release/Theia.app /Applications/Theia.app
```

## First-run setup

The onboarding flow configures:

- Experience focus: Everyday, Work, or Learning.
- Response style: Concise, Balanced, or Exploratory.
- Siri/Shortcuts guidance.

Useful settings include:

- Text model: Fast, Balanced, Best Quality, or Qwen3-VL.
- Qwen text context: 8K, 16K, or 32K.
- Qwen3-VL context: Efficient, Balanced, or Extended.
- Paths per prompt: one to three, producing four to twelve total paths.
- Optional internet access and preferred search engine.
- Pin/unpin window behavior.
- Developer UI visibility.

Prompt expansions use up to 512 output tokens. Direct Qwen chat uses up to 1,024 output tokens.

## Using Theia

### Screen analysis

Choose **Analyze Screen** from the menu bar or press `⌘⇧A`. Theia captures only the frontmost window, extracts the highest-value content, classifies the activity, and displays four primary prompts.

Each prompt exposes one path by default. Change **Paths per prompt** in Settings to show two or three paths per prompt. Multiple expanded answers may remain open and can be reached by scrolling.

### Qwen chat

Choose **New Chat with Qwen** for a clean local chat. A screenshot attachment automatically routes the request to Qwen3-VL. Text-only chat streams safe answer content live.

**Continue in Qwen** starts from the same clean model configuration as a new chat. The selected prompt and existing answer are provided as read-only active context rather than copied into conversation history.

### Siri and Shortcuts

Theia exposes these App Intents:

- **Analyze Screen with Theia**
- **Ask Theia**
- **Show a Theia Prompt**

Example phrases include:

- “Hey Siri, ask Theia to analyze my screen.”
- “Hey Siri, ask Theia why this result matters.”
- “Hey Siri, ask Theia to show one.”
- “Hey Siri, ask Theia to show the top ten restaurants.”

If Siri does not discover the app action, open the Shortcuts app, create a shortcut with the corresponding Theia action, give it a natural spoken name, and run it once. Theia also supports the local `theia://` command scheme for Shortcut workflows.

## Architecture

```text
Frontmost window
    │
    ├─ ScreenCaptureKit / native capture
    ├─ Apple Vision OCR
    └─ Active browser URL context
             │
             ▼
    Salience and privacy filtering
             │
             ▼
    Rules → BERT embeddings → Qwen classifier
             │
      ┌──────┴────────┐
      │ known task    │ Other / visual fallback
      ▼               ▼
 Fast templates     Qwen3-VL understanding
      └──────┬────────┘
             ▼
 Four prompts and optional expansions
             │
             ├─ Local Qwen answer
             ├─ Optional web-grounded answer
             └─ Clean continuation in Qwen chat
```

Important modules:

| Area | Main files |
| --- | --- |
| App lifecycle and window coordination | `TheiaApp.swift`, `App/AppCoordinator.swift`, `App/AppState.swift` |
| Screen capture and OCR | `Services/ScreenCaptureService.swift`, `Services/OCRService.swift` |
| Context and intent analysis | `Services/ContextAnalysisService.swift`, `Services/IntentClassificationService.swift` |
| Prompt generation and expansion | `Services/IntentPromptSuggestionService.swift`, `Services/PromptSummaryService.swift` |
| Qwen and Qwen3-VL | `Services/QwenChatService.swift`, `Services/QwenVisionPromptService.swift`, `Services/OllamaRuntimeManager.swift` |
| Siri and Shortcuts | `Services/SiriIntentService.swift`, `Services/SiriCommandInterpreter.swift` |
| SwiftUI interface | `UI/` |
| Regression and evaluation suites | `Tests/`, `BenchmarkResults/` |

## Development and testing

Build before submitting a change:

```bash
xcodebuild \
  -project Theia.xcodeproj \
  -scheme Theia \
  -configuration Debug \
  -derivedDataPath .build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the local regression suite:

```bash
./Scripts/run-regressions.sh
```

The regression runner compiles each standalone test against the application sources and covers prompt contracts, chat persistence, model memory isolation, internet routing, prompt-template customization, temporal freshness, and website classification.

Some benchmark modes call local Ollama models and are intentionally slower. They are documented in `Tests/` and should be run when changing model routing, prompt contracts, context limits, or classification policy.

See [CONTRIBUTING.md](CONTRIBUTING.md) for coding, privacy, UI, and model-output guidelines.

## Troubleshooting

### “Ollama is not installed”

Launch `/Applications/Ollama.app`, verify `ollama list`, and confirm that `http://127.0.0.1:11434/api/tags` responds. Theia can locate the CLI inside the Ollama application even when the shell link is unavailable.

### Model download or format errors

Update Ollama, then pull the exact configured model again:

```bash
ollama pull qwen3:4b
ollama pull qwen3-vl:4b-instruct
```

Use `ollama list` to confirm the names. Avoid substituting similarly named legacy or cloud-only tags unless you also change Theia's model configuration.

### Screen analysis cannot start

Grant Screen Recording access to the exact copy of Theia you are running. Moving or rebuilding an app may cause macOS to treat it as a different signed application and require permission again.

### Dense screenshots exceed context or run slowly

Theia downsizes the visual payload while retaining the original image for native OCR. Choose a larger Qwen3-VL context in Settings only when needed; larger windows consume more unified memory and can reduce speed.

### Siri cannot find Theia

Install Theia in `/Applications`, launch it once, open Shortcuts, add a Theia action, and run the shortcut once so macOS can index it. Siri owns voice recognition; Theia does not keep the microphone active.

## Security

Please do not open a public issue containing screenshots, OCR output, chat history, local paths, or model logs with personal information. Follow [SECURITY.md](SECURITY.md) for reporting security or privacy concerns.

## License

No open-source license has been granted yet. Unless a license is added, the source remains under its default copyright protection.
