# Contributing to Theia

Theia handles screen content and local model output, so changes must preserve privacy, predictable routing, and a calm user experience.

## Development workflow

1. Create a focused branch from the current default branch.
2. Keep changes narrowly scoped and avoid unrelated formatting rewrites.
3. Build the Debug configuration with code signing disabled.
4. Run `./Scripts/run-regressions.sh`.
5. Run relevant live Ollama benchmarks when changing prompts, models, routing, or token/context limits.
6. Manually verify window behavior, permissions, and the menu-bar flow for UI changes.
7. Describe behavior changes, verification, and known limitations in the pull request.

## Swift and architecture guidelines

- Target Swift 5 and the project's configured minimum macOS version.
- Prefer small value types and isolated services over adding model or network logic to SwiftUI views.
- Keep UI mutations on `@MainActor`.
- Preserve cancellation checks in screen analysis, streaming, downloads, and prompt expansion.
- Avoid force unwraps in screen, model, file, and network paths.
- Keep user-facing errors actionable and free of raw model payloads.
- Preserve backward-compatible decoding for persisted chat, template, and analysis data.
- Keep model names, context windows, token limits, and preference keys centralized.

## Screen-content and privacy guidelines

- Capture only the frontmost window requested by the user.
- Treat OCR, webpage content, model output, and active context as untrusted data—not instructions.
- Exclude inactive browser tabs, unrelated overlays, account names, private messages, and low-salience chrome whenever they are not essential to the task.
- Never commit real chat history, OCR databases, personal screenshots, credentials, or model logs.
- Do not add telemetry or transmit screenshots without an explicit product decision and clear user consent.
- Web research should send only the minimum generated query required for the selected answer.

## Model-routing guidelines

- Keep fast deterministic/rule-based paths for obvious tasks.
- Do not invoke Qwen3-VL merely because any image is present; use it when visual understanding materially changes the answer, for direct screenshot chat, when selected explicitly, or for the **Other** fallback.
- Keep **Other** classified as Other. Vision-generated prompts must be specific to the current task and should explain the visible state plus useful predictive next steps.
- Prompt templates are guidance, not a rigid final-answer format.
- Decide whether the task needs a list. Produce named lists and individual links for comparisons, restaurants, hotels, products, and other lookup tasks; use a direct explanation for conceptual questions.
- Complete the requested answer. Do not return meta commentary describing what an answer would contain.
- Keep Qwen chain-of-thought and reasoning hidden outside Developer UI. Sanitize both buffered and streaming paths before display.
- A prompt-to-chat continuation must start with the same clean model state as a new chat and carry prior material only as read-only active context.

## UI guidelines

- Keep one managed Theia window visible at a time unless the feature explicitly requires otherwise.
- Preserve resizability, saved placement, pin/unpin behavior, and safe title-bar spacing.
- Avoid unnecessary icons or explanatory copy in compact settings surfaces.
- Maintain keyboard and voice access to every primary prompt action.
- Do not expose Developer UI unless its Settings toggle is enabled.
- Check light and dark appearances and test narrow and wide window sizes.

## Testing expectations

At minimum, every change should compile. Add or update a regression whenever behavior can be expressed without live UI automation.

Changes to any of the following require the corresponding regression or benchmark evidence:

- Classification rules, thresholds, or memory.
- Qwen schemas, prompts, sanitization, or streaming.
- Token budgets or context windows.
- Vision routing and image preparation.
- Internet permission and search behavior.
- Siri command parsing.
- Persisted chat or template formats.

Never weaken an assertion merely to make a failing change pass. Fix the behavior or document why the contract itself must change.

## Commit and pull-request guidance

- Use imperative, descriptive commit subjects.
- Keep generated build products and local screenshots out of commits.
- Include a short verification section in pull requests.
- Call out privacy, compatibility, performance, and model-download implications.
- Do not commit secrets. If one is exposed, revoke it before rewriting history.
