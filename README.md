# Glyphline

Native macOS usage ledger for OpenAI, Cursor, and Claude accounts.

Glyphline stores account metadata and historical usage locally, keeps credentials in the macOS Keychain, and supports both a regular window and menu bar surface.

## Development

```bash
rtk xcodegen generate
xcodebuild -project Glyphline.xcodeproj -scheme Glyphline -destination 'platform=macOS' build
xcodebuild test -project Glyphline.xcodeproj -scheme Glyphline -destination 'platform=macOS'
```
