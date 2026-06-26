# AME Specification Migration Summary

## Overview

Migrated the AME (Zvame) specification from the `riscv-ame` repository's
UDB-dependent build pipeline to a self-contained document repository that
can produce PDF output without any external dependencies on UDB, LLVM
submodules, or Ruby ERB template processing.

## What was migrated

### Document source (`src/`)

| File | Origin | Notes |
|------|--------|-------|
| `riscv-spec.adoc` | `gen_src/top.adoc` | Main entry point; UDB path refs replaced with local paths |
| `intro.adoc` | `gen_src/intro.adoc` | Static copy, no UDB references |
| `programming_model.adoc` | `gen_src/programming_model.adoc` | Contains `udb:doc:*` cross-refs (resolved locally) |
| `state.adoc` | `gen_src/state.adoc` | Contains `udb:doc:*` cross-refs (resolved locally) |
| `datatypes.adoc` | `gen_src/datatypes.adoc` | Contains `udb:doc:*` cross-refs (resolved locally) |
| `parameters.adoc` | `gen_src/parameters.adoc` | Defines parameter anchors + cross-refs |
| `examples.adoc` | `gen_src/examples.adoc` | Contains `udb:doc:*` cross-refs (resolved locally) |
| `instructions.adoc` | `gen_src/instructions.adoc` | 10k+ lines; defines instruction anchors + wavedrom diagrams |
| `functions.adoc` | `gen_src/functions.adoc` | Defines function anchors + cross-refs |
| `glossary.adoc` | `gen_src/glossary.adoc` | Contains `udb:doc:*` cross-refs (resolved locally) |
| `contributors.adoc` | `gen_src/contributors.adoc` | UDB YAML reference removed |
| `xref-anchors.adoc` | New file | Stub anchors for base RISC-V ISA cross-refs (92 CSRs, fields, functions) |

### Images (`src/images/`)

- 106 wavedrom SVG diagrams (pre-rendered from original build)
- 6 custom SVG/PNG diagrams (ame_state, ame-square-*, zvame_regfiles, gemm-portable, ame_datapath, ame_logical_view)
- 3 docs-resources images (risc-v_logo.png, risc-v_logo.svg, draft.png)

### Fonts and theme (`docs-resources/`)

- `fonts/` — 32 font files (Petrona, Montserrat, JetBrainsMono, mplus, cmun)
- `themes/riscv-pdf.yml` — PDF theme configuration
- `images/` — RISC-V logo and draft watermark
- `global-config.adoc` — Asciidoctor global config

## External dependencies removed

| Dependency | Purpose | Replacement |
|-----------|---------|-------------|
| `riscv-unified-db` submodule | ERB template rendering, UDB data resolution | Pre-rendered adoc files committed directly |
| `scripts/gen.rb` | Template processor using `Udb::Resolver` | Eliminated; adoc files are now source-of-truth |
| `Udb::Resolver` | Resolved extension/instruction/CSR metadata from UDB YAML | All content materialized into static adoc |
| `Udb::Helpers::AsciidocUtils.resolve_links` | Converted UDB link syntax to adoc cross-refs | Links already resolved in gen_src output |
| `.adoc.erb` templates | ERB templates that queried UDB for dynamic content | Replaced by static `.adoc` files |
| UDB `ext/docs-resources/` submodule | Fonts, themes, images | Copied to local `docs-resources/` |
| LLVM/toolchain submodule | Test compilation (not doc build) | Not needed for PDF generation |
| `mise` / UDB toolchain | Ruby/Node.js version management | Standard system Ruby + gems |

## Resources that must remain local

1. **`docs-resources/fonts/`** — Required by the PDF theme for rendering
2. **`docs-resources/themes/riscv-pdf.yml`** — PDF styling configuration
3. **`docs-resources/images/`** — RISC-V logo and draft watermark
4. **`src/images/`** — All wavedrom diagrams and custom figures
5. **`src/xref-anchors.adoc`** — Stub anchors for base RISC-V ISA references

## Build instructions

### Prerequisites

```
gem install asciidoctor asciidoctor-pdf asciidoctor-diagram asciidoctor-lists rouge
npm install -g wavedrom-cli    # for wavedrom diagram rendering
```

### Build

```
make pdf
```

Output: `build/Zvame-0.1.pdf`

### Build metadata

The PDF title page displays:
- **Commit**: 12-character short hash of HEAD
- **Build time**: UTC timestamp of the build

## Cross-reference strategy

The `udb:doc:*` anchor naming convention is preserved as-is in the adoc files.
These anchors are defined locally:

- **177 anchors** defined in `parameters.adoc`, `functions.adoc`, `instructions.adoc`
- **92 stub anchors** in `xref-anchors.adoc` for base RISC-V ISA references (CSRs,
  CSR fields, and functions defined in the privileged spec)

All ~2030 cross-references resolve within the document without UDB.
