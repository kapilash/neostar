--- :NeostarExplain — ask an agent to explain a range of F* code (or why it
--- fails), streaming the answer into a floating window with follow-ups.

local M = {}

M.system_prompt = table.concat({
  "You are helping a person read F* code (possibly with Pulse) in their editor (Neovim).",
  "Answer in concise Markdown aimed at someone reviewing the code.",
  "You can read project files, and you can query the editor's running F* checker with the tools",
  "fstar_lookup (types and definitions of names), fstar_compute (evaluate a term) and",
  "fstar_diagnostics (current errors and verification status). Use fstar_lookup for names you",
  "are unsure about instead of guessing. You cannot edit files; do not claim to have changed anything.",
  "neostar_context returns the authoritative unsaved buffer and its revision; disk files may differ.",
  "Check its checker.current flag before treating diagnostics as up to date.",
}, " ")

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "neostar" })
end

--- Statuses and errors of the declarations overlapping rows [r1, r2] (0-based).
---@param s neostar.Session
function M.context(s, r1, r2)
  local statuses, errors = {}, {}
  for _, item in ipairs(s:sorted_fragments()) do
    if item.srow <= r2 and item.erow >= r1 then
      table.insert(statuses, { srow = item.srow, erow = item.erow, status = item.fragment.status })
    end
  end
  for _, d in ipairs(s:diagnostics()) do
    if d.lnum >= r1 and d.lnum <= r2 and d.severity <= vim.diagnostic.severity.WARN then
      table.insert(errors, d)
    end
  end
  return statuses, errors
end

local STATUS_TEXT = {
  verified = "verified (fully checked, including SMT)",
  lax = "lax-checked only (type-checked without SMT; not proven)",
  failed = "failed",
  inflight = "being checked",
  unreached = "not checked yet",
}

--- Build the prompt for a range.
function M.build_prompt(s, r1, r2, lines, question)
  local statuses, errors = M.context(s, r1, r2)
  local rel = vim.fn.fnamemodify(s.file, ":.")
  local root = s.root
  if root and s.file:sub(1, #root + 1) == root .. "/" then
    rel = s.file:sub(#root + 2)
  end
  local out = {
    ("File: %s, lines %d-%d"):format(rel, r1 + 1, r2 + 1),
    require("neostar.agent.context").header(s),
    "",
  }
  if #statuses > 0 then
    table.insert(out, "F* status of the declarations in this range:")
    for _, st in ipairs(statuses) do
      table.insert(out, ("- lines %d-%d: %s"):format(st.srow + 1, st.erow + 1, STATUS_TEXT[st.status] or st.status))
    end
    table.insert(out, "")
  end
  local failing = false
  if #errors > 0 then
    table.insert(out, "F* reports these problems in this range:")
    for _, d in ipairs(errors) do
      if d.severity == vim.diagnostic.severity.ERROR then
        failing = true
      end
      table.insert(
        out,
        ("- %s at line %d, column %d:\n%s"):format(
          d.severity == vim.diagnostic.severity.ERROR and "error" or "warning",
          d.lnum + 1,
          d.col + 1,
          d.message
        )
      )
    end
    table.insert(out, "")
  end
  table.insert(out, "```fstar")
  vim.list_extend(out, lines)
  table.insert(out, "```")
  table.insert(out, "")
  if question then
    table.insert(out, "Follow-up question: " .. question)
  elseif failing then
    table.insert(
      out,
      "Explain why F* rejects this code: what the error means, which goal or fact it could not establish, and how the code or proof could be fixed."
    )
  else
    table.insert(
      out,
      "Explain what this code states and does, including the meaning of its specifications (types, refinements, pre- and postconditions)."
    )
  end
  return table.concat(out, "\n"), failing
end

--- Start a run (first question or follow-up) for an explain window.
local function run_agent(bufnr, s, state, prompt, resume)
  local agent = require("neostar.agent")
  local mcp = require("neostar.agent.mcp")
  local tools = require("neostar.agent.tools")
  local run = { kind = "explain", state = state }
  local function done(res)
    if run.reported then
      return
    end
    run.reported = true
    if state.on_done then
      state.on_done(res)
    end
  end
  run.on_stop = function(reason)
    if state.window and state.window:is_open() then
      state.window:append(("\n\n_(%s)_\n"):format(reason))
      state.window:set_status("stopped")
    end
    done({ ok = false, stopped = true, error = reason })
  end
  agent.begin(bufnr, run)
  state.window:set_status("thinking…")
  state.docs_config = state.docs_config or vim.deepcopy(require("neostar").options.agent.docs)
  require("neostar.agent.docs").prepare_run(run, state.docs_config, state.window, function(doc_tools, guidance)
    local token, server = mcp.register({
      bufnr = bufnr,
      position = { state.r1, 0 },
      selection = state.selection,
      request_revision = vim.api.nvim_buf_get_changedtick(bufnr),
      tools = vim.tbl_extend("force", tools.read_only(), doc_tools),
    })
    run.token = token
    -- A follow-up goes to the agent that owns the conversation.
    local handle, err, runner = require("neostar.agent.runner").start({
      bufnr = bufnr,
      keep_session = true,
      runner = resume and state.runner or nil,
      cwd = agent.project_root(s),
      prompt = guidance ~= "" and (prompt .. "\n\n" .. guidance) or prompt,
      system_prompt = M.system_prompt,
      mcp_server = server,
      resume = resume,
      on_text = function(t)
        if not run.ended then
          state.window:append(t)
        end
      end,
      on_tool = function(name)
        if not run.ended then
          state.window:set_status("using " .. name .. "…")
        end
      end,
      on_done = function(res)
        if run.ended then
          return
        end
        if res.session_id then
          state.session_id = res.session_id
        end
        if not res.stopped then
          agent.finish(bufnr, run)
          if res.ok then
            state.window:set_status("done")
          else
            state.window:append("\n\n**Error:** " .. tostring(res.error) .. "\n")
            state.window:set_status("failed")
          end
        end
        done(res)
      end,
    }, resume and state.runner_config or nil)
    if not handle then
      agent.finish(bufnr, run)
      state.window:append("**Error:** " .. err .. "\n")
      state.window:set_status("failed")
      notify(err, vim.log.levels.ERROR)
      vim.schedule(function()
        done({ ok = false, error = err })
      end)
      return
    end
    state.runner = runner
    state.runner_config = handle.config
    state.release = handle.release
    state.window:append("> Agent: " .. require("neostar.agent.runner").label(handle) .. "\n\n")
    run.handle = handle
  end)
end

--- Explain rows [line1, line2] (1-based, inclusive), or the declaration at the
--- cursor when no range is given.
---@param bufnr integer
---@param line1? integer
---@param line2? integer
---@param opts? {on_done?: fun(res: table)} for tests
---@return table? state
function M.explain(bufnr, line1, line2, opts)
  opts = opts or {}
  local s = require("neostar").session(bufnr)
  if not s then
    notify("neostar: not an F* buffer", vim.log.levels.WARN)
    return nil
  end
  local r1, r2
  if line1 and line2 then
    r1, r2 = line1 - 1, line2 - 1
  else
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    local d = require("neostar.fstar.decl").decl_at(bufnr, row)
    if not d then
      notify("neostar: select some code, or move the cursor to a declaration, to explain it", vim.log.levels.WARN)
      return nil
    end
    r1 = d.srow
    r2 = (d.ecol == 0 and d.erow > d.srow) and d.erow - 1 or d.erow
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, r1, r2 + 1, false)
  local prompt, failing = M.build_prompt(s, r1, r2, lines)
  local state = { r1 = r1, r2 = r2, prompt = prompt, failing = failing, on_done = opts.on_done }
  local context = require("neostar.agent.context")
  state.selection = context.track(bufnr, r1, r2)
  state.window = require("neostar.ui.agent_window").open({
    title = ("Explain %s:%d-%d"):format(vim.fn.fnamemodify(s.file, ":t"), r1 + 1, r2 + 1),
    source = bufnr,
    on_close = function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, context.ns, state.selection)
      end
      local run = require("neostar.agent").current(bufnr)
      if run and run.state == state then
        require("neostar.agent").stop(bufnr, "closed")
      end
      if state.release then
        state.release()
      end
    end,
    on_followup = function(q)
      local run = require("neostar.agent").current(bufnr)
      if run then
        notify("neostar: finish or stop the current request before asking a follow-up", vim.log.levels.WARN)
        return
      end
      if not state.window:is_open() or require("neostar").session(bufnr) ~= s then
        notify("neostar: the explanation's source buffer is no longer attached", vim.log.levels.WARN)
        return
      end
      if not state.session_id then
        notify("neostar: there is no conversation to continue", vim.log.levels.WARN)
        return
      end
      local first, last = context.range(bufnr, state.selection)
      if not first then
        notify("neostar: the selected code was deleted; start a new explanation", vim.log.levels.WARN)
        return
      end
      state.r1, state.r2 = first, last
      local current = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
      local next_prompt = M.build_prompt(s, first, last, current, q)
      state.window:append("\n\n---\n\n**You:** " .. q .. "\n\n")
      run_agent(bufnr, s, state, next_prompt, state.session_id)
    end,
  })
  run_agent(bufnr, s, state, prompt, nil)
  return state
end

return M
