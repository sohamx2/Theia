# Security and privacy reporting

Theia processes screen captures, OCR text, browser context, local chat history, and optional web queries. Treat reports involving unintended capture, data disclosure, prompt injection, model-output leakage, or permission bypass as security-sensitive.

Do not include personal screenshots, private messages, API credentials, full OCR output, or chat-history files in a public issue.

Until a dedicated security contact is published, open a GitHub issue containing only a minimal, redacted description and clearly mark it as a security or privacy concern. Repository maintainers should move sensitive follow-up to a private channel before requesting logs or reproduction data.

Include when safe:

- The affected Theia version and build.
- macOS and Ollama versions.
- The configured Qwen model name.
- Reproduction steps using synthetic or fully redacted content.
- Whether the behavior requires web research, Qwen3-VL, Siri, or Developer UI.
