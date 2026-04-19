# Budgetero 💰
> AI-powered budget tracker for Filipino students — log expenses in seconds, get smart insights, and stay on track.

---

## Features
- **Natural language expense logging** — "Jollibee 120", "45 bread Food", voice input
- **Auto-categorization** via AI (Food, Transport, Bills, etc. — or any custom category)
- **Dashboard** with pie chart, spending breakdown, budget progress
- **Daily & weekly spending limits** — auto-calculated or set manually via chat
- **Smart notifications** — 70%, 90%, and over-budget alerts + daily reminder
- **Edit expenses & categories** — via chat or long-press on dashboard
- **Persistent storage** — all data saved locally on device

---

## Tech Stack
| Layer | Technology |
|---|---|
| Framework | Flutter (Dart) |
| AI / NLP | OpenAI GPT-4.1-mini |
| Charts | fl_chart |
| Notifications | flutter_local_notifications |
| Storage | shared_preferences |
| Speech | speech_to_text |

---

## Getting Started

### 1. Clone the repo
```bash
git clone https://github.com/YOUR_USERNAME/budgetero.git
cd budgetero
```

### 2. Install dependencies
```bash
flutter pub get
```

### 3. Set up your API key

API keys are **never stored in code**. They are passed in at run/build time using `--dart-define`.

**Copy the example file:**
```bash
cp dart_defines.example.json dart_defines.json
```

**Fill in your key** — open `dart_defines.json`:
```json
{
  "OPENAI_API_KEY": "sk-proj-YOUR_ACTUAL_KEY_HERE"
}
```

> Get your OpenAI key at: https://platform.openai.com/api-keys
> `dart_defines.json` is in `.gitignore` — it will never be committed.

---

### 4. Run the app

```bash
# Development
flutter run --dart-define-from-file=dart_defines.json

# Or pass the key directly (useful for CI)
flutter run --dart-define=OPENAI_API_KEY=sk-proj-xxxx
```

### 5. Build a release APK

```bash
flutter build apk --dart-define-from-file=dart_defines.json
```

---

## Android Setup (Notifications)

The `AndroidManifest.xml` already includes the required notification permissions. No extra steps needed.

If you are on Android 13+ the app will request notification permission on first launch.

---

## Project Structure

```
lib/
└── main.dart          # All app logic (single-file Flutter app)

android/
└── app/src/main/
    └── AndroidManifest.xml   # Permissions incl. POST_NOTIFICATIONS

dart_defines.example.json     # Template — copy to dart_defines.json and fill in
dart_defines.json             # YOUR secrets — gitignored, never commit this
.gitignore                    # Excludes secrets, build artifacts, IDE files
pubspec.yaml                  # Dependencies
```

---

## Environment Variables Reference

| Variable | Where to get it |
|---|---|
| `OPENAI_API_KEY` | https://platform.openai.com/api-keys |

---

## Contributing

1. Fork the repo
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Make sure `dart_defines.json` is **not** in your commit: `git status`
5. Open a pull request

---

## License
MIT
