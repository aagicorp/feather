<!-- One topic per pull request. Link the issue it closes, if there is one. -->

**What changed and why**

**How it was tested**
<!-- e.g. swift test --parallel; tools/uitest.sh (attach the PNG for a UI change); tools/perf.sh before and
     after for anything on the hot path, with the numbers and the Mac they came from. -->

**Checklist**
- [ ] A bullet under the top `## <version>` section of `CHANGELOG.md`, written for the person using Feather
- [ ] Tests added or updated where the change can be tested without a window
- [ ] No new dependency, or one agreed in an issue first and added to `CREDITS.md` and `THIRD-PARTY-LICENSES.txt`
- [ ] Nothing new runs on the main thread per keystroke or per row without a measurement
