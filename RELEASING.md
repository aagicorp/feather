# Releasing Feather

## How an update reaches a user
1. Every released copy of Feather has an address baked in (`FEED_URL` in `release.config`) and checks it once a
   day, and when the user picks **Feather > Check for Updates…**.
2. That address serves `appcast.xml`: the list of versions, where each DMG is, and a signature for each.
3. When the feed has a higher version than the running one, Sparkle shows the release notes and an Install button,
   downloads the DMG, checks the signature against the public key inside the app, swaps the app and relaunches.
4. Settings, the session and installed language servers are outside the app bundle, so they are untouched.

Two keys protect this. Apple's **Developer ID** certificate signs the app (so macOS opens it without warnings);
the **Sparkle EdDSA key** in your login keychain signs each update (so a hacked web server cannot push a fake one).
Back the EdDSA key up (`.build/artifacts/sparkle/Sparkle/bin/generate_keys -x feather-update-key.txt`, store it in
the company password manager, delete the file). If it is lost, existing copies can never be updated again.

## Handing a build to the team directly
    ./release.sh team
Builds the universal app, signs it with the Developer ID certificate, notarizes it when the notarization login is
stored, and writes `../Feather-local/team-builds/Feather-<version>.dmg` (outside the repository). No website or update feed is involved; this build does not
update itself, so the next version is sent the same way. Use this until the update address exists.

## One-time setup
    ./release.sh setup
It checks the four things needed and says what is missing: the Developer ID Application certificate, the update
key, the notarization credentials, and the addresses in `release.config`.

## Each release
1. Raise the number in `VERSION` (for example 0.9.0 to 0.9.1). Versions only go up.
2. Add a `## <version>` section at the top of `CHANGELOG.md`. The same text becomes the update window's notes
   and the **What's New** page inside the app, which opens once after each update.
3. Run `./release.sh`. It builds a universal app, signs it, makes the DMG, has Apple notarize it, and rewrites
   `releases/appcast.xml`.
4. With `GITHUB_REPO` set, the script then creates the GitHub release with the DMG, writes the website's
   `release.json` and `appcast.xml`, and deploys the site when `DEPLOY_WEBSITE_COMMAND` is set.
5. Commit and push: the GitHub release's tag `v<version>` already exists on GitHub; `git fetch --tags` brings
   it down.

Keep every old DMG in `releases/` on the machine that releases: `generate_appcast` uses them to make small
delta updates.

## A required update, for a serious bug
    ./release.sh --critical
or write the heading in CHANGELOG.md as `## 0.14.5 (required)`, which does the same and keeps the decision with
the notes. Either marks the release critical in the feed. Every older copy then shows the update as soon as it checks, with no
Skip button; every window carries an "Update required" card with Install Now until it is installed; and the
download starts by itself, so Install needs no wait. `--critical-below 0.14.2`
limits that to copies older than 0.14.2 (people already on 0.14.2 see an ordinary update). Sparkle never kills a
running app: the person still presses Install, and their windows come back as they were.

`--phased 86400` rolls an update out over a day, so a bad build reaches few people before it is pulled (publish a
new appcast without it). A plain release is shown once a day, and quietly: Sparkle downloads it and installs it
at the next quit when the person has allowed automatic updates.

## Trying an update on this Mac before anyone else gets it
    tools/update-lab.sh            # an ordinary update
    tools/update-lab.sh --critical --check
Builds the current version as the "old" app and the next patch version as a DMG, writes a signed `appcast.xml`
for it, serves both from `http://localhost:8765`, and opens the old app pointed at that feed. Choose **Feather ▸
Check for Updates…** (or pass `--check`): Sparkle offers the new version with its notes, Install downloads the
DMG, checks the signature with the key inside the app, swaps the app and relaunches it. Feather ▸ About then says
the new version. Nothing touches `releases/` or the real feed; the lab lives in `../Feather-local/update-lab/`, outside the repository, and the repository's
Feather.app is rebuilt as a normal development build afterwards.

Inside the app, the What's New page (Help ▸ What's New, and once after each update) starts with the running
version and a **Check for Updates** link, and shows a card with the same button.

A shipped copy can also be pointed at a lab feed, for checking a real release before it is announced:
`defaults write com.aagicorp.feather updateFeedOverride http://localhost:8765/appcast.xml` (only a local
address is honoured, and the signature check still applies). `defaults delete … updateFeedOverride` undoes it.

## Where things live: GitHub Releases and the website
- **The DMGs go to GitHub Releases.** `tools/publish_release.sh` (run by `release.sh`) makes the release
  `v<version>` in `GITHUB_REPO` with the notes from CHANGELOG.md and uploads the DMG twice: under its versioned
  name, which the update feed links to, and as `Feather.dmg`, so
  `https://github.com/<repo>/releases/latest/download/Feather.dmg` always fetches the newest version. The
  website's Download button uses that permanent link, so it never goes stale.
- **The website is its own folder and repository**, beside this one: `../FeatherWebsite`, the GitHub
  repository `aagicorp/feather-website` (`WEBSITE_DIR` in `release.config`), so the app's repository carries no
  site, node modules or built pages.
- **The website carries the feed and the version.** The same script writes `public/appcast.xml` there (the
  feed every copy reads; `FEED_URL` is its address on the site) and `public/release.json` (the version,
  size, date and links the site is built with). The page also asks GitHub for the newest release when it
  opens, so the number is right even before the site is redeployed.
- **Hosting the site:** the website repository `aagicorp/feather-website` is served by Cloudflare Pages at
  https://feather.aagicorp.com/ (root directory `/`, build command `npm run build`, output directory `out`);
  every push to its main branch goes live. `DEPLOY_WEBSITE_COMMAND` in `release.config` commits and pushes the
  website folder after a release, so the version text and the feed go live by themselves.
- The repository must be public for GitHub to serve the downloads without a login. Until then, `release.sh`
  without `GITHUB_REPO` falls back to printing what to upload where.

Publish the DMG first and the appcast second (the script does them in that order), so no copy is told about
a file that is not there yet. Keep every old DMG in `releases/` on the releasing Mac: `generate_appcast` makes
delta updates from them.

## Internal testing first, open source later
- **Now (private repo):** a private GitHub repository cannot serve downloads to Sparkle, because it needs a login.
  Serve `appcast.xml` and the DMGs from a folder on the company website. Testers install the DMG once and get
  every later build through the updater.
- **Going public:** make the repository public (Apache License 2.0) and, if you like, upload the DMGs to GitHub Releases and point
  `DOWNLOAD_URL_PREFIX` there. `FEED_URL` stays on the website for good, since shipped copies look there.
- A separate beta channel for testers is possible later (Sparkle channels); until then testers and everyone else
  get the same feed.
