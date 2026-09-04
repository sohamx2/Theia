# Current-screen Qwen3-VL benchmark

This experiment compares two local pipelines on the same screenshot:

1. Current Theia: macOS Vision OCR, Theia context analysis and cascade
   classification, then `qwen3:4b` prompt expansion.
2. Direct vision: one structured `qwen3-vl:4b-instruct` request reads the PNG,
   selects the active subject, classifies it, and generates four prompt cards.

The direct-vision service rejects non-loopback Ollama URLs so captured screen data
cannot accidentally be sent to a remote endpoint.

## Setup

```bash
/Applications/Ollama.app/Contents/Resources/ollama pull qwen3-vl:4b-instruct
```

Qwen3-VL requires Ollama 0.12.7 or newer. The tested model is the 3.3 GB 4B
instruct checkpoint, chosen to match the current 4B text model as closely as
possible while retaining reliable structured output.

## Build

Compile `Tests/CurrentScreenVisionBenchmark.swift` with the same model and service
sources used by the Theia app. The command-line runner accepts a PNG or JPEG via
`--screenshot`, plus optional repeated `--expected-term` and
`--distractor-term` checks. Pass `--activity-next-steps` to exercise the
production untemplated prompt mode used by the Qwen3-VL model option and the
automatic `Other` fallback.

The report gives each pipeline:

- up to 40 quality points for central-subject grounding;
- up to 40 points for structure, uniqueness, query safety, and action/question
  semantic alignment;
- up to 20 points for ignoring supplied distractor terms;
- an overall rank weighted 80% quality and 20% relative latency.

This is an exploratory one-screen comparison. It cannot pass Theia's model
replacement gate; that still requires a labeled held-out screenshot corpus and
the thresholds described in `REAL_SCREENSHOT_BENCHMARK.md`.
