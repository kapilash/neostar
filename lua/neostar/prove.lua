--- :NeostarProve — ask an agent to prove the `let` at the cursor. Candidates
--- are checked in a scratch F* process; a verified proposal is reviewed as a
--- diff before anything changes in the buffer.

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "neostar" })
end

M.system_prompt = table.concat({
  "You are proving an F* definition for a person working in their editor (Neovim).",
  "The statement of the target (its name, parameters, type, and any matching val) is fixed and",
  "comes from the file; you supply only a proof body and, optionally, new helper declarations",
  "that will be placed directly above the target.",
  "Use check_proof(helpers, body) to verify a candidate with F* (full SMT verification);",
  "it returns OK or F*'s errors with positions relative to your helpers/body.",
  "When a candidate is OK, call propose_proof with exactly the same helpers and body; the person",
  "will review it as a diff. admit, assume, magic, expect_failure and options that turn off",
  "proof checking are rejected. You can read project files and use fstar_lookup, fstar_compute",
  "and fstar_diagnostics. You cannot edit files. Keep your messages short: say what you are",
  "trying, not long explanations. If you cannot find a proof, stop and say briefly what is missing.",
  "neostar_context reads the current unsaved buffer. check_proof uses the frozen request revision,",
  "not later editor changes. Disk files may differ from both.",
}, " ")

--- Prompt for a target.
---@param s neostar.Session
---@param target neostar.ProveTarget
---@param max_checks integer
function M.build_prompt(s, target, max_checks)
  local rel = vim.fn.fnamemodify(s.file, ":t")
  if s.root and s.file:sub(1, #s.root + 1) == s.root .. "/" then
    rel = s.file:sub(#s.root + 2)
  end
  local out = {
    ("Prove `%s` in %s (line %d)."):format(target.name, rel, target.decl.srow + 1),
    require("neostar.agent.context").header(s),
    "",
  }
  table.insert(out, "Statement (fixed; you cannot change it):")
  table.insert(out, "```fstar")
  if target.val then
    table.insert(out, target.val.text)
  end
  vim.list_extend(out, vim.split(target.statement .. "<body>", "\n", { plain = true }))
  table.insert(out, "```")
  table.insert(out, "")
  table.insert(out, "Current body:")
  table.insert(out, "```fstar")
  vim.list_extend(out, vim.split(target.body, "\n", { plain = true }))
  table.insert(out, "```")
  local d = target.decl
  local errs = {}
  for _, diag in ipairs(s:diagnostics()) do
    if diag.lnum >= d.srow and diag.lnum <= d.erow and diag.severity == vim.diagnostic.severity.ERROR then
      table.insert(errs, ("- line %d: %s"):format(diag.lnum + 1, diag.message))
    end
  end
  if #errs > 0 then
    table.insert(out, "")
    table.insert(out, "F* currently reports:")
    vim.list_extend(out, errs)
  end
  table.insert(out, "")
  table.insert(
    out,
    ("Find a proof. Call check_proof until it returns OK (at most %d checks), then propose_proof with the same helpers and body."):format(
      max_checks
    )
  )
  return table.concat(out, "\n")
end

local function summary_line(result)
  if result.ok then
    return "OK"
  end
  local e = result.errors[1]
  if not e then
    return "failed"
  end
  local first = vim.split(vim.trim(e.message), "\n")[1]
  return ("%s: %s"):format(e.where, first)
end

--- Offer the verified proposal; on accept, re-check if the buffer changed.
local function review(bufnr, state, run, done)
  local p = state.proposal
  local function finish(outcome, msg)
    if msg then
      notify(msg, outcome == "applied" and vim.log.levels.INFO or vim.log.levels.WARN)
    end
    done({ outcome = outcome, message = msg })
  end
  local function current_target()
    if not vim.api.nvim_buf_is_loaded(bufnr) or require("neostar").session(bufnr) ~= state.session then
      return nil, "the source buffer was closed or detached"
    end
    local t, err = require("neostar.fstar.decl").find_target(bufnr, state.target.name)
    if not t then
      return nil, err
    end
    local same_val = (t.val and t.val.text) == (state.target.val and state.target.val.text)
    if t.statement ~= state.target.statement or not same_val then
      return nil, ("the statement of `%s` changed during the request"):format(state.target.name)
    end
    if t.body ~= state.target.body then
      return nil, ("the body of `%s` changed during the request"):format(state.target.name)
    end
    return t
  end
  local target, err = current_target()
  if not target then
    finish("refused", "neostar: proof not offered: " .. err)
    return
  end
  local proposal = require("neostar.ui.proposal")
  local reviewed = proposal.region_texts(bufnr, target, p.helpers, p.body)
  local view
  view = proposal.show({
    bufnr = bufnr,
    target = target,
    helpers = p.helpers,
    body = p.body,
    on_reject = function()
      if not run.ended then
        finish("rejected", nil)
      end
    end,
    on_accept = function()
      if run.ended then
        return
      end
      local t, err = current_target()
      if not t then
        finish("refused", "neostar: proof not applied: " .. err)
        return
      end
      if proposal.region_texts(bufnr, t, p.helpers, p.body) ~= reviewed then
        finish("refused", "neostar: proof not applied: the reviewed code changed")
        return
      end
      local ins = require("neostar.fstar.scratch").insert_row(t)
      local now = vim.api.nvim_buf_get_lines(bufnr, 0, ins, false)
      local before = vim.list_slice(state.lines, 1, require("neostar.fstar.scratch").insert_row(state.target))
      local function apply()
        proposal.apply(bufnr, t, p.helpers, p.body)
        finish("applied", ("neostar: proof of `%s` applied (one undo reverts it)"):format(t.name))
      end
      if vim.deep_equal(now, before) then
        apply()
        return
      end
      -- The text above the target changed: re-check against the current text.
      notify("neostar: the buffer changed; re-checking the proof before applying it")
      run.phase = "rechecking"
      local sc = state.scratch
      sc.lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      sc.target = t
      local tick = vim.api.nvim_buf_get_changedtick(bufnr)
      sc:check(p.helpers, p.body, function(result)
        if run.ended then
          return
        end
        if not vim.api.nvim_buf_is_loaded(bufnr)
          or require("neostar").session(bufnr) ~= state.session
          or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick
        then
          finish("refused", "neostar: proof not applied: the buffer changed during re-check; request a new proof")
          return
        end
        if result.ok then
          apply()
        else
          finish("refused", "neostar: proof not applied; it no longer verifies:\n" .. result.text)
        end
      end)
    end,
  })
  state.view = view
end

--- Prove the `let` at the cursor (or at `row`, 0-based).
---@param bufnr integer
---@param opts? {row?: integer, on_done?: fun(res: table)} on_done for tests
---@return table? state
function M.prove(bufnr, opts)
  opts = opts or {}
  local neostar = require("neostar")
  local s = neostar.session(bufnr)
  if not s then
    notify("neostar: not an F* buffer", vim.log.levels.WARN)
    return nil
  end
  local row = opts.row or (vim.api.nvim_win_get_cursor(0)[1] - 1)
  local decl = require("neostar.fstar.decl")
  local target, err = decl.target_at(bufnr, row)
  if not target then
    notify("neostar: " .. err, vim.log.levels.WARN)
    return nil
  end
  local cfg = neostar.options.agent
  local agent = require("neostar.agent")
  local mcp = require("neostar.agent.mcp")
  local tools = require("neostar.agent.tools")
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local sc = require("neostar.fstar.scratch").new({ session = s, target = target, lines = lines })
  local window
  local state = {
    session = s,
    revision = vim.api.nvim_buf_get_changedtick(bufnr),
    target = target,
    scratch = sc,
    lines = lines,
    max_checks = cfg.max_checks,
    checks = 0,
  }
  local run = { kind = "prove", phase = "running", scratch = sc, state = state }
  local function done(res)
    if state.result then
      return
    end
    state.result = res
    agent.finish(bufnr, run)
    if state.view then
      state.view.close()
    end
    if opts.on_done then
      opts.on_done(res)
    end
  end
  window = require("neostar.ui.agent_window").open({
    title = "Prove " .. target.name,
    source = bufnr,
    on_close = function()
      local run = agent.current(bufnr)
      if run and run.state == state and run.phase == "running" then
        agent.stop(bufnr, "closed")
      end
    end,
  })
  state.window = window
  window:set_status(("attempt 0/%d"):format(cfg.max_checks))
  state.on_progress = function(st, result)
    window:set_status(("attempt %d/%d"):format(st.checks, st.max_checks))
    if result then
      window:append(("\n\n> check %d: %s\n\n"):format(st.checks, summary_line(result)))
    end
  end
  local all = tools.read_only()
  for k, v in pairs(tools.proof_tools(state)) do
    all[k] = v
  end
  local token, server = mcp.register({
    bufnr = bufnr,
    position = { target.decl.srow, 0 },
    target = target.name,
    request_revision = state.revision,
    tools = all,
  })
  run.token = token
  run.on_stop = function(reason)
    window:append(("\n\n_(%s)_\n"):format(reason))
    window:set_status("stopped")
    done({ outcome = "stopped", message = reason })
  end
  agent.begin(bufnr, run)
  run.timer = assert((vim.uv or vim.loop).new_timer())
  run.timer:start(
    cfg.timeout_ms,
    0,
    vim.schedule_wrap(function()
      if agent.current(bufnr) == run then
        agent.stop(bufnr, ("time limit of %d s reached"):format(math.floor(cfg.timeout_ms / 1000)))
      end
    end)
  )
  local handle, start_err = require("neostar.agent.runner").start({
    bufnr = bufnr,
    cwd = agent.project_root(s),
    prompt = M.build_prompt(s, target, cfg.max_checks),
    system_prompt = M.system_prompt,
    mcp_server = server,
    on_text = function(t)
      if not run.ended then
        window:append(t)
      end
    end,
    on_tool = function(name)
      if not run.ended then
        window:set_status(("attempt %d/%d · %s"):format(state.checks, state.max_checks, name))
      end
    end,
    on_done = function(res)
      if run.ended then
        return
      end
      if res.stopped then
        agent.stop(bufnr, "stopped")
        return
      end
      run.handle = nil
      mcp.revoke(run.token)
      run.token = nil
      if state.proposal then
        run.phase = "reviewing"
        window:append("\n\n**Verified proof found.** Review the diff.\n")
        window:set_status("proof found")
        window:close()
        review(bufnr, state, run, done)
      else
        local why = res.ok and "no proof found" or ("agent error: " .. tostring(res.error))
        window:append(("\n\n**%s.**%s\n"):format(
          why:sub(1, 1):upper() .. why:sub(2),
          state.last_error and ("\n\nLast F* result:\n\n```\n" .. state.last_error .. "\n```") or ""
        ))
        window:set_status(state.checks >= state.max_checks and "limit reached" or "no proof")
        done({ outcome = "no_proof", message = why, last_error = state.last_error })
      end
    end,
  })
  if not handle then
    window:append("**Error:** " .. start_err .. "\n")
    window:set_status("failed")
    notify(start_err, vim.log.levels.ERROR)
    vim.schedule(function()
      done({ outcome = "error", message = start_err })
    end)
    return state
  end
  if not run.ended and run.phase == "running" then
    window:append("> Agent: " .. require("neostar.agent.runner").label(handle) .. "\n\n")
    run.handle = handle
  end
  return state
end

return M
