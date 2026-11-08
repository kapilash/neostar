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
| `:NeostarDocs [module]` | Browse library declarations from the documentation index (see [Browsing the documentation](#browsing-the-documentation)) |
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

### Library documentation retrieval

Optionally give proof and explanation agents access to an existing **fstardoc JSON index**:

```lua
require("neostar").setup({
  agent = {
    docs = {
      enabled = true, -- disabled by default
      index = vim.fn.stdpath("data") .. "/neostar/ulib.index.json",
    },
  },
})
```

neostar reads the index itself and answers the agent's queries inside Neovim, so serving needs no Python. Generate the index externally with `fstardoc_mcp.py index` (which does need F\* and Python with `markdown-it`); neostar does not generate indexes, download tooling, or check source automatically. It reads index schema `fstardoc-retrieval-index` version 1 and refuses other versions with a warning. Paths expand `~` and resolve relative to the working directory when `setup()` runs.

To have `fstardoc_mcp.py serve` answer instead, set `server` (and, if needed, `python`):

```lua
docs = {
  enabled = true,
  index = vim.fn.stdpath("data") .. "/neostar/ulib.index.json",
  server = vim.fn.expand("~/src/mine/FStar/.scripts/fstardoc/fstardoc_mcp.py"),
  python = "python3",
},
```

Both backends give the same answers; the server is useful to follow a newer `fstardoc_mcp.py` than neostar knows about.

Six read-only tools are offered through neostar's existing authenticated MCP endpoint: `fstardoc_find_by_contract`, `fstardoc_find_by_type`, `fstardoc_lookup`, `fstardoc_used_by`, `fstardoc_list_module`, and `fstardoc_modules`. Agents can discover lemmas by what their contracts guarantee or by type shape, then inspect signatures, documentation, and worked uses. This works with Claude, Copilot CLI, and Copilot SDK; **rebuild an older Rust helper** with `cargo install --locked --path tools/copilot` to allow these tools.

The index is static, covers exported public declarations, and may be incomplete or out of date with your checker. Indexed lookup complements, rather than replaces, live `fstar_lookup` and authoritative unsaved `neostar_context`; proof candidates still require full verification and human review. The entire index is never inserted into prompts, and agents get no additional filesystem or server access.

Missing or failed documentation produces a visible warning and leaves checker tools usable. Explanation follow-ups retain the original documentation configuration. The in-process backend re-reads the index when the file changes; `:NeostarDocsReload` forces that, and also restarts a configured server (pending retrievals receive a retry error). Runs that started without documentation gain it only on a new request. `:checkhealth neostar` reports the backend, paths, prerequisites, and the last backend error.

### Browsing the documentation

`:NeostarDocs [module]` lists the declarations in the index (all, or one module's, with module-name completion) using [Telescope](https://github.com/nvim-telescope/telescope.nvim) when it is installed and `vim.ui.select` otherwise. It reads `agent.docs.index` and does not need `agent.docs.enabled`. Fuzzy matching runs on the name and the signature, and the preview shows the signature, documentation, contract, and definition.

| Key | Action |
|---|---|
| `<CR>` | open the declaration's source at its range |
| `<C-y>` | insert its fully qualified name at the cursor (Telescope only) |

The source file is looked for in the current project's root and `include_dirs`, the working directory, and the F\* library (`fstar.exe --locate_lib` and its `fstar.include`).

Telescope users can also use `:Telescope neostar declarations module=FStar.Seq.Base` and `:Telescope neostar modules` (choose a module to list its declarations). The extension loads on first use of `:NeostarDocs`, or call `require("telescope").load_extension("neostar")`.

### Persistent Copilot runti

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
    docs = {
      enabled = false, python = "python3", server = nil,
      index = vim.fn.stdpath("data") .. "/neostar/ulib.index.json",
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
