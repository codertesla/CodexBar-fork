---
summary: "Light/dark proof that Devin's official mark renders at the native 18pt slot and through the serve dashboard mask."
---

# Devin icon proof

Synthetic captures only. No account identifiers, tokens, or live quota data.

- `native-18pt-light-dark.png` — `ProviderBrandIcon.image(for: .devin)` at the app's 18pt template slot on light and dark surfaces.
- `serve-dashboard-light.png` / `serve-dashboard-dark.png` — serve dashboard card CSS (`18px` mask, Devin accent `#317CFF`) using bytes from `GET /icons/ProviderIcon-devin.svg` on a freshly built `CodexBarCLI serve`.

Regenerate:

```sh
CODEXBAR_DEVIN_ICON_PROOF_DIR=docs/screenshots/devin-icon \
  make test-fast FILTER='devin uses the official hexagonal mark'
```
