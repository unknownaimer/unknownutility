# Publishing unknowntweaks

The tool carries the Unknown Aimer credit, the Discord invite and the TikTok handle on purpose;
they are in `Show-UTSplash.ps1` (`Get-UTCredits`) and nowhere else. What must stay out of the
repository is everything the credit does not say: your personal email address, your other GitHub
account, and your machine. Do this once, before the first push.

## 1. The account

Publish from the GitHub account you want the tool tied to, not from a personal one you also use
for other things - the commit history and the download URL both carry it forever.

- Turn on two-factor authentication. A tool that thousands of people pipe into PowerShell is worth
  stealing.
- In **Settings > Emails**, tick **Keep my email addresses private** and **Block command line
  pushes that expose my email**. GitHub then gives you a `NNNNNN+username@users.noreply.github.com`
  address. Commit with that address, never a real one.

## 2. Point git at that identity, for this repository only

This machine's global git config holds a different account. Do **not** change it, and do not rely
on it either: set the identity per repository so the other account is never used here by accident.

```bash
cd /path/to/unknowntweaks
git init
git config user.name "unknownaimer"
git config user.email "325379033+unknownaimer@users.noreply.github.com"
git config --local --list | grep user
```

Verify before the first commit that `git config user.email` prints the noreply address, not a
personal one. If you have ever committed with the wrong identity, do not try to fix history: start a
new repository, copy the files in, and commit fresh.

## 3. Authenticate without mixing accounts

A credential helper or `gh` login that already holds another account will happily push as that
account. Either:

- push over HTTPS with a fine-grained personal access token belonging to the publishing account
  (scope: contents read/write on this repository only), or
- use a dedicated SSH key: `ssh-keygen -t ed25519 -f ~/.ssh/id_unknowntweaks -C ""` (the empty
  comment matters: the default comment contains your Windows username and hostname), add the public
  key to the publishing account, and force this repository to use it:

```bash
git config core.sshCommand "ssh -i ~/.ssh/id_unknowntweaks -o IdentitiesOnly=yes"
git remote add origin git@github.com:unknownaimer/unknownutility.git
```

## 4. Bake the account into the build

The download URL used when the tool re-launches itself elevated is generated, not hand-written:

```powershell
.\Compile.ps1 -Version 1.0.0
```

Then update the one-liner in `README.md` to match. The build workflow does the same on every push,
so the committed `unknowntweaks.ps1` always matches the repository it lives in.

## 5. Check before you push

```bash
grep -rIn --exclude-dir=.git -iE 'YOUR-ANON-ACCOUNT|<your real name>|<your personal email>' .
git log --format='%an <%ae>' | sort -u
git status --ignored --short
```

The second command must show only the publishing identity. The third shows what `.gitignore` kept
out; anything you expected to ship that appears there needs a `!` line in `.gitignore`. Also open
`unknowntweaks.ps1` and confirm the `Source` and `$sync.url` lines point at the publishing account.

## 6. What still gives away more than the credit does

1. **The commit email.** Covered above. It is public in the API forever, even for a deleted repo.
2. **Time zone.** Commit timestamps carry an offset. `git commit --date` can normalise this if you
   care.
3. **Screenshots.** The tool's INFO tab shows the machine name and the signed-in user. Do not paste
   raw screenshots of it; the tool never uploads anything, but you might.
4. **The SSH key comment and the git user name.** Both default to your Windows account name.

## 7. What the tool itself discloses

A public build: nothing. It makes no network requests except the region pings (to Epic's public
ping hosts), the DNS benchmark (to public resolvers), and winget downloads when you ask it to
install something. There is no telemetry, no analytics, no update check that reports who you are.
Logs stay in `%LOCALAPPDATA%\unknowntweaks\logs` on the user's own machine.

A private-beta build (compiled with `-Beta`) adds exactly one request: at start-up it asks the
gate `GET /status?k=<tester key>&v=<version>` and refuses to run unless the answer is `ok`. The
gate logs the key, the tester's name, IP and country for that request. Say so to testers.

## 8. Private beta: private repository, gated one-liner

The order of operations, so the one-liner never points at something public:

1. Create the repository **private**. Push. The build workflow runs on private repositories too
   (GitHub's free plan includes enough Actions minutes for this).
2. Deploy the gate: follow [`gate/README.md`](../gate/README.md). It reads the compiled script
   straight from the private repository with a read-only token, so there is no second copy to
   keep in sync.
3. Build the beta script and commit it:

   ```powershell
   .\Compile.ps1 -Beta -Version 0.0.67 -StatusUrl https://unknowntweaks-gate.unknowntweaks.workers.dev/status
   ```

   The workflow does this on every push by itself: `GATE_URL` is set in the Compile step of
   `.github/workflows/build.yml`. Blank that one line and the next build is the public one again.
4. Hand each tester their own `irm "https://unknowntweaks-gate.unknowntweaks.workers.dev/ut?k=<their key>" | iex`. Never post a key
   anywhere shared.
5. Revoke a key when its one-liner turns up where it should not; flip the kill switch if the
   whole build must stop. Both take effect on the next download and the next start-up.

When the beta ends: compile without `-Beta` (the MIT header comes back), make the repository
public, update the README one-liner to the raw GitHub URL, delete the gate.
