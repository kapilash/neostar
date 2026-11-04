--- F* tools exposed to agents over MCP. Read-only tools work on the buffer's
--- own checker session; proof tools (added by prove.lua) use a scratch checker.

local M = {}

local BUSY = "checker busy: F* is running a full verification; try again after it finishes"

local function session_of(ctx)
  local s = require("neostar").session(ctx.bufnr)
  if not s or not s.alive then
    return nil
  end
  return s
end

--- Plain-text description of a lookup response.
function M.format_lookup(resp)
  local lines = { (resp.name or "?") .. (resp.type and resp.type ~= "" and (" : " .. resp.type) or "") }
  local d = resp["defined-at"]
  if type(d) == "table" and d.fname then
    table.insert(lines, ("defined at %s:%d"):format(d.fname, (d.beg or {})[1] or 0))
  end
  if type(resp.documentation) == "string" and resp.documentation:match("%S") then
    table.insert(lines, "")
    table.insert(lines, vim.trim(resp.documentation))
  end
  return table.concat(lines, "\n")
end

--- Location used for lookups: ctx.position (0-based row, byte col) or the buffer end.
local function lookup_location(s, ctx)
  local row, col = 0, 0
  if ctx.position then
    row, col = ctx.position[1], ctx.position[2]
  else
    row = math.max(vim.api.nvim_buf_line_count(s.bufnr) - 1, 0)
  end
  local text = vim.api.nvim_buf_get_lines(s.bufnr, row, row + 1, false)[1] or ""
  local line, column = require("neostar.fstar.transport").to_fstar_pos(row, math.min(col, #text), text)
  return { filename = s.file, line = line, column = column }
end

M.lookup = {
  description = "Look up an F* symbol (for example FStar.List.Tot.length or a name defined in this file) "
    .. "and return its fully qualified name, type, definition location and documentation. "
    .. "Uses the editor's running F* checker, including unsaved changes.",
  inputSchema = {
    type = "object",
    properties = { symbol = { type = "string", description = "Symbol name, possibly module-qualified" } },
    required = { "symbol" },
  },
  handler = function(args, ctx, respond)
    local s = session_of(ctx)
    if not s then
      respond("F* checker is not running for this buffer", true)
      return
    end
    local sym = vim.trim(tostring(args.symbol or ""))
    if sym == "" then
      respond("symbol is required", true)
      return
    end
    s:query("lookup", {
      context = "code",
      symbol = sym,
      ["requested-info"] = { "type", "documentation", "defined-at" },
      location = lookup_location(s, ctx),
    }, function(status, resp)
      if status == "busy" then
        respond(BUSY, true)
      elseif status == "success" and type(resp) == "table" then
        respond(M.format_lookup(resp))
      elseif status == "unavailable" then
        respond(tostring(resp), true)
      else
        respond("not found: " .. sym)
      end
    end)
  end,
}

M.compute = {
  description = "Evaluate (normalise) an F* term in the context of the checked part of the current file "
    .. "and return the result, or F*'s error.",
  inputSchema = {
    type = "object",
    properties = { term = { type = "string", description = "F* term to evaluate" } },
    required = { "term" },
  },
  handler = function(args, ctx, respond)
    local s = session_of(ctx)
    if not s then
      respond("F* checker is not running for this buffer", true)
      return
    end
    local term = vim.trim(tostring(args.term or ""))
    if term == "" then
      respond("term is required", true)
      return
    end
    s:query("compute", { term = term }, function(status, resp)
      if status == "busy" then
        respond(BUSY, true)
      elseif status == "success" then
        respond(type(resp) == "string" and resp or vim.json.encode(resp))
      else
        respond(type(resp) == "string" and resp or vim.inspect(resp), true)
      end
    end)
  end,
}

--- Plain-text report of declaration statuses and diagnostics (1-based lines).
function M.format_diagnostics(s)
  local out = { require("neostar.agent.context").header(s), "", "Declarations (lines are 1-based):" }
  for _, item in ipairs(s:sorted_fragments()) do
    local first = vim.api.nvim_buf_get_lines(s.bufnr, item.srow, item.srow + 1, false)[1] or ""
    table.insert(
      out,
      ("  lines %d-%d  %-9s  %s"):format(item.srow + 1, item.erow + 1, item.fragment.status, vim.trim(first):sub(1, 80))
    )
  end
  if #out == 3 then
    table.insert(out, "  (none checked yet)")
  end
  local diags = s:diagnostics()
  table.insert(out, "")
  if #diags == 0 then
    table.insert(out, "Diagnostics: none")
  else
    table.insert(out, "Diagnostics:")
    local names = { [1] = "error", [2] = "warning", [3] = "info", [4] = "hint" }
    for _, d in ipairs(diags) do
      table.insert(
        out,
        ("- %s %s at %d:%d-%d:%d\n%s"):format(
          names[d.severity] or "info",
          d.code and ("#" .. d.code) or "",
          d.lnum + 1,
          d.col + 1,
          (d.end_lnum or d.lnum) + 1,
          (d.end_col or d.col) + 1,
          d.message
        )
      )
    end
  end
  if s.running then
    table.insert(out, "")
    table.insert(out, "(a " .. s.running .. " check is running; this report may change)")
  end
  return table.concat(out, "\n")
end

M.diagnostics = {
  description = "Report the current file's F* errors and warnings (with 1-based line:column ranges) and the "
    .. "verification status of each declaration: verified, lax (type-checked without SMT), failed, inflight, "
    .. "or unreached.",
  inputSchema = { type = "object", properties = vim.empty_dict() },
  handler = function(_, ctx, respond)
    local s = require("neostar").session(ctx.bufnr)
    if not s then
      respond("no F* session for this buffer", true)
      return
    end
    respond(M.format_diagnostics(s))
  end,
}

M.context = {
  description = "Read the authoritative current editor buffer, including unsaved source, its revision, "
    .. "selection or proof target, diagnostics and checker freshness. Disk files may differ. "
    .. "For proof requests, request_revision identifies the frozen source used by check_proof.",
  inputSchema = { type = "object", properties = vim.empty_dict() },
  handler = function(_, ctx, respond)
    local s = require("neostar").session(ctx.bufnr)
    if not s or not vim.api.nvim_buf_is_loaded(ctx.bufnr) then
      respond("the source buffer is no longer attached", true)
      return
    end
    respond(vim.json.encode(require("neostar.agent.context").snapshot(s, ctx)))
  end,
}

--- The read-only tool set, keyed by MCP tool name.
function M.read_only()
  return {
    neostar_context = M.context,
    fstar_lookup = M.lookup,
    fstar_compute = M.compute,
    fstar_diagnostics = M.diagnostics,
  }
end

---@class neostar.ProofState
---@field target neostar.ProveTarget
---@field scratch neostar.Scratch
---@field max_checks integer
---@field checks integer
---@field last_pass? {helpers: string, body: string}
---@field last_error? string
---@field proposal? {helpers: string, body: string}
---@field on_progress? fun(state: neostar.ProofState, result?: table)

local candidate_schema = {
  type = "object",
  properties = {
    helpers = {
      type = "string",
      description = "New top-level helper declarations (lemmas) placed directly above the target. Empty string if none.",
    },
    body = {
      type = "string",
      description = "The proof: the expression that follows `=` in the target's definition.",
    },
  },
  required = { "body" },
}

local function norm(s)
  return type(s) == "string" and s or ""
end

--- check_proof and propose_proof for one proof request.
---@param state neostar.ProofState
function M.proof_tools(state)
  local guard = require("neostar.fstar.guard")
  local check_proof = {
    description = "Check a candidate proof of the target with F* (full SMT verification). You supply only the "
      .. "helper declarations and the body; the target's statement is fixed and taken from the file. "
      .. "admit, assume, magic, expect_failure and options that turn off checking are rejected. "
      .. "Returns OK or F*'s errors with positions relative to your helpers/body. "
      .. ("At most %d checks are allowed."):format(state.max_checks),
    inputSchema = candidate_schema,
    handler = function(args, _, respond)
      local helpers, body = norm(args.helpers), norm(args.body)
      local reason = guard.check_candidate(state.target.statement, helpers, body)
      if reason then
        state.last_error = "rejected: " .. reason
        if state.on_progress then
          state.on_progress(state)
        end
        respond("REJECTED (not checked): " .. reason, true)
        return
      end
      if state.checks >= state.max_checks then
        respond(("limit reached: %d checks have been used; stop and report that no proof was found"):format(state.max_checks), true)
        return
      end
      state.checks = state.checks + 1
      if state.on_progress then
        state.on_progress(state)
      end
      state.scratch:check(helpers, body, function(result)
        if result.ok then
          state.last_pass = { helpers = helpers, body = body }
          state.last_error = nil
        else
          state.last_pass = nil
          state.last_error = result.text
        end
        if state.on_progress then
          state.on_progress(state, result)
        end
        respond(result.text, not result.ok)
      end)
    end,
  }
  local propose_proof = {
    description = "Submit your final proof. It must be exactly the helpers and body of your most recent "
      .. "check_proof call, and that check must have returned OK. The user will review it as a diff.",
    inputSchema = candidate_schema,
    handler = function(args, _, respond)
      local helpers, body = norm(args.helpers), norm(args.body)
      local p = state.last_pass
      if not p or p.helpers ~= helpers or p.body ~= body then
        respond("not accepted: this exact helpers/body pair has not passed check_proof (call check_proof with it first)", true)
        return
      end
      state.proposal = { helpers = helpers, body = body }
      if state.on_progress then
        state.on_progress(state)
      end
      respond("accepted: the proof will be shown to the user for review. You are done.")
    end,
  }
  return { check_proof = check_proof, propose_proof = propose_proof }
end

return M
