# Credits

Feather is built on these open-source projects. Each is used under its own licence; the full texts, with their
copyright notices, are collected in [THIRD-PARTY-LICENSES.txt](THIRD-PARTY-LICENSES.txt).

## In the app

| Project | Use | Version | Licence |
| --- | --- | --- | --- |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | the terminal panel | 1.20.0 | MIT |
| [Sparkle](https://sparkle-project.org) | in-app updates | 2.10.0 | MIT (with BSD and zlib parts) |
| [tree-sitter](https://github.com/tree-sitter/tree-sitter) | the parsing runtime behind highlighting and folding | 0.25.10 | MIT |
| [SwiftTreeSitter](https://github.com/tree-sitter/swift-tree-sitter) | the Swift bindings to it | 0.25.0 | BSD-3-Clause |
| [Material Icon Theme](https://github.com/material-extensions/vscode-material-icon-theme) | file icons in `Resources/icons` | — | MIT |

## Tree-sitter grammars

One C target each, built into the app. Their highlight queries are copied into `Resources/queries`
([README](Resources/queries/README.md)).

| Grammar | Version | Licence |
| --- | --- | --- |
| [tree-sitter-javascript](https://github.com/tree-sitter/tree-sitter-javascript) | 0.23.1 | MIT |
| [tree-sitter-typescript](https://github.com/tree-sitter/tree-sitter-typescript) (TypeScript and TSX) | 0.23.2 | MIT |
| [tree-sitter-python](https://github.com/tree-sitter/tree-sitter-python) | 0.23.6 | MIT |
| [tree-sitter-java](https://github.com/tree-sitter/tree-sitter-java) | 0.23.5 | MIT |
| [tree-sitter-dart](https://github.com/UserNobody14/tree-sitter-dart) | `be07cf7` | MIT |
| [tree-sitter-kotlin](https://github.com/fwcd/tree-sitter-kotlin) | 0.3.8 | MIT |
| [tree-sitter-swift](https://github.com/alex-pinkus/tree-sitter-swift) | 0.7.3 | MIT |
| [tree-sitter-json](https://github.com/tree-sitter/tree-sitter-json) | 0.24.8 | MIT |
| [tree-sitter-css](https://github.com/tree-sitter/tree-sitter-css) | 0.23.2 | MIT |
| [tree-sitter-html](https://github.com/tree-sitter/tree-sitter-html) | 0.23.2 | MIT |
| [tree-sitter-yaml](https://github.com/tree-sitter-grammars/tree-sitter-yaml) | 0.7.0 | MIT |
| [tree-sitter-bash](https://github.com/tree-sitter/tree-sitter-bash) | 0.25.1 | MIT |
| [tree-sitter-go](https://github.com/tree-sitter/tree-sitter-go) | 0.25.0 | MIT |
| [tree-sitter-rust](https://github.com/tree-sitter/tree-sitter-rust) | 0.24.2 | MIT |

Versions are the ones pinned in `Package.resolved` at the time of writing; that file is authoritative.

## Not part of Feather

- **Language servers** are not bundled. Feather uses the ones installed on the Mac (`typescript-language-server`,
  `pyright`, `jdtls`, `sourcekit-lsp`, `gopls`, `rust-analyzer`), each under its publisher's own licence.
- **AI assistants** (Claude Code, Codex, Gemini CLI, aider, Cursor Agent, opencode) are started in the terminal
  when they are installed. Feather installs nothing and talks to no AI service itself.
- `swift-argument-parser` appears in `Package.resolved` because SwiftTerm's command-line targets use it; the
  `SwiftTerm` library Feather links does not, and no code from it is in the app.
