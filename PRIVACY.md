# Privacy Policy for Bolo

**Last Updated:** January 2026

## Overview

Bolo ("the App") is a voice-to-text dictation application for macOS. Your privacy is important to us. This policy explains what data we collect, how we use it, and your rights regarding your information.

## Summary

- **We do not store your voice recordings**
- **We do not store your transcriptions on our servers**
- **Your data stays on your device**
- **We use Google's Gemini API for processing (subject to their privacy policy)**

---

## Information We Collect

### Voice Data

When you use Bolo to dictate text:
- Your voice is recorded temporarily on your device
- The audio is sent to Google's Gemini API for transcription and processing
- The audio is discarded immediately after processing
- We do not retain, store, or have access to your voice recordings

### Text Data

- Transcribed text is inserted directly into your active application
- Your personal dictionary is stored locally on your device
- Transcription history (if enabled) is stored locally on your device
- We do not transmit or store your transcribed text on any server we control

### Usage Data

We do not collect:
- Analytics or usage statistics
- Crash reports
- Personal information
- Device identifiers

### API Key

- Your Gemini API key is stored securely in your Mac's Keychain
- The key is only used to authenticate with Google's Gemini API
- We never transmit your API key to any server other than Google's

---

## Third-Party Services

### Google Gemini API

Bolo uses Google's Gemini API to process your voice recordings. When you use Bolo:
- Your audio is transmitted to Google's servers for processing
- Google's privacy policy applies to this data: https://policies.google.com/privacy
- Google may process your audio according to their terms of service

We recommend reviewing Google's privacy policy to understand how they handle your data.

---

## Data Storage

### Local Storage

The following data is stored locally on your Mac:
- Personal dictionary entries (`~/Library/Application Support/Bolo/`)
- App settings and preferences
- Transcription history (if enabled)
- Gemini API key (in macOS Keychain)

### Cloud Storage

Bolo does not use cloud storage. All your data remains on your device.

---

## Permissions

Bolo requires the following permissions:

### Microphone Access
- **Purpose:** To capture your voice for transcription
- **When used:** Only when you actively hold the dictation hotkey
- **Storage:** Audio is never stored; it's processed and discarded

### Accessibility Access
- **Purpose:** To insert transcribed text into applications and read text context
- **When used:** To detect focused text fields and insert text
- **Data accessed:** Current text selection and surrounding context (for formatting)

### Network Access
- **Purpose:** To communicate with Google's Gemini API
- **When used:** When processing voice recordings
- **Data transmitted:** Audio data and text prompts

---

## Data Security

We implement the following security measures:
- API keys are stored in macOS Keychain (encrypted)
- All API communications use HTTPS/TLS encryption
- No sensitive data is logged or cached unnecessarily
- Local database uses standard macOS file system protections

---

## Your Rights

You have the right to:
- **Access your data:** All data is stored locally on your Mac
- **Delete your data:** Remove the app and its data from `~/Library/Application Support/Bolo/`
- **Control your data:** Disable features like auto-learn dictionary in settings
- **Revoke permissions:** Remove microphone or accessibility access in System Settings

---

## Children's Privacy

Bolo is not directed at children under 13. We do not knowingly collect personal information from children.

---

## Changes to This Policy

We may update this privacy policy from time to time. We will notify you of any changes by:
- Updating the "Last Updated" date at the top of this policy
- Providing notice within the app for significant changes

---

## Contact Us

If you have questions about this privacy policy or Bolo's privacy practices, please contact us:

- **Email:** [your-email@example.com]
- **GitHub Issues:** https://github.com/[your-username]/bolo/issues

---

## Additional Information for App Store Review

### Microphone Usage
Bolo accesses the microphone solely for the purpose of voice-to-text transcription. Audio is captured only when the user explicitly activates recording by pressing the designated hotkey. Audio data is transmitted to Google's Gemini API for processing and is not stored locally or remotely by Bolo.

### Accessibility Usage
Bolo uses Accessibility APIs to:
1. Insert transcribed text into the active text field
2. Read selected text for Command Mode editing
3. Extract surrounding text context for improved formatting
4. Detect the active application for context-aware transcription

Bolo does not use Accessibility features to monitor user activity, capture keystrokes, or access data outside of the active text field context.

---

*This privacy policy is effective as of January 2026.*
