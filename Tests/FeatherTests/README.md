# Feather tests

`swift test` runs everything here. The folders mirror `Sources/Feather`, one test file per source file or
feature, so the tests for `Sources/Feather/Git/Git.swift` live in `Tests/FeatherTests/Git/`.

- Tests are XCTest cases with `@testable import Feather`; they cover the parts that need no window: parsers,
  heuristics, diffing, git plumbing, settings, symbol scanning, the checkers, shell integration.
- `Support/TestSupport.swift` has the shared helpers: temporary folders, fixture files, throwaway git repositories,
  and a run-loop wait. Every test that touches the disk works in a folder it made and removes it afterwards.
- Nothing here runs a real language server, network request or the user's shell start-up files, and nothing ever
  touches a real project or Feather's real settings (the test binary has its own defaults domain).

Window-level checks (header, terminals, symbol search, git refresh) live in `Sources/Feather/App/UITestHarness.swift`
and run through `tools/uitest.sh`, which starts a real window, drives it, and fails on any `FAIL` line.
