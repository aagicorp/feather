# API client

Send HTTP requests and check the answers from inside Feather, the way Postman does it. It is off until you
switch it on: **Feather ▸ Extensions…**, then the switch next to *API Client*. Switching it on adds an **API**
pane to the sidebar (⌃⇧I), a **Requests** menu, entries in the Command Palette, and the touches described
below. Switching it off takes all of it away again.

## Where things are saved

Everything is plain JSON with stable ids, so it diffs well and can be committed.

```
your-project/
└── .feather/
    └── api/
        ├── collections/      one file per collection (folders, requests, checks, variables)
        └── environments/     one file per environment (Local.json, Staging.json…)

~/Library/Application Support/Feather/api/
├── personal/<project>/       collections and environments you keep to yourself ("From terminal" lives here)
└── history/<project>.jsonl   the last 500 requests; never in the repository
```

A variable marked **secret** never reaches a file: its value goes to the macOS Keychain and the JSON keeps only
the name. Feather watches `.feather/api`, so a `git pull` that brings a teammate's collection shows up at once.

## Formats

| Format | Import | Export |
| --- | --- | --- |
| Postman collection v2.1 and environment (`.json`) | yes | yes |
| `.http` / `.rest` files (VS Code REST Client) | yes | yes |
| cURL command | paste, or ⌘-click in the terminal | Copy as cURL |
| OpenAPI 3 / Swagger (`openapi.yaml`, `openapi.json`, `swagger.json`) | yes | — |

## Requests written as text: `.http` files

Open any `.http` or `.rest` file and a strip appears above it with one button per request in the file. The
request your cursor is in is highlighted; click its button to open it in a request tab and send it. The file
is read the way VS Code's REST Client reads it:

```http
@baseUrl = http://localhost:3000

### Login
POST {{baseUrl}}/auth/login
Content-Type: application/json

{ "email": "ann@example.com", "password": "{{password}}" }

###
# @name health
GET {{baseUrl}}/health
```

- `###` separates requests; the text after it names the request, and so does `# @name`.
- `@name = value` lines are file variables and are filled in; other `{{variables}}` come from the environment.
- The method is optional (GET); a long query can go on with lines starting `?` or `&`.
- Headers follow the request line; a blank line, then the body.

## From the terminal

When a `curl …` line is printed in the terminal (by you, by a script, or by the AI assistant), ⌘-click it:
the request is added to a **From terminal** collection in your personal folder and opened. Lines continued
with a trailing `\` are joined. `-X`, `-H`, `-d`, `--json`, `-F`, `-u`, `-G`, `-I` and `--oauth2-bearer` are
understood; options that only concern curl (`-s`, `-o`, `--max-time`…) are skipped.

## With the AI assistant

**Requests ▸ Ask Assistant About Last Request** types a short brief at the assistant's prompt: the request as
one cURL line, the status, time and size of the answer, the first 40 lines of the body, and any checks that
failed. Nothing is entered, so add your question and press Return. The same brief is what the "Ask assistant"
button on a response gives you.

## From an OpenAPI file

When the project has an `openapi.yaml`, `openapi.json` or `swagger.json` at its root (or in `api/`, `docs/`,
`spec/`), the API pane offers **Generate Requests**: one request per operation, in a new collection.

## Keyboard shortcuts

| Keys | What |
| --- | --- |
| ⌃⇧I | Show the API pane |
| ⌥⇧⌘N | New request |
| ⌘↩ | Send the request in front (in an `.http` file: the block the cursor is in) |
| ⌘S | Save the request |
| ⌥⇧⌘R | Run a collection or folder |

Every command is also in the Command Palette (⇧⌘P), and every shortcut can be changed in
Help ▸ Keyboard Shortcuts.
