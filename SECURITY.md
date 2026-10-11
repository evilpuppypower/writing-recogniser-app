# Security

## Reporting a problem

Please report security or privacy problems privately, through GitHub's
**Security → Report a vulnerability** on this repository. Please don't open
a public issue for them.

## What the app does with your data

- Everything stays on the device: PDFs, handwriting, corrections and
  settings. Android's cloud backup is turned off for the app's data.
- The only network use is optional and labelled in the app: downloading
  Google ML Kit's handwriting model, and MyScript Cloud recognition, which
  sends pen strokes only (no PDFs, no text) when the user picks that engine.
- Connections are https only.
- Source PDFs are never changed; exports are new files.

## Builds

APKs built by CI are only published inside a password-protected zip. They
are test builds for the project owner, not releases.

Nobody from this project will send you an APK, a download link or a zip
password, in an issue, a comment or anywhere else. Treat any such offer as
an attack.
