## [2026-09-18 20:40] | Task: Metallic yellow software cursor with a radiant glow

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> Make the cursor purely yellow, with a metallic, shiny, god-like glow.

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`

**Key Actions:**
- **[Repainted glyph]**: The reference cursor PNG is repainted once at load (`divineYellow`): pointer fill becomes polished yellow metal (diagonal ramp with one specular band), the outline a bright rim, and the fog is pulled in to a tight yellow aura that brightens toward the pointer (toned down after a live run read as too shiny on top).
- **[Test]**: The reference-image test now also checks that the wide fog is gone, and that the aura and the (opaque) pointer fill are yellow.

### 🧠 Design Intent (Why)
The overlay draws the bundled reference PNG, not the procedural colors, so the change has to happen on the image. The artwork is three flat grays (fog, fill, outline), which makes each part separable per pixel by gray level and lets the fog's own falloff drive the aura. The look was picked by the user from four rendered options (metal + tight glow, no rays). Repainting at load keeps the extracted reference asset untouched and costs nothing per frame. `glowTightness` sets the aura size (1 = the fog's full size). The procedural fallback (only used when the PNG is missing) is unchanged.

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorGlyphRenderer.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
