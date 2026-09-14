## [2026-09-14 12:00] | Task: Screenshots as JPEG

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> The observe screenshot goes out as JPEG quality 0.8 instead of PNG. Keep the 1280 longest-side rule; drop the 900 KB shrink loop if JPEG makes it moot.

### 🛠 Changes Overview
**Scope:** OpenComputerUseKit

**Key Actions:**
- **[Encoder]**: `boundedScreenshotData` scales the capture to a longest side of 1280 and encodes JPEG at quality 0.8. The 900 KB byte bound and its shrink loop are gone: a 1280-wide JPEG at this quality is a few hundred KB at most.
- **[Result item]**: `ToolResultContentItem.pngImage` is `jpegImage` with `image/jpeg`; the pi bridge's default image mime is `image/jpeg`.
- **[Names]**: `screenshotPNGData` is `screenshotData`; the format no longer sits in the name.
- **[cua.call]**: emits every image the tool took through the image frame and returns `{ text }` only, as `cua.screenshot` did; no picture exists in JavaScript for `write()` to put into the text output (which pi cuts at 100k characters). Docs in `ToolDefinitions`, `SKILL.md`, `cua-api.md`, `js-code-tool.md`.
- **[emitImage]**: the JavaScript global is gone; nothing in JavaScript holds a picture any more. Its mentions in `ToolDefinitions`, `SKILL.md`, `cua-api.md` and `js-code-tool.md` too.
- **[Tests]**: the bounded-screenshot tests assert the JPEG magic and the scaled pixel size instead of a byte cap.

### 🧠 Design Intent (Why)
A model prices an image by its pixel size, not its bytes (OpenAI docs, 2026-09-14). Bytes only cost upload time, and a screen PNG can reach 900 KB where the JPEG is a fraction of that.

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolResult.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/PiBridgeServer.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `docs/ARCHITECTURE.md`, `docs/SECURITY.md`, `docs/references/js-code-tool.md`, `docs/references/js-stream-protocol.md`
