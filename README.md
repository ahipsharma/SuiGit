# SuiGit

**Version control for the NetSuite File Cabinet.**

Every time you push a SuiteScript file to NetSuite from VS Code, SuiGit captures a
versioned snapshot in a custom record. Browse history, diff versions, restore old
content — all the things Git gives you for source code, but for the files that
actually live in your NetSuite account.

## How it works

```
VS Code (Shift+Alt+U on active file)
       │
       ├─► SuiteCloud CLI uploads the file to NetSuite  (waits for completion)
       │
       └─► SuiGit POSTs file content to a RESTlet, which writes
           a new customrecord_suigit_version row if the hash differs
```

## v1 scope and limitations

This v1 captures **only changes pushed through Shift+Alt+U (or the SuiGit batch task)**.
File changes that land in NetSuite through any other path are invisible to SuiGit:

- Direct File Cabinet UI uploads
- Bundle installs
- SOAP / REST web services
- SDF pushes that bypass the SuiGit wrapper task
- Production hot patches

This is a deliberate trade-off — NetSuite doesn't allow User Event scripts on the
`file` record, so there's no native server-side hook to catch every write. A future
version may add a Map/Reduce reconciliation sweep that scans `/SuiteScripts/` on a
schedule and records any drift. Not in this release.

## Prerequisites

| Tool | Why |
|---|---|
| VS Code | Editor |
| [Oracle SuiteCloud extension](https://marketplace.visualstudio.com/items?itemName=oracle.suitecloud-vscode-extension) | Bundles the CLI; handles OAuth setup |
| Java 17 or 21 | Required by the SuiteCloud CLI |
| Node.js 18+ | Runs the CLI |
| Git | SuiGit uses `git status` / `git diff` to detect changes |

## Quick start

> Full step-by-step walkthrough with screenshots: [docs/SuiGit-Onboarding.docx](docs/SuiGit-Onboarding.docx)

```bash
# 1. Clone
git clone <this-repo-url> SuiGit
cd SuiGit

# 2. Connect SuiteCloud to your account
#    VS Code: Ctrl+Shift+P → "SuiteCloud: Set Up Account"

# 3. Deploy SuiGit's objects to NetSuite
#    Right-click `src/` → "SuiteCloud: Deploy Project"
#    This creates customrecord_suigit_version and the RESTlet.

# 4. Copy the SuiteCloud CLI JAR to the standard location (one-time)
mkdir -p ~/.suitecloud-sdk/cli
cp ~/.suitecloud-sdk/vscode/cli-*.jar ~/.suitecloud-sdk/cli/

# 5. Create your TBA credentials file
mkdir -p ~/.suigit
cp examples/config.example.json ~/.suigit/config.json
# then edit ~/.suigit/config.json with the 5 secrets you generate in NetSuite UI
# (see Onboarding doc Section B.4 + B.5)
```

Then add the keybinding ([Preferences: Open Keyboard Shortcuts (JSON)](https://code.visualstudio.com/docs/getstarted/keybindings#_advanced-customization)):

```json
{
  "key": "shift+alt+u",
  "command": "workbench.action.tasks.runTask",
  "args": "SuiGit: Upload + Capture (active file)"
}
```

Open any file under `src/FileCabinet/SuiteScripts/` and press **Shift+Alt+U**. The
SuiteCloud CLI uploads it, then SuiGit writes a version record. Verify in NetSuite:
`Customization → Lists, Records, & Fields → Record Types → SuiGit Version → List`.

## Repository layout

```
SuiGit/
├── src/                          # SDF project root (the part deployed to NetSuite)
│   ├── FileCabinet/SuiteScripts/
│   │   └── crw_rs_suigit_script.js        # The capture RESTlet
│   └── Objects/
│       ├── customrecord_suigit_version.xml    # Versions table schema
│       └── customscript_crw_rs_suigit_script.xml
├── scripts/
│   ├── suigit-push.ps1                # Workstation push driver
│   └── generate-onboarding-docx.py    # Regenerates the Word onboarding doc
├── examples/
│   └── config.example.json            # Template for ~/.suigit/config.json
├── docs/
│   └── SuiGit-Onboarding.docx         # Full step-by-step guide
├── .vscode/
│   └── tasks.json                     # SuiGit tasks (Upload+Capture, Capture only, Dry run)
├── deploy.xml                         # SDF deploy manifest
├── manifest.xml                       # SDF project manifest
├── project.json                       # ⚠️ Per-developer (gitignored) — created by `suitecloud account:setup`
├── suitecloud.config.js               # SDF project config
└── README.md
```

## Daily commands

| Trigger | What it does |
|---|---|
| **Shift+Alt+U** | Upload active file via SuiteCloud + capture version. Primary daily flow. |
| **Ctrl+Alt+U** | Capture only — record disk state of changed files, no upload. Use when you deployed via another route. |
| `Tasks: Run Task → SuiGit: Push & Capture` | Batch mode — deploy whole project + capture all changed files. |
| `Tasks: Run Task → SuiGit: Push (dry run)` | Build payload and print, don't deploy or POST. |

## Security model

- TBA credentials live in `%USERPROFILE%\.suigit\config.json`, **outside the repo**. Never committed.
- Each developer holds their own access token tied to their NetSuite user. Revoking a token kills only that workstation.
- RESTlet input is parsed defensively: per-file failures don't abort the batch, fields are truncated to schema limits, OAuth 1.0a signatures are enforced by NetSuite.

## Troubleshooting

See [docs/SuiGit-Onboarding.docx](docs/SuiGit-Onboarding.docx) → Section F for a complete cause-and-fix table. Common ones:

- **`SuiGit config not found`** — you missed step 5 of Quick Start.
- **`There is no JAR file in your CLI for Node.js`** — you missed step 4.
- **`403 Forbidden`** — TBA credentials wrong, or the role used to create the token lacks `REST Web Services` + `Log in using Access Tokens` permissions.

## Contributing

The Python onboarding-doc generator at [scripts/generate-onboarding-docx.py](scripts/generate-onboarding-docx.py)
is the source of truth for [docs/SuiGit-Onboarding.docx](docs/SuiGit-Onboarding.docx). If you update the doc,
edit the Python script and re-run:

```
python scripts/generate-onboarding-docx.py
```

Commit both files so the docx stays in sync.
