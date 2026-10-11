# ztype App Icon

The selected 1024 x 1024 PNG is AI-generated, with a charcoal lowercase `z`,
a teal insertion caret, a near-white tile and transparency outside the tile.
The original PNG alpha is retained during standard iconset resizing.

- Source: `Resources/AppIcon.png`
- macOS package: `Resources/AppIcon.icns`
- Reproduction of packaging: `./script/build_icon.sh`
- Generation mode: AI-generated raster image. The selected asset is the original
  generation, not a third-party application's icon.
- The outer edge has minor artifacts visible at large magnification. This is not
  represented as a manually perfected vector mark.

## Selected Generation Prompt

```text
Use case: logo-brand
Asset type: final production macOS application icon, square 1024 x 1024 bitmap, for the independent typing-autocomplete utility named ztype.
Primary request: one original polished macOS icon built around a bold lowercase z monogram and a crisp vertical text insertion caret immediately to its right, suggesting inline typing completion. A compact, memorable silhouette, clear at 32 pixels.
Style/medium: meticulously designed native app icon, restrained tactile depth and clean edges, very subtle porcelain finish, not a glossy toy, not a screenshot or a presentation mockup.
Composition: a single large centered soft-square macOS icon tile with the standard continuous rounded corners, front-facing orthographic view, approximately 90% of the canvas, generous but not excessive internal padding. The z and caret form one centered balanced mark. Mark is charcoal and teal, using the restrained teal of a productivity application; background tile is clean near-white. Keep the z distinctly lowercase, no wordmark.
Background: transparent alpha outside the rounded icon tile if supported; otherwise completely uniform white outside the tile. No checkerboard pattern. No enclosing white square frame. Soft subtle edge shading only, no broad cast shadow.
Constraints: only one icon, no grid, no text other than the lowercase z, no brand slogans, no watermark, no sparkles, no keyboard or document illustration, no perspective, no alternate variants.
```
