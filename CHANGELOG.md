# What's New in Feather

## 0.14.4

### Project colour
- **A project colour shows on light themes too.** On a light theme the colour was dyed so faintly, and then
  painted so see-through over the glass, that the bars looked plain. A light chrome now takes more of the
  colour, and a project colour is painted nearly solid over the glass on every theme.

## 0.14.3

### The editor and terminal float like VS Code's
- **A little gap around the sidebar, the editor and the terminal panel.** Each is now a rounded panel standing off
  the window edges and each other, as VS Code lays them out; the window's glass shows in the gaps, and a gap is
  also the divider, so dragging it still resizes the panes.
- **The sidebar is a card too.** It floats off the activity bar and the window edges like the editor and the
  terminal, on the same ground, which takes the project colour as the bars do. The terminal panel's left edge
  lines up with the editor's.
- **The editor and terminal are translucent like the sidebar.** With glass on (macOS 26, Settings), both panels
  let the desktop show through, a touch less than the sidebar so code stays easy to read
  (`defaults write com.aagicorp.feather glassSurfaceAlpha 0.7` tunes it). Without glass nothing changes.

### Project colour
- **Calmer project colours.** The colour is now dyed into the window chrome instead of painted over it, so the
  bars and the ground under the panels take the hue without becoming a block of paint; and the palette's shades
  are kept off full saturation, since the whole window wears the one chosen. VS Code and Peacock colours are
  read as before.

### Welcome page
- **A short editor no longer cuts the welcome page off at the top.** With the terminal dragged tall, the title
  and the first steps were pushed above the editor's edge. The page now scrolls from the top when the editor is
  shorter than its content, and sits in the middle as before when there is room.

### Scroll bars
- **No little grey box in the corner of the sidebar.** Where the sidebar's vertical and sideways bars meet,
  AppKit painted a corner piece of its own, a lighter square at the bottom right. It is gone, in every scroll
  view.

### Terminal list
- **Dragging a terminal to the top of the list works.** The list is exactly as tall as its rows, so a drag to the
  top usually overshoots into the strip above it, where the drop was refused and nothing moved. A row dropped
  just above the list now lands at the top, and one dropped just below it at the end. A press on a row that was
  not the selected one also no longer rebuilds the list under the pointer; the rows update in place, which is
  lighter too. The window harness now drives this with real mouse events (`FEATHER_UITEST_ONLY=terminal-drag
  tools/uitest.sh`).

### Languages come as extensions
- **The Languages pane is gone for now.** Installing language servers will happen in the Extensions window, as in
  VS Code, once the catalogue is up; the window says so. A language server already on the Mac is used as before,
  and the status bar's hint says how to get one from the terminal in the meantime.

### Source Control: laid out like VS Code's
- **The list reads like VS Code's.** "Changes" and "Staged Changes" headers carry their count on a pill; each
  file shows its icon, its name, its folder dimmed after it and its status letter in colour at the far right;
  the stage, unstage and discard buttons appear only on the row under the pointer. The message box is a rounded
  field whose hint names the branch, and the one big button carries an icon: ✓ Commit, ⟳ Sync Changes,
  Publish Branch.
- **No dark box behind the explorer's M.** The git mark used to sit on a block of the row's colour so a long name
  would not show through it; the block read as a black box on the glass sidebar. The name is now simply cut
  short before the mark, so the row's own background shows through, whatever it is.
- **The count on the Source Control icon no longer hides the icon.** It is a small pill on the icon's lower-right
  corner, as in VS Code, instead of a large one across its middle.

### Explorer: the git marks are back in view
- **The M, U, A… letters and the folder dots were often not there.** The explorer column grows to fit its widest
  row so a deep tree scrolls sideways and no name is cut short, but the marks sat at the far end of the column,
  out of view. They are now pinned to the visible right edge of the sidebar, in a column of their own so the
  letters and dots of neighbouring rows line up, and stay there however far the tree is scrolled.
- **Compact folder rows read better.** In `src › main › java` the folded folders recede and the folder the row
  stands for keeps the full colour. The whole chain is always written out, as VS Code, Zed and IntelliJ write
  it; one too long for the sidebar ends in an ellipsis and the tooltip holds the whole path (and "Contains
  changes" when there are some).
- **Unfold Folder / Fold Folder** in the explorer's menu open a chain out into one row per folder and fold it
  back, the way Zed and IntelliJ do, for when the package path matters more than the space.
- **Preferences ▸ General ▸ Compact folders** turns the folding off altogether, like VS Code's
  `explorer.compactFolders`.

### Source control without the terminal
- **Merge conflicts are resolved in the editor.** A file with `<<<<<<<` blocks shows each block tinted, the
  current side green and the incoming side blue as VS Code colours them, with **Accept Current**, **Accept
  Incoming** and **Accept Both** after every `<<<<<<<` line. Each is one undoable edit. diff3 blocks with a base
  section work too.
- **Pull and Sync that end in conflicts** are a merge to finish, not an error: the pane explains the three
  buttons, lists the files marked !, and its button reads "Resolve N Conflicts First" until each is marked
  resolved, then "Commit Merge". A pull with `pull.rebase` pauses the same way and offers **Continue Rebase**
  and **Abort Rebase**.
- **Publish Branch.** The pane's one button is Commit while there is something to commit; otherwise it is
  **Publish Branch** for a branch that is not on a remote, or **Sync Changes ↑2 ↓1** when commits wait, as in VS
  Code. Publish pushes with tracking to origin. With no remote at all it offers to create the repository on
  GitHub through the GitHub command-line tool (`gh`), private or public, or to connect a remote address, then
  pushes.
- A pull refused for a missing upstream or for uncommitted changes in the way says so in plain words, with
  what to do, instead of git's message.

### A more modern explorer
- **Rows light up under the pointer**, one at a time, and the selection is a rounded bar inset from the edges, as
  in Finder and Xcode, rather than a stripe across the sidebar.
- **Faster rows.** The row's icon, name and git mark are laid out by hand instead of with Auto Layout, which was
  most of the cost of filling a big folder; scrolling thousands of files is smoother.

### Liquid Glass on macOS 26
- **The window chrome is glass.** The sidebar, the activity bar, the header and the status bar sit on the
  system's sidebar and title-bar material, Liquid Glass on macOS 26, with the theme colour (or the project
  colour) laid over it so the theme still reads and the desktop shows through blurred, as it does behind the
  system's own sidebars. Quick Open, the Command Palette, suggestions, notice cards and the merge-conflict
  buttons are sheets of glass. On earlier systems, with Reduce Transparency on, or with the new
  **Preferences ▸ General ▸ Glass window chrome** switch off, everything is the flat theme colour as before.

### Required updates
- A release can be marked **critical** (`./release.sh --critical`) when it fixes a serious bug. Every older copy
  then shows the update at once with no Skip, every window carries an "Update required" card with Install Now
  until it is in, and the download starts by itself so Install needs no wait. `tools/update-lab.sh` tries the
  whole update path on one Mac, with `--critical` for that case.

### Requests on from the start; the extension catalogue is coming
- **The Requests pane (the API client) is on from the first launch.** Feather ▸ Extensions… still switches it off.
- **Extensions… says what is coming.** The catalogue of extensions needs a home on the web first, so the window
  shows a "coming soon" card and lists what is built in under it.

### The Requests pane, redrawn
- **One accent on the request bar.** Send is the one blue button (⌘↩ still sends); the method sits on a pill of
  its colour; the active environment shows beside the address as a chip; Cookies, Copy as cURL and where the
  answer goes live under one ⋯ menu.
- **Tabs with counts.** Params 1 · Headers 2 · Body JSON · Auth Bearer · Checks · Variables, as underline tabs
  with a pill, instead of a segmented control with dots.
- **Tables that invite typing.** Every name/value list ends in a row that says "Add parameter" (or header, or
  field) and becomes real as you type; ✕ appears at the end of a row under the pointer and ⌫ removes the
  selected row; the + − buttons are gone; a Description column was added. **Bulk edit** at the right of the
  tabs turns Params, Headers or a form body into text, one `name: value` a line, `//` in front to switch a row off.
- **The answer.** The status is a pill in its colour (green 2xx, amber 3xx and 4xx, red 5xx and failures) with
  the time and size beside it; the header is hidden until there is an answer, so the empty state speaks alone;
  Pretty / Raw is a toggle inside Body; Headers and Cookies tabs carry their counts; Copy, Copy path and Save
  are icons together at the right.
- **The sidebar.** One row of controls: the environment, New ▾ (request, collection, folder, environment,
  import, paste cURL) and ⋯; every method on a pill of one width, so names line up; duplicate and delete
  appear on a row under the pointer, + on a collection or folder; the history is grouped by Today, Yesterday
  and date.

### Terminal notifications are off by default
- The notification and the sound for a terminal that has finished or is asking something are now off until
  you switch them on: **Preferences ▸ Terminal ▸ Tell me when a terminal is waiting** and **Play a sound…**,
  or the same two switches in the Command Palette.

### The installer
- **The disk image opens as an installer window**: Feather on the left, Applications on the right, an arrow
  and "Drag Feather to Applications to install" on the background, the window at a fixed size with no toolbar,
  and Feather's icon on the volume. `tools/make_dmg.sh` lays it out through Finder; `release.sh` uses it.

### Measured and tuned
- **The first keystroke in a big file no longer stutters.** Suggestions come from the words already in the
  file, and gathering them scanned up to 400,000 characters on the main thread the moment typing began: 39 ms
  for one key. The scan now runs off the main thread for anything but small files; the worst key in a 3.8 MB
  file went from 38.8 ms to 7.9 ms, the average from 5.3 ms to 4.6 ms.
- `tools/perf.sh` now also measures idle CPU and memory with a project and a terminal open, scrolling the
  explorer and the editor, opening and closing forty tabs three times over, and counts leaked blocks. On this
  Mac the release build idles at 0.3 % of a core with 93 MB, scrolls a page in under 2 ms, and gives back every
  byte the tabs took; the leaked blocks (18 KB) are in Apple's XPC frameworks, none in Feather's own code.

### Fixed
- An ignored folder or file with a non-ASCII name ("Ünïcode build", "émoji 🚀.md") was never dimmed in the
  explorer: git writes such names with octal escapes and Feather compared them as they came. They are unquoted now.

### Source Control shows how many files changed
- The Source Control icon in the activity bar carries the number of changed files, over every repository under
  the folder, as VS Code's does. It comes from the same `git status` as the explorer marks, so it is right
  whether or not the pane is open, and the icon's tooltip says it in words.

## 0.14.2

### The "only loading" hang on macOS 15, fixed for real
- On macOS 15 (Sequoia) Feather froze at 100 % CPU as soon as a terminal opened in a folder that is not a git
  repository, which on a fresh Mac is every folder. The terminal's branch lookup walked up the folder tree
  looking for `.git` and expected to stop at `/`; macOS 15's Foundation answers `/..`, then `/../..`, for ever,
  so the main thread never came back. macOS 26 answers `/` and hid the bug. The walk now uses plain paths, stops
  at the root on every macOS, and has a hard limit on steps.

## 0.14.1

### On a Mac without the developer tools
- **Feather no longer hangs on a Mac that has no git.** Apple ships `/usr/bin/git` as a stub that puts up the
  "install the command line developer tools?" dialog and a "Finding software…" window and blocks until they
  are answered; every part of Feather that asked git something at folder open waited on it, which looked like an
  app stuck at loading. Feather now looks for the real git (Command Line Tools, Xcode, then Homebrew on the
  shell's PATH) and never runs the stub. Without one, Source Control says so and offers **Install Command Line
  Tools…**; the Activity pane says checkpoints need it; everything else works. Once the tools are installed
  the branch, the Explorer marks and Source Control fill in on their own.
- Every git call has a time limit (two minutes; ten for fetch, pull and push), so a stuck git can no longer
  hold a pane.

### If something goes wrong at launch
- **Hold Shift while Feather starts** (or run it with `--safe`) to open a clean window: the last session and
  folder are not reopened, and a card says how to get back to normal.
- **Feather ▸ Reset Feather…** (or `Feather --reset` from a terminal) clears settings, saved sessions,
  checkpoints, API client data, the shell files and caches, then quits. Projects are never touched.

## 0.14.0

### Explorer
- **Folders that hold nothing but one folder are shown as one row**, `src › main › java › com › aagicorp`, as
  VS Code's compact folders do, so a Java or Kotlin tree no longer marches off to the right.
- **The tree scrolls sideways** when names are wider than the sidebar, instead of cutting them off.

### The activity bar
- The sidebar's panes are now icons down the left edge of the window, as in VS Code: Explorer, Search, Source
  Control, Languages, Problems, Activity, and any extension's pane. Click one to show it, click the lit one to
  hide the sidebar; the strip stays. Extensions and Settings sit at the bottom.

### Extensions: parts of Feather you switch on
- **Feather ▸ Extensions…** lists optional features with a switch each. Off, a feature costs nothing: no menu,
  no sidebar icon, no memory. On, it appears in every window at once. Nothing is downloaded.
- The first extension is the **API Client**, below. It is off until you switch it on.
- The activity bar, header and status bar all take the project colour when one is set.

### API client: send requests and check the answers, like Postman
- Collections, folders and requests are saved as plain JSON in the project's `.feather/api` folder, so they can be
  committed and shared with the team; or in your own folder, for collections that are just for you. Passwords,
  tokens and API keys marked secret live in your Keychain and never in a file.
- Environments (Local, Staging…) hold `{{variables}}`; a request can take a value from its answer into a
  variable ("$.token" → token), so a sign-in followed by authenticated requests works without scripts.
- The API pane leads with **New Request**, **Import…** and a More menu (new collection, folder or environment,
  paste a cURL command, generate from OpenAPI, export, cookies); COLLECTIONS and each collection carry a +.
  Params and Headers always offer a blank row to type into, so nothing needs a + first.
- **Cookies** (the button beside Send, or Requests ▸ Cookies…) lists what servers set, where each one
  applies and when it ends, with Delete and Clear All. A sign-in cookie set over `http://localhost` is kept
  and sent back, as browsers and Postman do, even though macOS itself would refuse it.
- Checks are forms: status is 200, a JSON path equals a value, a header contains text, the time is under a
  limit. Each result is a plain sentence. Requests can be run one after another with the results in a table.

### API client: import and export

- Import what the team already has: Requests ▸ Import… takes Postman collections and environments, OpenAPI 3 files (JSON or YAML), .http/.rest files from VS Code's REST Client, and text files of curl commands. Pick several files or a whole folder at once.
- Postman scripts are kept as text on the request and listed after the import; they do not run. Postman path variables like `:id` become `{{id}}`.
- Paste a curl command to make a request from it: quotes, line continuations, `-d`, `-F` uploads, `-u` sign-in and `--json` are all understood.
- OpenAPI files become one request per operation, in folders by tag, with example bodies built from the schema; each server becomes an environment.
- Export a collection as a Postman v2.1 file (Postman opens it; checks are written into the description as plain lines) or as an .http file. Export environments as Postman environment files, or everything at once into a folder.
- Secret variable values never reach an exported file; the export says which ones were left blank.
- Copy as cURL now resolves variables and sign-in, and writes uploads as `-F` parts.

### API client: developer and AI touches
- **Send from `.http` files**: open any `.http` or `.rest` file (VS Code REST Client style, `###` between requests) and a strip above it lists the requests; the one your cursor is in is highlighted. Click one to open it in a request tab and send it. `.http` files are coloured too.
- **Add to API from the terminal**: ⌘-click a `curl …` line printed in the terminal (by you or by the assistant) and it becomes a request in a "From terminal" collection, kept in your personal folder and opened at once.
- **Ask Assistant About Last Request** (Requests menu): hands the last request to the AI assistant as a short brief — the cURL line, the status and time, the first lines of the answer, and any checks that failed — typed at its prompt so you can add your question.
- **Generate Requests from OpenAPI**: a project with an `openapi.yaml`, `openapi.json` or `swagger.json` gets an offer in the API pane to make a request for every operation.
- A user guide is in `docs/api-client.md`: where files are kept, the formats, the `.http` syntax and the shortcuts.

### API client: the pane, request tabs and runner
- **API pane** (sidebar, ⌃⇧I): pick the environment at the top, filter by name or address, and see collections → folders → requests with the method in colour (GET green, POST amber, PUT blue, DELETE red). Recent history sits underneath; click an entry to open that request with the address it was sent to. Right-click for New Request, New Folder, Rename (in place, or press Return), Duplicate, Copy as cURL, Variables…, Run, Export… and Delete. Drag requests and folders to reorder them or move them between folders and collections. Drop Postman, OpenAPI, .http or cURL files on the pane to import them.
- **Request tabs**: method, address ({{variables}} shown in blue) and Send (⌘↩). Tabs for Params (kept in step with the address), Headers, Body (JSON or text in a real editor, forms, multipart with files), Auth (inherit, none, bearer, basic, API key), Checks (a form per check, no scripts) and Set variables. Edits show the dot on the tab; ⌘S saves into the collection, and a scratch request asks which collection to go in. Edits in a closed tab come back when the request is opened again.
- **The answer** under the request (a button puts it beside instead): status in colour, time and size; Body pretty-printed and coloured, with ⌘F, Copy and Copy Path (the JSON path under the caret, for a check); Raw; Headers; Cookies; Checks with ✓/✕ and a plain sentence for each. A spinner and Cancel (Esc) while sending; errors in plain words; answers over 50 MB offer Save to File.
- **Environments**: Manage environments… in the picker opens a sheet with the variables (tick Secret to keep a value in your Keychain and out of the file), the timeout, follow redirects and certificate checking. A collection's Variables… opens the same sheet for its own variables.
- **Run a collection or folder** (⌥⇧⌘R or the right-click menu): every request in order with the chosen environment, in a results tab with status, time and checks per request, Stop, Run Again and Rerun Failed. Values captured from one answer flow into the next request.

## 0.13.0

The biggest release yet: real syntax parsing, Replace in Project, errors without a language server, a review
flow for what the assistant changed, split terminals, editable shortcuts and VS Code themes.

### Settings, keyboard shortcuts and themes
- **Settings has a search box and sections**, like VS Code's: type "terminal" or "save" and only the matching
  settings stay. The sections are Appearance, Editor, Files & Saving, Terminal, AI Assistant, Git, Preview and General.
- **Change any keyboard shortcut**: Help ▸ Keyboard Shortcuts (or Settings ▸ General ▸ Keyboard Shortcuts…) lists
  every menu command. Double-click one, press the new keys, then Return. Reset puts one back, Reset All puts
  them all back, and keys used by two commands are shown in red. The menus pick up the change at once.
- **Import a VS Code theme**: Settings ▸ Appearance ▸ Import VS Code Theme… (also in the Feather menu and the
  Command Palette) takes any `*-color-theme.json` file. The theme appears in the theme list and the Command
  Palette, and can be deleted from Settings again.
- Two more built-in themes: **Solarized Dark** and **GitHub Light**.

### Review changes since a checkpoint, block by block
- **Review Changes** (a button at the top of the Activity pane, View ▸ Review Changes Since Checkpoint, or ⌃⇧R)
  opens one tab that walks you through every file that changed since the checkpoint, like reviewing a pull
  request: "3 of 7 files", ‹ Previous File / Next File ›, and on every block of changed lines a **Keep** button
  (looked at, nothing changes) and an **Undo** button (those lines go back to how they were at the checkpoint).
- Undo changes only that block, on disk and in the editor if the file is open: ⌘Z in the file brings it back, and
  a file with unsaved edits around the block is left alone until you save.
- New files get **Keep** or **Move to Trash**; deleted files get **Keep Deleted** or **Restore**. **Keep All** and
  **Undo All…** are in the tab's header, with a bar showing how much of the change has been dealt with.
- Keyboard, while the review has the focus: j / k or ↓ / ↑ move between blocks, K keeps, U undoes, ⌘] and ⌘[ move
  between files. What you have reviewed is remembered for the current checkpoint until you take a new one.

### Terminal
- **Split Terminal** (Terminal menu, ⌃⇧5, or the split button in the terminal's header): puts a second shell beside the one in front. Split again for up to four columns; drag the thin divider to size them. The list on the right shows the members of a split joined by a bracket; click any of them to show the whole group with that one in front. Killing a member closes just that column. Splits come back with the session on the next launch.
- **What is it doing:** the terminal's header now says what the terminal in front is up to — "▶ npm run build · 12 s" while a command runs, then "✓ finished in 14 s" or "✕ exit 1 · 14 s" for a moment after it ends. With an AI assistant it reads "Claude Code · working 2 m", "Claude Code · waiting for you" when it asks something, and "stopped after 2 m" when it goes quiet.
- **See what the assistant changed:** when the assistant stops and files changed while it worked, the changed lines of the file you are looking at light up briefly and a card says "Claude Code changed 4 files", with "Review in Activity" to see the list. Nothing is opened and the keyboard stays in the terminal.

### Replace in Project
- The Search pane now has a Replace field: click the chevron beside the search field, or choose Edit ▸ Replace in Project… (⇧⌘H).
- Search options like VS Code: Match Case (Aa), Match Whole Word (ab) and Use Regular Expression (.*). In regex mode, $1, $2… in the replacement stand for the groups. Every match on a line is listed, not just the first.
- Replace All opens a preview tab first: each file's lines before and after, with a switch to skip a file. "Replace N in M Files" applies it. Hover a result row for Replace, or a file row for Replace All in File.
- Files open in the editor are changed in memory (⌘Z undoes it, nothing unsaved is lost); other files are rewritten on disk with their line endings and encoding kept. A checkpoint is saved first, so Undo All in the Activity pane puts everything back.
- Searching now sees unsaved edits in open files.

### Problems without a language server
- Run ▸ Check Project for Errors (⇧⌘B), or the play button in the Problems pane, runs the project's own compiler or linter and lists what it finds: `tsc` (tsconfig.json), `pyright`, `pyflakes` or `py_compile` (Python), Maven or Gradle (pom.xml / build.gradle), `dart analyze` (pubspec.yaml) and `swift build` (Package.swift). The results show in the Problems pane, the status bar counts and as squiggles in the editor, and Fix This works on them.
- It also runs a moment after you save a file of that kind (Settings: "Check the Project for Errors After Saving", on by default). The pane says "Checked with tsc · just now" or "Checking…".
- A language server's report for a file takes over from the checker's, so nothing is listed twice. Nothing runs in Restricted Mode.

### Syntax colouring from real parsing
- TypeScript, TSX, JavaScript, JSX, Python, Java, Dart, Kotlin, Swift, JSON, CSS, HTML, YAML, shell, Go and
  Rust are now coloured from a syntax tree (Tree-sitter) instead of pattern matching, so a string with `//` in
  it, a keyword used as a name, or JSX in a `.tsx` file all get the right colour. Other languages keep the old
  colouring.
- Colours follow every keystroke: the tree is updated as you type and re-read off the main thread, so typing in
  a very large file stays as quick as before.
- Code in another language inside a file is coloured as that language: `<script>` and `<style>` in HTML, and
  css`…` or html`…` template strings in JavaScript and TypeScript.
- Folding uses the tree's own blocks (function bodies, classes, objects, arrays, HTML elements, Python suites) for
  these languages, so a block folds exactly where it ends; indentation still decides for other languages.
- Grammars load only when a file of that language is opened; an empty window loads none. Files over 1 MB keep
  the pattern colouring: measured, a syntax tree of a 3.8 MB file costs 260 MB of memory for no gain in speed.
- `tools/perf.sh` measures the release build (launch, idle memory and CPU, a 3,000-file folder, a large file,
  keystrokes, the API client's cost) so the numbers can be checked before every release.

### Also
- In the Source Control pane's graph, each commit's message now starts right after the lanes on its own row,
  as in VS Code's Git Graph, instead of after the widest point of the whole history.
- Nothing you can see changed here: the two largest source files (the main window and the terminal pane) were
  split into smaller files of one concern each, so future changes are easier to make and review.
- ⌘T and Go to Symbol in File now list Go functions correctly in files with a `package` line, Rust's `fn new()`
  and `mod` blocks; TODO comments in files with Windows line endings no longer carry a stray character; the
  changed-lines flash works for such files too.
- The test suite grew from 28 to 790 cases across every part of Feather (`swift test`), with folders mirroring
  the sources and a README in Tests/.
- `tools/uitest.sh` drives a real window through the header, terminals, symbol search and git scenarios and
  fails on any regression; the code is in App/UITestHarness.swift.

## 0.12.0

### A smaller header, with the layout in it
- **The header is 30 points instead of 38**, and it keeps its colour in full screen. Back, Forward and the project
  name (file search) are where they were.
- **Two buttons at the right of the header show and hide the sidebar and the terminal**, and light up while
  their pane is showing. The same as ⌘B and ⌘J.
- The Start AI Assistant button has left the header. The command is still in the Terminal menu (⌃⌥A); most
  people start their assistant by typing its name in the terminal anyway.

### Terminal
- **Maximize Terminal**: the ⤢ button in the terminal's header, a double-click on that header, or ⌃⇧M. The
  terminal takes the editors’ room; the same again brings them back. The sidebar opens and closes as usual meanwhile.
- **Drag terminals up and down the list** to put them in the order you want.
- **Change Color and Change Icon** on a terminal's right-click menu, as in VS Code: give the server a green
  globe and the tests a yellow check, and tell them apart at a glance. Names, colours and icons come back
  when Feather reopens.
- **Rename a terminal in place**: double-click its name (or Rename… in its menu) and type. The trash icon on
  a row now appears only while the pointer is over it, so long names are not cut short.
- **Feather knows exactly when a command ends.** New zsh and bash terminals carry a small hook that marks
  the start and end of every command, so "finished" or "failed (exit code 1)" is said at the moment it
  happens, with the real exit code, for any command that took more than a few seconds. Your own shell files
  are read as before; nothing in your home folder is changed. Other shells keep the old guess-from-silence.
  Terminal ▸ Open Shell Integration Files (also in the Command Palette) shows exactly what the hook is.
- **Folders, files and programs in different colours** in `ls` output (the terminal now asks `ls` for
  colour; your own `LSCOLORS` still applies).
- **Copy on Select** (Terminal menu, Settings, or the Command Palette): selecting text in a terminal copies it.
  Every copy from a terminal, by ⌘C or by selecting, shows "Copied 3 lines (240 characters)" for a moment.
- **The list of terminals has its own colours**: icons in the accent colour, the terminal showing in full, the
  others a little quieter. Choose your own icon and name colours in Settings ▸ Terminal list, or go back to the
  theme's.
- **You are told when a terminal finishes, even while you are looking at it.** A small card in the corner of the
  window and a sound, so Claude Code (or a build) finishing in a visible terminal does not go unnoticed while you
  read code. Out of view it is still a notification and a Dock badge. If macOS notifications are off for Feather,
  the card is shown instead. Run tasks now say whether they finished or failed, with the exit code.
- A sound plays when a terminal finishes or asks something (Settings ▸ Play a sound).

### Git keeps up with the terminal
- **The status bar says what is waiting to be pushed or pulled**: "⎇ main ↑2 ↓1". Click it for Source Control.
- **Sync Changes** (Git menu, ⌃⇧S, or the ⟳ button in Source Control): pull, then push, in one go. Pull, Push and
  Fetch are in the Git menu too.
- **A commit, checkout, push or pull made in the terminal now shows up by itself**: the branch in the status
  bar, the Source Control pane and the explorer's marks refresh a moment later. No more hiding and showing
  the terminal to make Feather notice.
- **The terminal shows its branch**: "TERMINAL ⎇ main" in the panel's header for the terminal in front, and
  beside each terminal's folder in the list.

### Go to Symbol in Workspace (⌘T)
- **Type the name of a function, class or type and go to it, wherever in the project it is.** Works with no
  language server installed: TypeScript, JavaScript, Python, Java, Kotlin, Swift, Go, Rust, C, C#, PHP, Dart,
  Ruby and shell files are read by the shape of their lines. The first search reads the project; later ones
  only re-read files that changed.
- **Quick Open (⌘P) understands VS Code's prefixes**: `#` for a symbol anywhere, `@` for a symbol in this file,
  `:` for a line number.
- Methods written on one line (`fetchAll() { return [] }`) are found now, by ⌘T and by Go to Symbol in File.

### For contributors
- `swift test` runs a small test suite for the parts that need no window: terminal heuristics and shell marks,
  symbol scanning, the workspace index, git parsing and branch reading.

## 0.11.1

### Preview
- **Signing in now works in the preview.** Many apps mark their sign-in cookie “Secure”, and the preview's engine
  (the one Safari uses) would not keep such a cookie from `http://localhost`, so you signed in and landed back on the
  sign-in page. Feather now keeps those cookies for apps running on this Mac, including apps whose pages and API are
  on different ports. Nothing changes in your project, and the address still reads `localhost`. Needs macOS 14 or later.
- **New Preview Tab**: the **+** at the right of a preview, or **⌃⌥N**. Working on two front ends, or a site and its
  admin? Give each its own preview tab and type its address, as you would in a browser.

## 0.11.0

Feather for working with an AI assistant: let Claude Code, Codex, Gemini or aider write the code in Feather's terminal,
and use Feather to watch, check and run what it did.

### Start and talk to your assistant
- **Start Claude Code** (or whichever tool you have) from the button beside the search box, or **⌃⌥A**. If none is
  installed, Feather shows how to get one.
- **Terminal on the Right** (View menu): the assistant in a tall column, your files on the left.
- **Fix This** on any error in the Problems pane hands the error and its place to the assistant. **⌃⌥K** asks it about
  the code you selected. Nothing is sent until you press Return.
- **Feather tells you when the assistant is done or is asking you something**, with a notification and a dock badge,
  so you can look away while it works.

### See and undo what it changed
- **Checkpoints.** Feather saves a snapshot when you open a folder and whenever you press **+ Checkpoint**. They work
  in any folder, with or without Git, and never touch your project's own Git history.
- **Activity** (⌃⇧A): every file changed since the checkpoint. Click one to see what changed, side by side.
  **Undo All…** puts everything back (new files go to the Trash, and you can put the changes back again);
  **Restore This File** does it for one.
- **Follow changes**: Feather opens each file as the assistant changes it and flashes the changed lines.
- Files you have open now update on their own the moment something changes them.

### Try the result
- When your app starts and prints its address, Feather offers **Open Preview**: your running app in a tab beside the
  code, reloading as files change. Phone, tablet and full widths. **Preview This Page** works for a plain HTML file.
- The preview exists only while its tab is open. It adds nothing to Feather's download size.
- On a sign-in page served over plain http, the preview explains once why signing in may not stick there (a “Secure”
  cookie from `http://localhost` is kept by Chrome but not by Safari's engine) and points to **Open in Browser**.

### Your choice of assistant, and quicker previews
- **Any AI tool.** Right-click the ✦ button (or Terminal ▸ Choose AI Assistant) to pick Claude Code, Codex, Gemini CLI,
  aider, Cursor Agent or opencode, or **Use Another Command…** for anything that runs in a terminal.
- **Show Preview** (⌃⌥P) opens your running app straight away; **⌃⌥⇧P** opens it beside the code; **⌃⌥B** opens it in
  your browser.
- A button in the terminal's header moves it between the bottom and the right-hand side.

### Friendlier all round
- The button that starts your assistant is a single icon beside the search box; hover it for the name.
- A new, plain start screen with three steps: open your folder, start your assistant, watch and run.
- Alerts and messages say things in plain words. The status bar says "TypeScript checking on" instead of "TypeScript LSP".
- Settings scrolls, so it fits a small screen.

## 0.10.0

### Editing
- **Multiple cursors.** **⌘D** selects the word and then each next occurrence, **⇧⌘L** selects them all, **⌥⌘↑ / ⌥⌘↓**
  add a cursor above or below, **⌥-click** adds one anywhere, **Esc** goes back to one. Typing, deleting, pasting and
  the arrow keys act at every cursor.
- **Code folding.** A chevron in the gutter folds a block; **⌃⌘[ / ⌃⌘]** fold and unfold, **⌃⇧⌘[ / ⌃⇧⌘]** do all of
  them. Searching or jumping into a folded block opens it.
- **Sticky scroll.** The class and function you are inside stay pinned at the top while you scroll.
- **Auto save** (Settings): after a short delay, or when you switch tab or app.
- **.editorconfig** is honoured: indentation, line endings, final newline, trailing spaces, per file.
- Word suggestions no longer slow typing in the middle of very large files (about seven times faster there).

### Git
- **Diff view.** Click a changed file in Source Control to see old and new side by side, with the changed words marked.
  Stage, unstage or revert a single block from the diff. **⌃⇧D** opens the changes of the current file.
- **Blame** for the current line in the status bar; click it for the commit.
- **Stash**: stash, pop, apply and drop from the branch menu.
- **Open on GitHub** (also GitLab and Bitbucket): the file and line, the repository, or its pull requests.

### Problems and terminal
- **Problems pane** (⇧⌘M): every error and warning in one list, click to jump. A **TODO** list of TODO, FIXME, HACK and
  NOTE comments across the project sits beside it.
- **⌘-click a path in the terminal** (`src/App.tsx:42:7`, a Java stack frame, a Python traceback line) to open it there.

### Menus
- A **Terminal** menu holds everything about the terminal: new, show or hide, next and previous, Run Task, and the two
  Send to Terminal commands (they used to be spread over View and Run).
- **Help ▸ Keyboard Shortcuts** lists every shortcut, read from the menus themselves. The Help menu's search field
  finds any command by name.

### Running things
- **Run Task…** (⌥⌘R) lists what the project can run: `package.json` scripts, Maven and Gradle goals, Flutter commands,
  pytest, Django, FastAPI, `Makefile` targets, and your own in `.feather/settings.json`. **⌥⇧⌘R** reruns the last one.
- **Send Selection to Terminal** (⌃⌥S) and **Send File Reference to Terminal** (⌃⌥L), handy with command-line AI tools.
- **Install the `feather` command** (Feather menu): `feather .` or `feather src/App.tsx:42` from any terminal.

## 0.9.1

### Explorer
- **Git marks on files**, as in VS Code: **M** modified, **U** untracked, **A** added, **R** renamed and **!** conflict
  at the end of the row, with the name in the matching colour. Folders that contain changes get a dot, green when
  everything inside is new. The marks follow saves, staging, commits and checkouts on their own.

### Other
- Open files and folders from the command line: `Feather.app/Contents/MacOS/Feather ~/project src/App.tsx`.

## 0.9.0

First build for the internal team.

### Editing
- Brackets and quotes close themselves; the matching bracket is highlighted. **⇧⌘\\** jumps to it.
- Move a line with **⌥↑ / ⌥↓**, copy it with **⇧⌥↑ / ⇧⌥↓**, delete it with **⇧⌘K**, indent with **⌘] / ⌘[**.
- **Format Document** (⇧⌥F), and in Settings: trim trailing spaces, final newline and format on save.
- **Go to Symbol in File** (⇧⌘O), **Reopen Closed Tab** (⇧⌘T), and Close Others / Close to the Right on a tab's menu.
- Typing in very large files is about four times faster when suggestions are on.

### Explorer
- New File, New Folder, Refresh and Collapse All buttons at the top.
- Names are typed right in the tree, as in VS Code: **Return** or **F2** renames, **Esc** cancels, and a name like
  `components/Button.tsx` makes the folder too. Open tabs follow a renamed file.
- `.env` files, `Dockerfile.*`, `nginx.conf` and ignore files are now coloured.

### Languages
- A **Languages** pane in the sidebar (⇧⌘X): install only the language servers you need. New: Kotlin, XML,
  Dockerfile, Markdown, TOML, Prisma, Svelte and PHP.

### Safety
- **Folder trust.** The first time a folder is opened Feather asks whether you trust it. In Restricted Mode you can
  browse, search and edit, but language servers, Run and git stay off until you trust the folder from the status bar.

### Updates
- Feather updates itself: **Feather ▸ Check for Updates…**. This page opens once after each update, and any time
  from **Help ▸ What's New**.
