# ADR 0005. Dictation parsing: Claude or ChatGPT by choice, without a key a plain tracker

## Context

Speech has to be turned into tasks with urgency and time. That needs language parsing, but not everyone has a key, and depending on a single provider is undesirable.

## Decision

The user chooses the parsing provider: Claude or ChatGPT (OpenAI). Each has its own key and a free model field with a default value; both answer in the same line format. If no key is connected, the app works as a plain tracker: the microphone and the hotkey open text input, every line becomes a task exactly as written, with no parsing of time or urgency and no rephrasing; the person sets urgency and time in the editor. Dictation requires a key. If there is a key but the provider did not answer, the lines also become tasks as they are, and a pill explains the reason. Speech recognition is done by the system; the AI receives ready text.

## Why

- The user decides whether to hand text to an external service, and which one.
- An explicit refusal is more honest than a hidden substitution: the person sees their words as written, not someone else's guess.
- Two providers give a choice by price, availability and habit, and a shared answer format keeps the rest of the code the same.

Considered and rejected:

- **Steps without a key: Apple Foundation Models, then a local model (llama.cpp and a small model of about 1 GB), then rules.** The project owner's decision: either connect a provider or work with text. Besides, the Apple model on the test machine did not support Russian; the local model needs a download of about a gigabyte with checksum verification and resume, does not work on an Intel Mac and pulls an external binary component into the build.
- **Claude only.** Tied to a single provider.
- **Local rules as a fallback parser when there is no key.** Rules silently distort phrases; a plain tracker without parsing is predictable.

## Consequences

- Without a key the product's main idea, dictating the day by voice, is unavailable. The first launch for a person without a key looks like a simple list.
- Dictation sends text to a third-party service; this has to be said plainly in the README and in the settings window.
- The user pays for use with their own key, and the "no credit" and "wrong key" errors have to be explained in the app.
- Two adapters and two sets of error texts have to be kept in sync; default model names go stale, so the model field is editable.
- The former local rule-based parsing was removed from the dictation path; whoever wants parsing without the internet will not get it.
