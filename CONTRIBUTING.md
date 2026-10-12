# Contributing to Feather

Feather is a native macOS code editor written in Swift and AppKit. Bug reports, fixes, language support and
performance work are all welcome. This page says how the project is built and tested, what a change should
bring with it, and how the code is written, so a pull request can be reviewed quickly.

## Setting up

You need a Mac with macOS 13 or later and Xcode 16 or later. The Liquid Glass chrome needs the macOS 26 SDK (Xcode 26); with an older Xcode the app builds without it and draws the flat panels it draws on earlier systems (`swift build -Xswiftc -DFEATHER_NO_GLASS` builds that way on purpose). The package's tools version is 5.9; CI builds on
GitHub's `macos-15` runner.

```sh
git clone https://github.com/aagicorp/feather.git
cd feather
./build.sh          # Feather.app in this folder: ad-hoc signed, never checks for updates
open Feather.app
swift build         # a compile check without making the app
```

Settings, sessions and caches live outside the repository (`~/Library/Application Support/Feather`), so a
development build and an installed copy do not get in each other's way beyond sharing them. `Feather --safe`
opens a clean window; `Feather --reset` wipes those files and quits. Neither touches a project.

## Running the checks

| Command | What it does |
| --- | --- |
| `swift test` | The unit tests (in one process: they share the settings store, so `--parallel` is not safe) (about 990): parsers, heuristics, diffing, git plumbing, settings, symbol scanning, the checkers, shell integration. No window, no network, no real project. See [Tests/FeatherTests/README.md](Tests/FeatherTests/README.md). |
| `tools/uitest.sh [folder]` | The window harness (`Sources/Feather/App/UITestHarness.swift`): builds the debug binary, opens a real window, drives it through its scenarios, writes a PNG per scenario and fails on any `FAIL` line. `FEATHER_UITEST_ONLY=name tools/uitest.sh` runs one scenario. |
| `tools/perf.sh [folder]` | Measures the **release** build: launch to window, idle CPU and memory, a 3,000-file folder, expanding its tree, a 1.5 MB TypeScript file, keystroke cost, forty tabs opened and closed, leaked blocks. |
| `tools/shots.sh [folder]` | Screenshots for the website and the README: opens this repository in the app, stages each feature and captures the real window (`Sources/Feather/App/UITestHarness+Shots.swift`). |

CI runs the first two on every push and pull request (`.github/workflows/ci.yml`) and keeps the harness's PNGs
as an artifact. Run them before opening a pull request; the harness needs a logged-in session since it opens a
window.

## Making a change

- **One topic per pull request**, with a description of what was tested and how. A fix for a bug comes with
  a test that failed before it where one is possible; the test files mirror the source folders, so the tests for
  `Sources/Feather/Git/Git.swift` live in `Tests/FeatherTests/Git/`.
- **Performance work brings numbers.** Say what `tools/perf.sh` (or a smaller measurement) reported before and
  after, on which Mac. The release notes quote them.
- **Feather's point is being light.** A change that adds memory, a dependency, or work per keystroke or per
  scroll needs a reason. New dependencies are discussed in an issue first; everything in `Package.swift` today
  is there because the app cannot do without it.
- **Add a changelog entry.** `CHANGELOG.md` is organised as `## <version>` sections, newest first, with
  `### <area>` headings inside each (Editor, Source Control, Terminal, Fixed…). Add a bullet under the top
  section, which is the release being prepared: a **bold sentence that says what changed from the user's side**,
  then, if it helps, why and how. The same text becomes the update window's release notes and the app's
  **What's New** page, so write it for the person using Feather, not for the reviewer. Do not raise `VERSION`;
  the maintainers do that when they release.
- **Changes to the UI come with a picture** when they can: a PNG from `tools/uitest.sh` or a screenshot.
- Keep **RELEASING.md** and **docs/** in step with what you change.

## Where things are

Everything lives in `Sources/Feather`, one folder per area, and `Tests/FeatherTests` mirrors it:

| Folder | What is in it |
| --- | --- |
| `App/` | Launch (`main.swift`, `AppDelegate`), settings and the Preferences window, key bindings, theme import, updates, release notes, folder trust, safe mode and reset, the `feather` command, the window test harness |
| `Window/` | The main window, its header, activity bar, status bar and notices, and the window-level panels: Command Palette, Quick Open, Filter |
| `Editor/` | The text editor and everything inside it: tabs, documents, editing commands, multiple cursors, folding, sticky scroll, completion, breadcrumbs, merge conflicts, the syntax tree, `.editorconfig`, auto save |
| `Language/` | Tree-sitter languages and queries, the server-less symbol finder, outline and workspace symbols |
| `LanguageServer/` | The LSP client and manager, document sync, the Problems pane, and the project checkers (compilers and linters run when no server is there) |
| `Explorer/` | The file tree, file icons, project file listing, project-wide search and replace |
| `Project/` | Per-project settings (`.feather/settings.json`), project colour, tasks and run configurations |
| `Git/` | Git commands, status, blame, diffs and the diff view, the commit graph, the Source Control pane |
| `Terminal/` | The terminal pane, its list and groups, links, shell integration, the activity watch, AI command-line tools, Send to Terminal |
| `Preview/` | Web, Markdown and media previews, the static file server and the localhost relay |
| `Activity/` | The Activity pane: project checkpoints and what the assistant changed since one |
| `Extensions/` | Built-in extensions that can be switched off (`Extensions.swift`) and the API client under `APIClient/` |
| `Shared/` | Small AppKit helpers used everywhere: the scroller, glass surfaces, pointer cursor, row hover actions |

Language support is a good first contribution: a Tree-sitter grammar is one line in `Package.swift`, a case in
`Sources/Feather/Language/TreeSitterLanguage.swift` and a folder of queries in `Resources/queries`; a language
server is a row in `Sources/Feather/LanguageServer/LSPManager.swift`.

## How the code is written

Match the code around your change. In particular:

- **Swift and AppKit, nothing else.** No SwiftUI, no web views for chrome, no Objective-C unless a system API
  leaves no choice. Views are laid out by hand where Auto Layout would cost scrolling performance (the explorer
  rows are an example).
- **Comments say why, in plain prose.** A `///` line over a property or function explains what it is for and
  what would go wrong without it ("Set while Back/Forward is moving the cursor, so that move is not itself
  recorded as a new place"). Do not restate the code. Comments and release notes use British spelling
  (colour, licence, organised), as the existing text does.
- **Four spaces, lines around 120 characters**, one type or one area per file, extensions in `Type+Area.swift`
  files when a type grows (`TerminalPane+List.swift`). Prefer `final class` and `private` by default.
- **Nothing blocks the main thread.** Git, language servers, file scans and parsing run on their own queues; a
  call to an outside program has a time limit. If a change does work on every keystroke or every row, measure it.
- **Nothing phones home.** Feather makes no network request the user did not ask for (the update check is the
  one scheduled exception and it is documented). Nothing is installed on the user's behalf; an install command
  is shown as text to copy.
- **Tests build their own world.** A test works in a temporary folder it made and removes, on its own defaults
  domain, never on the user's settings or a real repository.
- Commit messages are a sentence that says what changed and, when it is not obvious, why, as the history does.

## Licence

By contributing you agree that your contribution is licensed under the [Apache License 2.0](LICENSE), as Feather
is. There is no contributor licence agreement to sign. Please do not copy in code under a licence that is not
compatible with Apache 2.0, and add anything you bundle to `CREDITS.md` and `THIRD-PARTY-LICENSES.txt`.

## Conduct

The project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be kind, be specific, assume good faith.

Feather is maintained on a best-effort basis; a reply may take a little while.
