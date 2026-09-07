# Private beta gate

Keeps the one-liner working while the repository is private, gives every tester their own link,
and lets you cut off one tester, or everyone, in one click.

## What it can and cannot do

A one-liner is `irm <url> | iex`: PowerShell downloads the script text and runs it. Whoever has a
working link has the full script on their machine, readable. No gate changes that; obfuscation
does not either (it is reversible, and it gets a script people run as administrator flagged by
Defender). What the gate does:

- The source repository stays **private**: no browsing, no history, no docs, no tests, no clone.
- Each served copy is **stamped** with the tester's key and name (`$sync.betaTester`), and each
  one-liner carries the key. A leaked file or link identifies its source.
- Each key can be **revoked**; the tester's downloads stop and their already-downloaded copy
  stops at its next start-up check.
- One **kill switch** stops every copy everywhere.
- The compiled beta header grants **no licence**, so a leak is not a permitted redistribution.

What it does not do: stop a determined person from removing the start-up check from a copy they
already have. That copy still carries their name.

## Setup in the browser, once (no installs)

Do this **after** the first push, so the file the gate reads exists.

### A. GitHub: a read-only token for the gate

Signed in as `unknownaimer`: profile menu > **Settings** > **Developer settings** > **Personal
access tokens** > **Fine-grained tokens** > **Generate new token**.

- Name: `unknowntweaks-gate`. Expiration: 90 days is fine (you will get an email before it lapses).
- Repository access: **Only select repositories** > `unknownutility`.
- Permissions > Repository permissions > **Contents: Read-only**. Nothing else.
- Generate, copy the token now (it is shown once). It can read this one repository and nothing
  else, so even if the gate leaked it, the blast radius is "someone can read the script".

### B. Cloudflare: the Worker

From the dashboard home:

1. Left menu **Compute (Workers)** (older layout: **Workers & Pages**) > **Create** >
   **Create Worker** (the "Hello World" starter). Name it `unknowntweaks-gate`. **Deploy**.
2. **Edit code**. Select everything in the editor, delete it, paste the whole of
   [`worker.js`](worker.js). **Deploy**.
3. Back on the Worker's page: **Settings** > **Bindings** > **Add** > **KV namespace**.
   Variable name: `GATE`. Under KV namespace choose **Create new** and name it `unknowntweaks-gate`.
   Save. (This is the little database that holds the keys and the kill switch.)
4. **Settings** > **Variables and Secrets** > **Add**, four times as type *Text*:

   | Name | Value |
   |---|---|
   | `GH_OWNER` | `unknownaimer` |
   | `GH_REPO` | `unknownutility` |
   | `GH_BRANCH` | `main` |
   | `GH_FILE` | `unknowntweaks.ps1` |

   and once as type **Secret**: `GH_TOKEN` = the token from step A. **Deploy** if it asks.
5. Note the Worker's address on its overview page:
   `https://unknowntweaks-gate.<something>.workers.dev`. That is `GATE` everywhere below. A custom
   domain can be attached later without changing anything else.

### C. GitHub: tell the build to produce beta scripts

Repository > **Settings** > **Secrets and variables** > **Actions** > **Variables** > **New
repository variable**: `GATE_URL` = the Worker address from B5 (no trailing slash). From the next
push on, the workflow compiles `-Beta` and bakes the status URL in. Re-run the last workflow from
the **Actions** tab to rebuild without pushing.

Until this is done the committed `unknowntweaks.ps1` is the **public** build (the workflow ran
once without `GATE_URL`). The gate refuses to serve a non-beta file, so nothing leaks meanwhile,
but no tester link will work until the re-run has finished. Check the Actions tab is green first.

## Keys (all in the browser)

Generate a key on your PC (PowerShell):

```powershell
-join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
```

Cloudflare > **Storage & Databases** > **KV** > `unknowntweaks-gate` > **KV pairs** > **Add entry**:

- Key: `key:` followed by the 24 characters, e.g. `key:Ab3xK9...`
- Value: `{"name":"tester one","revoked":false}`

Give that tester exactly this, and nothing else:

```
irm "https://unknowntweaks-gate.unknowntweaks.workers.dev/ut?k=Ab3xK9..." | iex
```

**Revoke one tester:** edit that entry's value to `{"name":"tester one","revoked":true}`.
Their downloads stop at once; their downloaded copy stops the next time it starts.

**Kill everything:** add an entry with key `killswitch` and value `on`. Delete it to reopen.

## Spotting a leak

Worker page > **Logs** (or **Observability**) > **Live**: one JSON line per hit with the key, the
tester's name, IP, country, path, version and the answer given. The script checks in once per
start, so a key that was one person on one connection and is now twenty IPs across three
countries is a leaked key. Revoke that key. The others keep working.

## What the script sends

A beta build makes exactly one request a public build does not: at start-up,
`GET /status?k=<key>&v=<version>`. No hardware, no username, nothing else. Tell testers this;
it is the one thing in the tool that is not "sends nothing".

## Command line instead (optional)

If you prefer a terminal and have Node.js: `npm i -g wrangler`, `wrangler login`, fill in
`wrangler.toml`, `wrangler kv namespace create GATE`, `wrangler secret put GH_TOKEN`,
`wrangler deploy`. Keys: `wrangler kv key put --binding GATE "key:..." '{"name":"...","revoked":false}'`.
Logs: `wrangler tail`.

## Ending the beta

Delete the `GATE_URL` repository variable, push (or re-run the workflow) so the public MIT build is
committed, make the repository public, update the README one-liner to the raw GitHub URL, and
delete the Worker. The public build has no status URL and never calls anything.
