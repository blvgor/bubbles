# ADR 0006. Provider keys only in the keychain, network without a cache

## Context

The Claude and OpenAI keys are the user's secrets, and the repository is public. The requests carry the text of their tasks.

## Decision

Each provider's key is stored only in the macOS keychain, under its own service name. It is not written to files, does not get into the app settings and is not printed to a log. The key is read and written only through one keychain-store layer. In the settings window the key is entered in a secure field and is not shown back; "Check" and "Delete" are available. Requests to providers and the key check go through an ephemeral session with no URL cache: nothing is saved to disk.

## Why

- The keychain is the standard place for secrets: the data is encrypted and tied to the app.
- A file or the user's settings can be read by any process, end up in backups and may land in a repository.
- An ordinary session stores responses in a disk cache, and that would hold the texts of requests and answers with the person's tasks.

Considered and rejected:

- **App settings (UserDefaults) or a config file.** Stored in plain text.
- **An environment variable.** The app launches at login, not from a terminal, so it has no environment.
- **The standard URLSession session.** It caches responses to disk.

## Consequences

- A key does not move between Macs by itself: on a new machine it is entered again. The app has no backup.
- Because of the ad-hoc signature, after a rebuild the system may ask for permission to access the key again.
- Automated tests must not touch the real keychain, so this layer is thin and checked by hand, while the rest of the code receives the key as a string.
- Without a cache every request goes over a new connection and is slightly slower; a retry after a failure takes nothing from previous answers.
- Deleting a key is irreversible: it can only be restored from the provider's console.
