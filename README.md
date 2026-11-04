# neostar

Neovim support for [F\*](https://github.com/FStarLang/FStar), including Pulse.

- Tree-sitter highlighting for `.fst` / `.fsti`, with Pulse highlighted inside `#lang-pulse` tails and Pulse fences
- One `fstar.exe --ide` checker per buffer, configured from the nearest `*.fst.config.json`
- **Lax checking by default**: buffers are type-checked (no SMT) as you edit, and full verification runs only when you ask for it
- A per-declaration frontier in the sign column (verified / lax-only / failed / in flight / not reached) and a statusline summary
- Hover, go-to-definition, completion, and diagnostics through Neovim's built-in LSP client (an in-process shim, so no extra server is needed)
- `:NeostarCompute` evaluates an expression in the context of the checked code
- An agent bridge (Claude Code or GitHub Copilot CLI): `:NeostarExplain` explains code or why it fails, and `:NeostarProve` asks the agent to prove a lemma, checked by F\* and reviewed by you as a diff

Requires Neovim 0.11 or later (tested on 0.12) and an `fstar.exe` that supports `--ide`. The agent commands also need [Claude Code](https://claude.com/claude-code) (`claude`) or [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli) (`copilot`) on `PATH`, logged in.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  dir = "kapilash/neostar", 
  ft = "fstar",
  opts = {},
}
```

The plugin attaches automatically to `fstar` buffers. `setup()` is optional and only needed to change [options](#configuration).

### Tree-sitter parsers

neostar highlights with the [tree-sitter-fstar](https://github.com/FStarLang/tree-sitter-fstar) grammars `fstar` and `pulse`, pinned to the revision the bundled queries were copied from.

**With nvim-treesitter** (both the `master` and `main` branches work): neostar registers the two parsers, so you can install them with:

```vim
:TSInstall fstar pulse
```

**Without nvim-treesitter**, build the parsers yourself and put them on your `runtimepath`:

```sh
git clone https://github.com/FStarLang/tree-sitter-fstar
cd tree-sitter-fstar
git checkout f5aca8ce0122f0ac10eaeb6f3081382d59d294f2
mkdir -p ~/.local/share/nvim/site/parser
cc -O2 -shared -fPIC -Isrc -o ~/.local/share/nvim/site/parser/fstar.so src/parser.c src/scanner.c
cc -O2 -shared -fPIC -Ipulse/src -o ~/.local/share/nvim/site/parser/pulse.so pulse/src/parser.c pulse/src/scanner.c
```

If the `fstar` parser is missing, neostar shows one notification and turns highlighting off. Everything else keeps working.

## Commands

| Command | What it does |
|---|---|
| `:NeostarVerify` | Fully verify the buffer, including SMT |
| `:NeostarVerifyToCursor` | Fully verify up to the declaration under the cursor; the rest is lax-checked |
| `:NeostarCancel` | Cancel the running check. If F\* is stuck in a long SMT query, you're offered a kill and restart (this loses verified status) |
| `:NeostarRestart` | Start a fresh checker for the buffer and lax-check it |
| `:NeostarReloadDeps` | Restart the checker so it re-reads dependencies from disk, then lax-check. Verified marks are dropped because a dependency may have changed. This happens automatically for other open buffers in the project when you write an F\* file |
| `:NeostarExplain` / `:'<,'>NeostarExplain` | Ask the agent to explain the declaration at the cursor or the selection (see [Agent bridge](#agent-bridge)) |
| `:NeostarProve` | Ask the agent to prove the `let` under the cursor; a verified proof is shown as a diff to accept or reject |
| `:NeostarAgentStop` | Stop the agent run for this buffer |
| `:NeostarCompute {expr}` / `:'<,'>NeostarCompute` | Evaluate an expression (or the selection) in the context of the checked code and show the result in a float (`q` closes it) |

Lax checks run when you open a buffer, after you pause editing, and when the file changes on disk (for example, when an agent edits it). `:w` never starts a verification.

Hover (`K`), go-to-definition (`gd` or `vim.lsp.buf.definition()`), completion and diagnostics come from the `neostar` LSP client. During a full verification, hover and completion return nothing instead of blocking. They never cancel the check.

## Agent bridge

neostar starts the agent itself, inside Neovim, with the project root (the directory of `*.fst.config.json`) as its working directory. The agent can **read** project files and query the buffer's running F\* checker through neostar's tools (`fstar_lookup`, `fstar_compute`, `fstar_diagnostics`). `neostar_context` supplies the authoritative **unsaved buffer**, its revision, selected code or proof target, and checker freshness; ordinary file-reading tools still see disk contents. It has no tool that writes files or runs commands, and your other MCP servers (including Copilot's built-in GitHub server) are not available to it.

Two agents are supported. With the default `agent.runner = "auto"`, neostar uses Claude Code if `claude` is found, otherwise GitHub Copilot CLI, so one config works on a machine with either. Set `runner = "claude"` or `"copilot"` to force one.

| | Claude Code | GitHub Copilot CLI |
|---|---|---|
| executable / model | `agent.claude.cmd` / `agent.claude.model` | `agent.copilot.cmd` / `agent.copilot.model` |
| project instructions that apply | `CLAUDE.md` | `AGENTS.md` and Copilot's instruction files |
| cost | tokens on your Claude account | one premium request per Explain, Prove or follow-up, times the model's multiplier |
| needs | `claude` logged in | `copilot` logged in, and MCP servers allowed by your organization's Copilot policy |

Without a model setting, each agent uses its own default model; for Copilot that may be a premium model, so consider setting `agent.copilot.model`. If Copilot cannot connect to neostar's tool server (for example because a policy disables MCP servers), the run stops with an error saying so.

### Persistent Copilot runtime (optional Rust helper)

From the neostar repository, install the native helper with Rust 1.94 or later:

```sh
cargo install --locked --path tools/copilot
```

Put Cargo's bin directory (normally `~/.cargo/bin`) on Neovim's `PATH`, and select Copilot:

```lua
require("neostar").setup({ agent = { runner = "copilot" } })
```

The default `agent.copilot.transport = "auto"` uses `neostar-copilot` when installed, otherwise the existing CLI transport. `"sdk"` requires the helper; `"cli"` always starts a CLI process per turn. Set `agent.copilot.helper` for a custom helper path. No Node.js helper dependency is needed: the Rust binary uses the installed, authenticated `agent.copilot.cmd`.

The SDK transport keeps one runtime per project/executable and separate conversations per Explain window. Follow-ups keep their original runner, model and transport, even if `setup()` changes. MCP credentials are replaced on each turn; failures are reported without silently retrying a paid request through another transport. Runtimes close when their last source buffer detaches or Neovim exits. SDK conversations are stored below `stdpath("state")/neostar/copilot`, separately from terminal Copilot sessions.

`:checkhealth neostar` reports executable/parser availability, runner, model and transport. Agent windows also show the runner/transport and configured model. Missing Markdown parsers no longer prevent agent windows from opening.

### Explain

`:NeostarExplain` explains the declaration under the cursor; `:'<,'>NeostarExplain` explains the selected lines. The agent receives the code, the F\* status of its declarations and any F\* errors in the range. If there are errors, it explains why F\* rejects the code and how it could be fixed. The answer streams into a float:

| Key | Action |
|---|---|
| `f` | ask a follow-up question in the same conversation |
| `q` / `<Esc>` | close (stops the agent if it is still answering) |

Follow-ups refresh the selected unsaved code, revision and diagnostics rather than relying on the first prompt. If the selection is deleted, start a new explanation. A follow-up cannot replace another active request.

### Prove

`:NeostarProve` asks the agent to prove the `let` under the cursor (in an `.fst` file). The agent works against F\*:

- It can only supply a **proof body** and new **helper lemmas**, which go directly above the target (above its `val`, if there is one). The target's **statement is never changed**: neostar takes it verbatim from your buffer for every check and for the final edit.
- Candidates containing `admit`, `assume`, `magic`, `expect_failure`, or options that turn off proof checking are rejected before they reach F\*.
- Each candidate is checked in a separate **scratch F\* process**. The code above the target is checked without SMT, and the helpers and target are fully verified. Your buffer's own checker, its verified marks and its diagnostics are not touched.
- A request stops after `agent.max_checks` checks (default 10) or `agent.timeout_ms` (default 5 minutes, including review and accept-time rechecking). Progress ("attempt 3/10") and each F\* result appear in a float.

Only a proof that **passed full verification** is offered. It appears as a diff:

| Key | Action |
|---|---|
| `a` | accept: apply helpers and body as one edit (a single `u` undoes it); the buffer is then lax-checked |
| `r` / `q` | reject: the buffer stays as it is |
| `<CR>` | jump to the target |

If you edited the code above the target meanwhile, the proof is re-checked against the current text before it is applied, and it is refused if it no longer verifies. Moving the target is safe; changing its statement, `val` or body requires a new request. An edit during asynchronous rechecking refuses the result rather than overwriting newer text. The file is never written; save it yourself. Mutually recursive `let rec ... and ...` targets are not supported yet.

`:NeostarAgentStop` (from the buffer, an agent window or a proof diff) stops the whole request, including review and its scratch checker. Unloading the source buffer also stops its request; closing an old Explain window does not stop a newer request.

## Configuration

`setup()` is optional. These are the defaults:

```lua
require("neostar").setup({
  fstar_exe = nil,               -- override the F* executable
  debounce_ms = 500,             -- pause after edits before lax-checking
  lax_request_timeout_ms = 2000, -- how long hover/completion wait for a lax check
  cancel_timeout_ms = 5000,      -- before offering to kill a check that won't stop
  signs = { --[[ see below ]] },
  lsp = true,                    -- in-process LSP client
  treesitter = true,             -- tree-sitter highlighting
  agent = {
    runner = "auto",             -- "auto" (Claude Code, else Copilot), "claude" or "copilot"
    claude = { cmd = "claude", model = nil },   -- nil model = Claude Code's default
    copilot = {
      cmd = "copilot", model = nil, -- nil model = Copilot's default
      transport = "auto",          -- "auto", "sdk" or "cli"
      helper = "neostar-copilot",  -- optional native Rust helper
    },
    max_checks = 10,             -- candidate checks per :NeostarProve request
    timeout_ms = 300000,         -- time limit per :NeostarProve request
  },
})
```

`agent.cmd` and `agent.model` were replaced by the per-agent tables above; setting them shows an error naming the replacement.

See `:help neostar` for details.

## Verification frontier

Every line of each top-level declaration gets a sign showing what F\* has established about it:

| Status | Default sign | Highlight group (default link) | Meaning |
|---|---|---|---|
| verified | `┃` | `NeostarVerified` (`DiagnosticOk`) | fully checked, including SMT |
| lax-only | `┆` | `NeostarLax` (`Comment`) | type-checked without SMT. **Not proven.** |
| failed | `┃` | `NeostarFailed` (`DiagnosticError`) | F\* reported an error |
| in flight | `│` | `NeostarInflight` (`DiagnosticWarn`) | being checked right now |
| not reached | `·` | `NeostarUnreached` (`NonText`) | changed, or not checked yet (F\* stops at the first failure) |

Verified and lax-only always use different glyphs and highlight groups, so a lax pass never looks like a proof. When you edit, declarations above the edit keep their verified status; the affected declaration and everything below it immediately become not reached, then receive fresh statuses on the next check.

To change glyphs or groups:

```lua
require("neostar").setup({
  signs = {
    verified = { text = "▌", hl = "NeostarVerified" },
    lax = { text = "╎", hl = "NeostarLax" },
  },
})
vim.api.nvim_set_hl(0, "NeostarLax", { fg = "#7a7a7a" })
```

### Statusline

`require("neostar").status()` returns counts for the current buffer: `{ verified, lax, failed, unchecked, running, alive }`. `running` is `"lax"`, `"full"`, `"verify-to-position"`, or `nil` when idle. `require("neostar").statusline()` formats this as a short string, for example `F* ✓17 ~25 ✗0 ?0 [full…]` (✓ verified, ~ lax-only, ✗ failed, ? unchecked). It returns `""` for buffers that aren't F\* files.

With [lualine](https://github.com/nvim-lualine/lualine.nvim):

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      {
        function() return require("neostar").statusline() end,
        cond = function() return vim.bo.filetype == "fstar" end,
      },
      "filetype",
    },
  },
})
```

## Development

```sh
make test               # unit tests (headless Neovim, replayed F* transcripts)
make test-integration   # end-to-end tests against a real fstar.exe on PATH
make copilot-helper     # build the optional Rust helper (release)
make test-copilot-helper # offline SDK transport and permission regressions
```

`scripts/record_transcript.py` re-records the F\* transcripts in `tests/fixtures/transcripts/` from the scenarios in `tests/fixtures/files/`.
