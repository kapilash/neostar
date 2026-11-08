--- neostar: F* support for Neovim.

local M = {}

M.defaults = {
  --- Override the F* executable (otherwise from *.fst.config.json or PATH).
  fstar_exe = nil,
  --- Delay after the last edit before a lax check starts.
  debounce_ms = 500,
  --- How long hover/completion wait for a running lax check.
  lax_request_timeout_ms = 2000,
  --- How long a cancel may take before offering to kill and restart F*.
  cancel_timeout_ms = 5000,
  --- Sign glyphs and highlight groups per declaration status.
  signs = vim.deepcopy(require("neostar.ui.signs").default_signs),
  --- Start the in-process LSP client (hover, definition, completion, diagnostics).
  lsp = true,
  --- Start tree-sitter highlighting for F* buffers.
  treesitter = true,
  --- Agent features (:NeostarExplain, :NeostarProve).
  agent = {
    --- Which agent to use: "auto" (Claude Code if `claude.cmd` is found,
    --- otherwise GitHub Copilot CLI), "claude" or "copilot".
    runner = "auto",
    --- Claude Code: executable, and model (nil uses Claude Code's default).
    claude = { cmd = "claude", model = nil },
    --- GitHub Copilot CLI: executable, and model (nil uses Copilot's default).
    copilot = { cmd = "copilot", model = nil, transport = "auto", helper = "neostar-copilot" },
    docs = {
      enabled = false,
      python = "python3",
      server = nil,
      index = vim.fn.stdpath("data") .. "/neostar/ulib.index.json",
    },
    --- Maximum candidate checks per :NeostarProve request.
    max_checks = 10,
    --- Time limit for a :NeostarProve request.
    timeout_ms = 300000,
  },
}

M.options = vim.deepcopy(M.defaults)

---@type table<integer, neostar.Session>
M.sessions = {}

--- Session option overrides applied when `attach` gets none (used by tests).
M._default_overrides = nil

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "neostar" })
end

--- Agent options removed in favour of per-agent tables.
local REMOVED_AGENT_KEYS = {
  cmd = "agent.cmd was replaced by agent.claude.cmd / agent.copilot.cmd",
  model = "agent.model was replaced by agent.claude.model / agent.copilot.model",
}

--- Check the agent options; returns an error message or nil.
local function validate_agent(a)
  local function pos_int(v)
    return type(v) == "number" and v >= 1 and v == math.floor(v)
  end
  local function pos(v)
    return type(v) == "number" and v > 0
  end
  for key, msg in pairs(REMOVED_AGENT_KEYS) do
    if a[key] ~= nil then
      return msg
    end
  end
  local runners = require("neostar.agent.runner").registry
  local ok, err = pcall(function()
    vim.validate("agent.runner", a.runner, "string")
    for name in pairs(runners) do
      vim.validate("agent." .. name, a[name], "table")
      vim.validate("agent." .. name .. ".cmd", a[name].cmd, "string")
      vim.validate("agent." .. name .. ".model", a[name].model, "string", true)
    end
    vim.validate("agent.max_checks", a.max_checks, pos_int, "a positive integer")
    vim.validate("agent.timeout_ms", a.timeout_ms, pos, "a positive number")
    vim.validate("agent.copilot.helper", a.copilot.helper, "string")
    vim.validate("agent.docs", a.docs, "table")
    vim.validate("agent.docs.enabled", a.docs.enabled, "boolean")
    vim.validate("agent.docs.python", a.docs.python, "string")
    vim.validate("agent.docs.server", a.docs.server, "string", true)
    vim.validate("agent.docs.index", a.docs.index, "string")
    vim.validate("agent.copilot.transport", a.copilot.transport, function(value)
      return value == "auto" or value == "cli" or value == "sdk"
    end, '"auto", "cli" or "sdk"')
  end)
  if not ok then
    return tostring(err)
  end
  if a.runner ~= "auto" and not runners[a.runner] then
    return ("agent.runner: unknown runner `%s` (use \"auto\", \"claude\" or \"copilot\")"):format(a.runner)
  end
  return nil
end

--- Configure the plugin. Optional: defaults apply without calling it.
---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  local err = validate_agent(M.options.agent)
  if err then
    notify("neostar: invalid option " .. err .. "; using the default agent options", vim.log.levels.ERROR)
    M.options.agent = vim.deepcopy(M.defaults.agent)
  end
  M.options.agent.docs = require("neostar.agent.docs").normalize(M.options.agent.docs)
  require("neostar.treesitter").register_with_nvim_treesitter()
end

---@param bufnr? integer
---@return neostar.Session?
function M.session(bufnr)
  if bufnr == nil or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return M.sessions[bufnr]
end

--- Statusline summary table for a buffer (nil if not an F* buffer).
---@param bufnr? integer
---@return neostar.Summary?
function M.status(bufnr)
  return require("neostar.ui.status").summary(M.session(bufnr))
end

--- Short statusline text for a buffer ("" if not an F* buffer).
---@param bufnr? integer
---@return string
function M.statusline(bufnr)
  return require("neostar.ui.status").text(M.session(bufnr))
end

local function buf_file(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" or vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  return vim.fs.normalize(vim.fn.fnamemodify(name, ":p"))
end

--- Attach neostar to an F* buffer: tree-sitter, checker session, signs, LSP.
---@param bufnr integer
---@param overrides? table session option overrides (tests)
---@return neostar.Session?
function M.attach(bufnr, overrides)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local opts = M.options
  if opts.treesitter then
    require("neostar.treesitter").start(bufnr, notify)
  end
  if M.sessions[bufnr] then
    return M.sessions[bufnr]
  end
  local file = buf_file(bufnr)
  if not file then
    return nil
  end

  local cfgmod = require("neostar.config")
  local cfg, err = cfgmod.for_file(file, opts.fstar_exe)
  if not cfg then
    notify("neostar: " .. err, vim.log.levels.ERROR)
    return nil
  end
  if cfg.warning then
    notify("neostar: " .. cfg.warning, vim.log.levels.WARN)
  end

  local session_opts = vim.tbl_extend("force", {
    cmd = cfgmod.command(file, cfg),
    cwd = cfg.root,
    root = cfg.root,
    file = file,
    debounce_ms = opts.debounce_ms,
    lax_request_timeout_ms = opts.lax_request_timeout_ms,
    cancel_timeout_ms = opts.cancel_timeout_ms,
    notify = notify,
  }, overrides or M._default_overrides or {})

  local session = require("neostar.fstar.session").new(bufnr, session_opts)
  M.sessions[bufnr] = session

  require("neostar.ui.signs").attach(bufnr, session, function()
    return M.options.signs
  end)
  session:subscribe(function(event)
    if event == "state" then
      vim.schedule(function()
        vim.cmd("redrawstatus")
      end)
    end
  end)

  -- Edits and reloads drive the check policy.
  vim.api.nvim_buf_attach(bufnr, false, {
    on_bytes = function(_, _, _, srow, _, _, old_erow, _, _, new_erow)
      if M.sessions[bufnr] ~= session then
        return true -- detach
      end
      local last = srow + math.max(old_erow, new_erow)
      local seq = session:note_edit()
      vim.schedule(function()
        if M.sessions[bufnr] ~= session then
          return
        end
        if session:invalidate_rows(srow, last) then
          session:emit("fragments")
          session:emit("diagnostics")
        end
        session:on_edit(seq)
      end)
    end,
    on_reload = function()
      if M.sessions[bufnr] ~= session then
        return true
      end
      vim.schedule(function()
        if M.sessions[bufnr] == session then
          session:on_reload()
        end
      end)
    end,
    on_detach = function() end,
  })

  local group = vim.api.nvim_create_augroup("neostar.buf." .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    buffer = bufnr,
    callback = function()
      session:on_save()
      M.reload_dependents(bufnr)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete", "BufWipeout" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      M.detach(bufnr)
    end,
  })

  if opts.lsp then
    session.lsp_client = require("neostar.lsp").attach(session)
  end

  if session:start() then
    session:check("lax")
  end
  return session
end

--- Stop the checker and remove neostar state from a buffer.
function M.detach(bufnr)
  if package.loaded["neostar.agent"] then
    require("neostar.agent").stop(bufnr, "source buffer detached")
  end
  if package.loaded["neostar.agent.copilot_sdk"] then
    require("neostar.agent.copilot_sdk").detach(bufnr)
  end
  local session = M.sessions[bufnr]
  if not session then
    return
  end
  M.sessions[bufnr] = nil
  pcall(vim.api.nvim_del_augroup_by_name, "neostar.buf." .. bufnr)
  if session.lsp_client then
    local client = vim.lsp.get_client_by_id(session.lsp_client)
    if client then
      client:stop()
    end
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, require("neostar.ui.signs").ns, 0, -1)
  end
  session:destroy()
end

--- After an F* file is written, other open buffers of the same project
--- reload their dependencies.
function M.reload_dependents(written_bufnr)
  local written = M.sessions[written_bufnr]
  local root = written and written.root
  if not root then
    local file = buf_file(written_bufnr)
    local cfg = file and require("neostar.config").for_file(file)
    root = cfg and cfg.root
  end
  for bufnr, s in pairs(M.sessions) do
    if bufnr ~= written_bufnr and s.root == root and s.alive then
      s:reload_deps()
    end
  end
end

function M.stop_all()
  if package.loaded["neostar.agent"] then
    require("neostar.agent").stop_all()
  end
  if package.loaded["neostar.agent.mcp"] then
    require("neostar.agent.mcp").stop()
  end
  for bufnr in pairs(M.sessions) do
    M.detach(bufnr)
  end
  if package.loaded["neostar.agent.copilot_sdk"] then
    require("neostar.agent.copilot_sdk").shutdown()
  end
  if package.loaded["neostar.agent.docs"] then
    require("neostar.agent.docs").shutdown()
  end
end

-- commands -----------------------------------------------------------------------

local function with_session(fn)
  local s = M.session(0)
  if not s then
    notify("neostar: not an F* buffer with a running checker", vim.log.levels.WARN)
    return
  end
  fn(s)
end

function M.verify()
  with_session(function(s)
    s:check("full")
  end)
end

function M.verify_to_cursor()
  with_session(function(s)
    local cur = vim.api.nvim_win_get_cursor(0)
    local text = vim.api.nvim_get_current_line()
    local line, col = require("neostar.fstar.transport").to_fstar_pos(cur[1] - 1, cur[2], text)
    s:check("verify-to-position", { line, col })
  end)
end

function M.cancel()
  with_session(function(s)
    s:cancel()
  end)
end

function M.restart()
  local bufnr = vim.api.nvim_get_current_buf()
  local s = M.sessions[bufnr]
  if s then
    s:restart()
  elseif vim.bo[bufnr].filetype == "fstar" then
    M.attach(bufnr)
  end
end

function M.reload_deps()
  with_session(function(s)
    s:reload_deps()
  end)
end

--- Evaluate a term with F* `compute` and show the result.
---@param term string
---@param on_done? fun(status: string, response: any) for tests
function M.compute(term, on_done)
  with_session(function(s)
    term = vim.trim(term or "")
    if term == "" then
      notify("neostar: nothing to evaluate", vim.log.levels.WARN)
      return
    end
    if s:running_class() then
      notify("neostar: F* is checking; evaluation is unavailable until the check finishes", vim.log.levels.WARN)
      if on_done then
        on_done("busy", nil)
      end
      return
    end
    s:query("compute", { term = term }, function(status, resp)
      if status == "busy" or status == "unavailable" then
        notify("neostar: F* is checking; evaluation is unavailable until the check finishes", vim.log.levels.WARN)
      else
        require("neostar.ui.compute").show(status == "success", resp, term)
      end
      if on_done then
        on_done(status, resp)
      end
    end)
  end)
end

local function selection_text(line1, line2)
  local s = vim.fn.getpos("'<")
  local e = vim.fn.getpos("'>")
  if s[2] == line1 and e[2] == line2 then
    local mode = vim.fn.visualmode()
    local lines = vim.fn.getregion(s, e, { type = mode ~= "" and mode or "v" })
    return table.concat(lines, "\n")
  end
  return table.concat(vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false), "\n")
end

function M.create_commands()
  local cmd = vim.api.nvim_create_user_command
  cmd("NeostarVerify", M.verify, { desc = "Fully verify the F* buffer (with SMT)" })
  cmd("NeostarVerifyToCursor", M.verify_to_cursor, { desc = "Fully verify the F* buffer up to the cursor" })
  cmd("NeostarCancel", M.cancel, { desc = "Cancel the running F* check" })
  cmd("NeostarRestart", M.restart, { desc = "Restart the F* checker for this buffer" })
  cmd("NeostarReloadDeps", M.reload_deps, { desc = "Reload F* dependencies from disk and re-check" })
  cmd("NeostarDocsReload", function()
    local docs = require("neostar.agent.docs")
    local err = docs.problem(M.options.agent.docs)
    docs.reload()
    notify(err or "neostar: documentation index will be read on the next tool call or agent request",
      err and vim.log.levels.WARN or vim.log.levels.INFO)
  end, { desc = "Reload the externally generated F* documentation index" })
  cmd("NeostarCompute", function(a)
    local term = a.args
    if term == "" and a.range > 0 then
      term = selection_text(a.line1, a.line2)
    end
    M.compute(term)
  end, { nargs = "*", range = true, desc = "Evaluate an F* expression (argument or visual selection)" })
  cmd("NeostarExplain", function(a)
    if a.range > 0 then
      require("neostar.explain").explain(vim.api.nvim_get_current_buf(), a.line1, a.line2)
    else
      require("neostar.explain").explain(vim.api.nvim_get_current_buf())
    end
  end, { range = true, desc = "Ask the agent to explain the selection or the declaration at the cursor" })
  cmd("NeostarProve", function()
    require("neostar.prove").prove(vim.api.nvim_get_current_buf())
  end, { desc = "Ask the agent to prove the `let` at the cursor (result shown as a diff)" })
  cmd("NeostarAgentStop", function()
    local bufnr = vim.b.neostar_source or vim.api.nvim_get_current_buf()
    if not require("neostar.agent").stop(bufnr, "stopped by :NeostarAgentStop") then
      notify("neostar: no agent run in this buffer")
    end
  end, { desc = "Stop the agent run for this buffer" })
end

return M
