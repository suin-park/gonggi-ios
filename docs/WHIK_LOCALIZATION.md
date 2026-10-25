# WHIK localization (en / ko / ja / zh-Hans)

## Files

| What | Where |
|---|---|
| App UI strings (all languages) | `Gonggi/Resources/Localizable.xcstrings` — key = English source text |
| Home-screen name, permission prompts | `Gonggi/Resources/{en,ko,ja,zh-Hans}.lproj/InfoPlist.strings` |
| Language state + lookup | `Gonggi/Features/Whik/AppLanguage.swift` (`AppLanguage`, `L(_:)`, `WhikDate`, `WhikAutoName`) |
| Server error → short localized line | `Gonggi/Features/Whik/WhikServerMessage.swift` |
| Guard (CI) | `scripts/check_localization.py` |

## Rules

- App code uses `L("English text")` or `L("Text with %@", arg)` / `L("%1$@ … %2$@", a, b)`. No per-screen
  dictionaries and no `if language == …` branches.
- First launch is English on every device. The choice (Profile › Settings › Language) is saved under
  `whik.language.v1` and applied at once: `AppLanguage` is `@Observable`, so every view that called `L(...)`
  re-renders — no view identity reset, capture / generation / viewer state is kept.
- Static copy must be computed (`static var x: String { L("…") }`), not `static let`, so it follows a language
  change.
- Dates shown by the app use `WhikDate` / `AppLanguage.shared.locale`; new automatic record names use
  `WhikAutoName`. Existing and user-typed names are never rewritten.
- System UI (permission prompts, keyboard, share sheet) follows the iPhone language; the app does not override it.
- Raw server messages are logged, not shown (`WhikServerMessage`). Guide text written by the analysis server is
  Korean only and is shown only when the app is in Korean (`AdvancedCaptureCopy.serverCopy`).
- The 3DGS web viewer page receives `lang=<code>`; its own loading text is served by the cloud app and is not
  yet localized there (the native overlay on top of it is).

## Scope

All screens reachable from the WHIK shell: Home, Capture (3D Space / 360° Space / 3D Object flows, guidance,
summary, processing), Library (search / sort / filters, detail, edit, share, import, unsent captures), viewers,
sign-in, Profile and settings sub-screens, notifications, errors, empty states and accessibility labels.
Hidden features (see `docs/WHIK_HIDDEN_FEATURES.md`) keep their Korean copy.

## Adding or changing a string

1. Use `L("New English text")` in code.
2. Add the key to `Localizable.xcstrings` with en / ko / ja / zh-Hans values (same placeholders).
3. Run `python3 scripts/check_localization.py` — it fails on a missing key, an empty language, a placeholder
   mismatch, or a Korean literal left in reachable code.

Unit tests run with `-whik.language.v1 ko` (scheme `Gonggi`) because older copy tests assert Korean text;
`WhikShellTests` switches languages explicitly.
