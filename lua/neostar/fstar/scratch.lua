--- Scratch checker: a separate F* process that checks proof candidates for one
--- target declaration. The text before the target is checked with SMT queries
--- admitted; helpers and the target are fully verified; nothing after the target
--- is sent. The buffer's own checker is never touched.

local transport_mod = require("neostar.fstar.transport")

local M = {}

M.PUSH = '#push-options "--admit_smt_queries true"'
M.POP = "#pop-options"
local PING = "describe-protocol"

--- Test hook: transport factory used instead of the session's.
M._factory_override = nil

---@class neostar.ScratchLayout
---@field helpers_line integer 1-based F* line of the first helper line
---@field helpers_lines integer number of helper lines (0 if none)
---@field region_line integer first line of the val/statement region
---@field body_line integer line where the body starts
---@field body_col integer character column where the body starts (0-based)
---@field prefix_last integer last line belonging to the prefix (incl. pragmas)

local function split(s)
  if s == nil or s == "" then
    return {}
  end
  return vim.split(s, "\n", { plain = true })
end

--- Row where helpers are inserted: above a matching val, else above the let.
---@param target neostar.ProveTarget
function M.insert_row(target)
  return target.val and target.val.srow or target.decl.srow
end

--- Build the scratch text for a candidate.
---@param lines string[] buffer lines (snapshot)
---@param target neostar.ProveTarget
---@param helpers string
---@param body string
---@return string text, neostar.ScratchLayout layout
function M.assemble(lines, target, helpers, body)
  local out = {}
  local function add(l)
    table.insert(out, l)
  end
  local mrow = target.module_row
  for r = 0, mrow do
    add(lines[r + 1])
  end
  add(M.PUSH)
  local ins = M.insert_row(target)
  for r = mrow + 1, ins - 1 do
    add(lines[r + 1])
  end
  add(M.POP)
  local prefix_last = #out
  local hl = split(helpers)
  if #hl > 0 and hl[#hl] ~= "" then
    table.insert(hl, "")
  end
  local helpers_line = #out + 1
  for _, l in ipairs(hl) do
    add(l)
  end
  local region_line = #out + 1
  for r = ins, target.decl.srow - 1 do
    add(lines[r + 1])
  end
  local st = split(target.statement)
  local bl = split(body)
  local body_line = #out + #st
  local last_st = st[#st] or ""
  local body_col = vim.str_utfindex(last_st, "utf-32")
  -- statement lines, with the body's first line joined to the last one
  for i = 1, #st - 1 do
    add(st[i])
  end
  add(last_st .. (bl[1] or ""))
  for i = 2, #bl do
    add(bl[i])
  end
  return table.concat(out, "\n") .. "\n",
    {
      helpers_line = helpers_line,
      helpers_lines = #hl,
      region_line = region_line,
      body_line = body_line,
      body_col = body_col,
      prefix_last = prefix_last,
    }
end

---@class neostar.CandidateError
---@field where "helpers"|"body"|"statement"|"prefix"|"other"
---@field line? integer 1-based, relative to `where` (helpers/body)
---@field col? integer 1-based characters
---@field level string
---@field message string

--- Map an F* range position to a location relative to the submitted text.
---@param layout neostar.ScratchLayout
---@param pos integer[] {line (1-based), col (0-based chars)}
function M.locate(layout, pos)
  local line, col = pos[1], pos[2]
  if line >= layout.body_line then
    local rel = line - layout.body_line + 1
    local c = rel == 1 and (col - layout.body_col) or col
    if c < 0 then
      return "statement", nil, nil
    end
    return "body", rel, c + 1
  end
  if line >= layout.region_line then
    return "statement", nil, nil
  end
  if layout.helpers_lines > 0 and line >= layout.helpers_line then
    return "helpers", line - layout.helpers_line + 1, col + 1
  end
  return "prefix", nil, nil
end

--- Human/agent-readable text for a check result.
function M.format_result(result)
  if result.ok then
    return "OK: the helpers and the target verify (full SMT verification)."
  end
  local out = { "FAILED:" }
  for _, e in ipairs(result.errors) do
    local loc
    if e.where == "body" or e.where == "helpers" then
      loc = ("%s line %d, column %d"):format(e.where, e.line, e.col)
    elseif e.where == "statement" then
      loc = "the target's statement (which you cannot change)"
    elseif e.where == "prefix" then
      loc = "code above the target in the file (not part of your candidate)"
    else
      loc = "unknown location"
    end
    table.insert(out, ("- %s in %s:\n%s"):format(e.level, loc, vim.trim(e.message)))
  end
  if #result.errors == 0 then
    table.insert(out, "- F* reported a failure without details")
  end
  return table.concat(out, "\n")
end

--- Immediate failure result (with text).
local function failed(message)
  local r = { ok = false, errors = { { where = "other", level = "error", message = message } } }
  r.text = M.format_result(r)
  return r
end

---@class neostar.Scratch
local Scratch = {}
Scratch.__index = Scratch

---@param opts {session: neostar.Session, target: neostar.ProveTarget, lines: string[], ping_interval_ms?: integer, transport_factory?: fun(o: table): table}
---@return neostar.Scratch
function M.new(opts)
  local s = opts.session
  return setmetatable({
    session = s,
    target = opts.target,
    lines = opts.lines,
    factory = opts.transport_factory or M._factory_override or s.transport_factory,
    ping_interval_ms = opts.ping_interval_ms or s.ping_interval_ms or 200,
    transport = nil,
    run = nil,
    closed = false,
  }, Scratch)
end

---@return boolean ok, string? err
function Scratch:start()
  self.transport = self.factory({
    cmd = self.session.cmd,
    cwd = self.session.cwd,
    on_unrouted = function() end,
    on_exit = function(code, stderr)
      self:_on_exit(code, stderr)
    end,
  })
  local ok, err = self.transport:start()
  if not ok then
    self.transport = nil
    return false, err
  end
  return true
end

function Scratch:_on_exit(code, stderr)
  self.transport = nil
  local run = self.run
  if run and not self.closed then
    self:_finish({
      ok = false,
      errors = {
        {
          where = "other",
          level = "error",
          message = ("the scratch F* process exited (code %s)%s"):format(
            tostring(code),
            stderr and stderr:match("%S") and (": " .. stderr) or ""
          ),
        },
      },
    })
  end
end

function Scratch:_stop_ping()
  if self.ping_timer and not self.ping_timer:is_closing() then
    self.ping_timer:stop()
    self.ping_timer:close()
  end
  self.ping_timer = nil
end

function Scratch:_finish(result)
  local run = self.run
  if not run then
    return
  end
  self.run = nil
  self:_stop_ping()
  if self.transport and run.qid then
    self.transport:forget(run.qid)
  end
  result.text = M.format_result(result)
  run.cb(result)
end

--- Check a candidate. cb receives {ok, errors, text}. One check at a time.
---@param helpers string
---@param body string
---@param cb fun(result: table)
function Scratch:check(helpers, body, cb)
  if self.closed then
    cb(failed("the proof request has ended"))
    return
  end
  if self.run then
    cb(failed("a check is already running"))
    return
  end
  if not self.transport then
    local ok, err = self:start()
    if not ok then
      cb(failed("could not start F*: " .. tostring(err)))
      return
    end
  end
  local text, layout = M.assemble(self.lines, self.target, helpers, body)
  local run = { cb = cb, layout = layout, errors = {}, failed = false, seen = {} }
  self.run = run
  local own = vim.fn.fnamemodify(self.session.file, ":t")
  local function add_issue(issue)
    local r = (issue.ranges or {})[1]
    local where, line, col = "other", nil, nil
    if r and r.beg and (r.fname == nil or vim.fn.fnamemodify(r.fname, ":t") == own) then
      where, line, col = M.locate(layout, r.beg)
    end
    local key = (issue.message or "") .. "|" .. vim.inspect(r and r.beg)
    if run.seen[key] then
      return
    end
    run.seen[key] = true
    if issue.level == "error" then
      run.failed = true
    end
    if issue.level == "error" or issue.level == "warning" then
      table.insert(run.errors, { where = where, line = line, col = col, level = issue.level, message = issue.message or "" })
    end
  end
  local qid, err = self.transport:request("full-buffer", {
    kind = "full",
    code = text,
    line = 0,
    column = 0,
    ["with-symbols"] = false,
  }, {
    persistent = true,
    on_message = function(msg)
      if self.run ~= run then
        return
      end
      if msg.kind == "message" and msg.level == "progress" and type(msg.contents) == "table" then
        local stage = msg.contents.stage
        if stage == "full-buffer-fragment-failed" then
          run.failed = true
        elseif stage == "full-buffer-finished" then
          self:_finish({ ok = not run.failed, errors = run.errors })
        end
      elseif msg.kind == "response" then
        local r = msg.response
        if type(r) == "table" and vim.islist(r) then
          for _, issue in ipairs(r) do
            if type(issue) == "table" then
              add_issue(issue)
            end
          end
        elseif msg.status ~= "success" and type(r) == "string" then
          add_issue({ level = "error", message = r })
          if msg["query-id"] == run.qid then
            self:_finish({ ok = false, errors = run.errors })
          end
        end
      end
    end,
  })
  if not qid then
    self.run = nil
    cb(failed("could not send to F*: " .. tostring(err)))
    return
  end
  run.qid = qid
  self:_start_ping(run)
end

function Scratch:_start_ping(run)
  self:_stop_ping()
  local t = assert((vim.uv or vim.loop).new_timer())
  self.ping_timer = t
  local out, age = 0, 0
  t:start(
    self.ping_interval_ms,
    self.ping_interval_ms,
    vim.schedule_wrap(function()
      if self.run ~= run or not self.transport then
        return
      end
      if out >= 1 then
        age = age + 1
        if age < 6 then
          return
        end
      end
      age = 0
      out = out + 1
      self.transport:request(PING, {}, {
        on_response = function()
          out = math.max(out - 1, 0)
        end,
      })
    end)
  )
end

--- Stop the process. A running check is answered with an "ended" error.
function Scratch:close()
  if self.closed then
    return
  end
  local run = self.run
  if run then
    self:_finish({ ok = false, errors = { { where = "other", level = "error", message = "the proof request has ended" } } })
  end
  self.closed = true
  self:_stop_ping()
  if self.transport then
    local t = self.transport
    self.transport = nil
    t:stop()
  end
end

function Scratch:is_running()
  return self.transport ~= nil and self.transport:is_running()
end

M.Scratch = Scratch
M._transport = transport_mod
return M
