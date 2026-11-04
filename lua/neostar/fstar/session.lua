--- Per-buffer F* checking session.
---
--- Owns the transport, the check state machine (idle / lax / full), the
--- per-declaration fragment model (tracked with extmarks so it follows edits),
--- and the issues reported by F*. UI and LSP code subscribe to events; the
--- session knows nothing about LSP.

local transport_mod = require("neostar.fstar.transport")

local M = {}

M.ns = vim.api.nvim_create_namespace("neostar.fragments")

---@alias neostar.FragmentStatus "verified"|"lax"|"failed"|"inflight"|"unreached"
---@alias neostar.CheckKind "lax"|"full"|"verify-to-position"

---@class neostar.Fragment
---@field id integer          extmark id in M.ns
---@field status neostar.FragmentStatus
---@field issues table[]      raw F* issues attributed to this declaration
---@field seen boolean        reported during the current run

---@class neostar.Session
local Session = {}
Session.__index = Session

---@type table<integer, neostar.Session>
M.sessions = {}

local PING = "describe-protocol"

local function new_timer()
  return assert(vim.uv.new_timer())
end

local function stop_timer(t)
  if t and not t:is_closing() then
    t:stop()
  end
end

local function close_timer(t)
  if t and not t:is_closing() then
    t:stop()
    t:close()
  end
end

---@class neostar.SessionOpts
---@field cmd string[]
---@field cwd string
---@field root string
---@field file string
---@field debounce_ms? integer
---@field lax_request_timeout_ms? integer
---@field cancel_timeout_ms? integer
---@field ping_interval_ms? integer
---@field transport_factory? fun(opts: table): table
---@field confirm_kill? fun(on_yes: fun())
---@field notify? fun(msg: string, level: integer)

---@param bufnr integer
---@param opts neostar.SessionOpts
---@return neostar.Session
function M.new(bufnr, opts)
  local self = setmetatable({
    bufnr = bufnr,
    file = opts.file,
    root = opts.root,
    cmd = opts.cmd,
    cwd = opts.cwd,
    opts = opts,
    debounce_ms = opts.debounce_ms or 500,
    lax_request_timeout_ms = opts.lax_request_timeout_ms or 2000,
    cancel_timeout_ms = opts.cancel_timeout_ms or 5000,
    ping_interval_ms = opts.ping_interval_ms or 500,
    transport_factory = opts.transport_factory or transport_mod.new,
    notify = opts.notify or function(msg, level)
      vim.notify(msg, level, { title = "neostar" })
    end,
    confirm_kill = opts.confirm_kill,
    ---@type neostar.Fragment[]
    fragments = {},
    global_issues = {},
    running = nil, ---@type neostar.CheckKind?
    run_qid = nil,
    current_fragment = nil, ---@type neostar.Fragment?
    cancelling = false,
    pending = nil, ---@type {kind: neostar.CheckKind, pos?: integer[]}?
    sent_tick = nil,
    waiters = {},
    listeners = {},
    alive = false,
    stopped = false,
    debounce_timer = new_timer(),
    ping_timer = new_timer(),
    cancel_timer = new_timer(),
  }, Session)
  return self
end

-- events ---------------------------------------------------------------------

--- Subscribe to session events: "fragments", "diagnostics", "state".
---@param fn fun(event: string, session: neostar.Session)
function Session:subscribe(fn)
  table.insert(self.listeners, fn)
end

function Session:emit(event)
  for _, fn in ipairs(self.listeners) do
    local ok, err = pcall(fn, event, self)
    if not ok then
      vim.schedule(function()
        vim.notify("neostar: listener error: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
end

-- process lifecycle ----------------------------------------------------------

---@return boolean ok
function Session:start()
  self.stopped = false
  self.transport = self.transport_factory({
    cmd = self.cmd,
    cwd = self.cwd,
    on_unrouted = function(msg)
      self:_on_unrouted(msg)
    end,
    on_exit = function(code, stderr)
      self:_on_exit(code, stderr)
    end,
  })
  local ok, err = self.transport:start()
  if not ok then
    self.alive = false
    self.notify(("F* failed to start (%s): %s"):format(self.cmd[1], err or "unknown error"), vim.log.levels.ERROR)
    self:emit("state")
    return false
  end
  self.alive = true
  self:emit("state")
  return true
end

function Session:_on_exit(code, stderr)
  self.alive = false
  local was = self.running
  self:_reset_run()
  self:_fail_waiters()
  local msg = ("F* exited unexpectedly (code %s) for %s"):format(tostring(code), vim.fn.fnamemodify(self.file, ":t"))
  if stderr and stderr:match("%S") then
    msg = msg .. "\n" .. stderr
  end
  msg = msg .. "\nRun :NeostarRestart to start a new checker."
  if not self.stopped then
    self.notify(msg, vim.log.levels.ERROR)
  end
  if was then
    self:_mark_unseen_unreached()
  end
  self:emit("state")
  self:emit("fragments")
end

--- Stop the process and timers; the session can be restarted.
function Session:stop()
  self.stopped = true
  if self.transport then
    self.transport:stop()
  end
  self.alive = false
  self:_reset_run()
  self:_fail_waiters()
  stop_timer(self.debounce_timer)
  self.pending = nil
end

--- Stop and free all resources; the session cannot be used afterwards.
function Session:destroy()
  self:stop()
  close_timer(self.debounce_timer)
  close_timer(self.ping_timer)
  close_timer(self.cancel_timer)
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    vim.api.nvim_buf_clear_namespace(self.bufnr, M.ns, 0, -1)
  end
  self.fragments = {}
  self.listeners = {}
end

--- Kill the process, start a fresh one, and lax-check the buffer.
function Session:restart()
  self:stop()
  for _, f in ipairs(self.fragments) do
    f.status = "unreached"
    f.issues = {}
  end
  self.global_issues = {}
  self.sent_tick = nil
  self:emit("fragments")
  self:emit("diagnostics")
  if self:start() then
    self:check("lax")
  end
end

-- buffer helpers -------------------------------------------------------------

function Session:_text()
  local lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
  return table.concat(lines, "\n") .. "\n"
end

function Session:_tick()
  return vim.api.nvim_buf_get_changedtick(self.bufnr)
end

--- Clamp an F* [line,col] into the buffer; returns 0-based row, col.
function Session:_buf_pos(pos)
  local row = transport_mod.to_buf_pos(pos)
  local nlines = vim.api.nvim_buf_line_count(self.bufnr)
  if row >= nlines then
    row = nlines - 1
    return row, #(vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)[1] or "")
  end
  local line = vim.api.nvim_buf_get_lines(self.bufnr, row, row + 1, false)[1] or ""
  local _, col = transport_mod.to_buf_pos(pos, line)
  return row, col
end

--- Does an F* file name denote this buffer's file?
function Session:is_own_file(fname)
  if type(fname) ~= "string" or fname == "" then
    return false
  end
  if fname == self.file then
    return true
  end
  local abs = fname
  if fname:sub(1, 1) ~= "/" then
    abs = vim.fs.joinpath(self.cwd or vim.fs.dirname(self.file), fname)
  end
  if vim.fs.normalize(abs) == vim.fs.normalize(self.file) then
    return true
  end
  -- F* reports the file it was started on by its base name.
  return not fname:find("/", 1, true) and fname == vim.fs.basename(self.file)
end

-- fragments ------------------------------------------------------------------

---@param f neostar.Fragment
---@return integer srow, integer scol, integer erow, integer ecol
function Session:fragment_range(f)
  local m = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, M.ns, f.id, { details = true })
  if not m or not m[1] then
    return -1, -1, -1, -1
  end
  local d = m[3] or {}
  return m[1], m[2], d.end_row or m[1], d.end_col or m[2]
end

--- Fragments sorted by start row.
---@return {fragment: neostar.Fragment, srow: integer, erow: integer}[]
function Session:sorted_fragments()
  local out = {}
  for _, f in ipairs(self.fragments) do
    local s, _, e = self:fragment_range(f)
    if s >= 0 then
      table.insert(out, { fragment = f, srow = s, erow = e })
    end
  end
  table.sort(out, function(a, b)
    return a.srow < b.srow
  end)
  return out
end

--- Find or create the fragment for an F* range; drops overlapping fragments.
---@param range {beg: integer[], ["end"]: integer[]}
---@return neostar.Fragment?
function Session:_upsert_fragment(range)
  if not range or not range.beg then
    return nil
  end
  local srow, scol = self:_buf_pos(range.beg)
  local erow, ecol = self:_buf_pos(range["end"] or range.beg)
  local keep, found = {}, nil
  for _, f in ipairs(self.fragments) do
    local s, sc, e = self:fragment_range(f)
    if s == srow and sc == scol and not found then
      found = f
      table.insert(keep, f)
    elseif s >= 0 and s <= erow and e >= srow then
      pcall(vim.api.nvim_buf_del_extmark, self.bufnr, M.ns, f.id)
    elseif s >= 0 then
      table.insert(keep, f)
    end
  end
  self.fragments = keep
  local mark_opts = {
    end_row = erow,
    end_col = ecol,
    right_gravity = false,
    end_right_gravity = true,
  }
  if found then
    mark_opts.id = found.id
    vim.api.nvim_buf_set_extmark(self.bufnr, M.ns, srow, scol, mark_opts)
    return found
  end
  local id = vim.api.nvim_buf_set_extmark(self.bufnr, M.ns, srow, scol, mark_opts)
  local f = { id = id, status = "unreached", issues = {}, seen = false }
  table.insert(self.fragments, f)
  return f
end

function Session:_mark_unseen_unreached()
  for _, f in ipairs(self.fragments) do
    if not f.seen or f.status == "inflight" then
      f.status = "unreached"
      f.issues = {}
    end
  end
end

--- Invalidate the edited declaration and every declaration depending on it.
---@return boolean changed
function Session:invalidate_rows(first, _last)
  local changed = #self.global_issues > 0
  self.global_issues = {}
  for _, f in ipairs(self.fragments) do
    local s, _, e = self:fragment_range(f)
    if s >= 0 and e >= first then
      changed = changed or f.status ~= "unreached" or #f.issues > 0
      f.status = "unreached"
      f.issues = {}
    end
  end
  return changed
end

-- summary --------------------------------------------------------------------

---@class neostar.Summary
---@field verified integer
---@field lax integer
---@field failed integer
---@field unchecked integer
---@field running neostar.CheckKind?
---@field alive boolean

---@return neostar.Summary
function Session:summary()
  local s = { verified = 0, lax = 0, failed = 0, unchecked = 0, running = self.running, alive = self.alive }
  for _, f in ipairs(self.fragments) do
    if f.status == "verified" then
      s.verified = s.verified + 1
    elseif f.status == "lax" then
      s.lax = s.lax + 1
    elseif f.status == "failed" then
      s.failed = s.failed + 1
    else
      s.unchecked = s.unchecked + 1
    end
  end
  return s
end

--- "full" for full verification runs, "lax" otherwise, nil when idle.
function Session:running_class()
  if not self.running then
    return nil
  end
  if self.running == "full" or self.running == "verify-to-position" then
    return "full"
  end
  return "lax"
end

-- issues ---------------------------------------------------------------------

--- All issues as vim.Diagnostic-like tables (0-based rows, byte columns).
function Session:diagnostics()
  local out = {}
  local function add(issue)
    local ranges = issue.ranges or {}
    local primary = ranges[1]
    local level = issue.level
    local sev = vim.diagnostic.severity.INFO
    if level == "error" then
      sev = vim.diagnostic.severity.ERROR
    elseif level == "warning" then
      sev = vim.diagnostic.severity.WARN
    end
    local message = (issue.message or ""):gsub("%s+$", "")
    local d = { severity = sev, message = message, code = issue.number }
    if primary and self:is_own_file(primary.fname) then
      d.lnum, d.col = self:_buf_pos(primary.beg)
      d.end_lnum, d.end_col = self:_buf_pos(primary["end"] or primary.beg)
    else
      d.lnum, d.col, d.end_lnum, d.end_col = 0, 0, 0, 0
      if primary and primary.fname then
        d.message = ("%s(%d,%d): %s"):format(primary.fname, primary.beg[1], primary.beg[2], message)
      end
    end
    table.insert(out, d)
  end
  for _, f in ipairs(self.fragments) do
    for _, issue in ipairs(f.issues) do
      add(issue)
    end
  end
  for _, issue in ipairs(self.global_issues) do
    add(issue)
  end
  return out
end

-- running checks -------------------------------------------------------------

function Session:_reset_run()
  if self.run_qid and self.transport then
    self.transport:forget(self.run_qid)
  end
  self.running = nil
  self.run_qid = nil
  self.current_fragment = nil
  self.cancelling = false
  self.pings_out = 0
  stop_timer(self.ping_timer)
  stop_timer(self.cancel_timer)
end

local stage_status = {
  ["full-buffer-fragment-ok"] = "verified",
  ["full-buffer-fragment-lax-ok"] = "lax",
  ["full-buffer-fragment-failed"] = "failed",
}

---@param msg table
function Session:_on_run_message(msg)
  local contents = msg.contents
  if msg.kind == "message" and msg.level == "progress" and type(contents) == "table" then
    local stage = contents.stage
    if stage == "full-buffer-started" then
      return
    elseif stage == "full-buffer-fragment-started" then
      local f = self:_upsert_fragment(contents.ranges)
      if f then
        f.status = "inflight"
        f.seen = true
        f.issues = {}
        self.current_fragment = f
        self:emit("fragments")
      end
    elseif stage_status[stage] then
      local f = self:_upsert_fragment(contents.ranges)
      if f then
        f.status = stage_status[stage]
        f.seen = true
        self.current_fragment = f
        self:emit("fragments")
      end
    elseif stage == "full-buffer-finished" then
      self:_finish_run()
    end
    return
  end
  if msg.kind == "response" then
    local issues = msg.response
    if type(issues) == "table" and vim.islist(issues) and #issues > 0 and type(issues[1]) == "table" then
      for _, issue in ipairs(issues) do
        self:_attribute_issue(issue)
      end
      self:emit("diagnostics")
    elseif msg.status ~= "success" and type(issues) == "string" then
      table.insert(self.global_issues, { level = "error", message = issues, ranges = {} })
      self:emit("diagnostics")
      if msg["query-id"] == self.run_qid then
        -- F* rejected the whole query (protocol error): no progress will follow.
        self:_finish_run()
      end
    end
  end
end

local function same_issue(a, b)
  if a.message ~= b.message or a.number ~= b.number then
    return false
  end
  local ra, rb = (a.ranges or {})[1], (b.ranges or {})[1]
  if not ra or not rb then
    return ra == rb
  end
  return vim.deep_equal(ra.beg, rb.beg) and vim.deep_equal(ra["end"], rb["end"])
end

--- Attach an issue to the declaration containing its primary range (F*
--- repeats the issues of reused declarations in a top-level response), or to
--- the declaration being checked, or to the file as a whole.
function Session:_attribute_issue(issue)
  local primary = (issue.ranges or {})[1]
  local target
  if primary and primary.beg and self:is_own_file(primary.fname) then
    local row = self:_buf_pos(primary.beg)
    for _, f in ipairs(self.fragments) do
      local s, _, e = self:fragment_range(f)
      if s >= 0 and s <= row and row <= e then
        target = f
        break
      end
    end
  end
  target = target or self.current_fragment
  local list = target and target.issues or self.global_issues
  for _, existing in ipairs(list) do
    if same_issue(existing, issue) then
      return
    end
  end
  table.insert(list, issue)
end

function Session:_finish_run()
  local kind = self.running
  self:_mark_unseen_unreached()
  self:_reset_run()
  self:emit("fragments")
  self:emit("diagnostics")
  self:emit("state")
  -- verify-to-position drops everything after the position: lax-check the
  -- rest (the verified prefix is reused at its verified level).
  if kind == "verify-to-position" and not self.pending and not self.cancelled_by_user then
    self.pending = { kind = "lax" }
  end
  self.cancelled_by_user = false
  self:_run_pending()
  if self:running_class() == "full" then
    self:_fail_waiters()
  elseif not self.running and self.sent_tick == self:_tick() then
    self:_flush_waiters()
  end
end

function Session:_on_unrouted(msg)
  -- Messages of a cancelled/forgotten run may still arrive; nothing to do.
  local _ = msg
end

--- Keep one ping in flight while a check runs: F* only emits the tail of a
--- run (and completes a cancellation) after it reads more input.
function Session:_start_pinging()
  self.pings_out = 0
  self.ping_timer:start(
    self.ping_interval_ms,
    self.ping_interval_ms,
    vim.schedule_wrap(function()
      if not self.running or not self.transport or not self.transport:is_running() then
        return
      end
      if (self.pings_out or 0) >= 1 then
        self.ping_age = (self.ping_age or 0) + 1
        -- A ping can be swallowed by a cancel; resend if it is long overdue.
        if self.ping_age < 6 then
          return
        end
      end
      self.ping_age = 0
      self.pings_out = (self.pings_out or 0) + 1
      self.transport:request(PING, {}, {
        on_response = function()
          self.pings_out = math.max((self.pings_out or 1) - 1, 0)
        end,
      })
    end)
  )
end

--- Start a check now (cancelling nothing). Use `check` for policy-aware entry.
---@param kind neostar.CheckKind
---@param pos? integer[] {line, column} for verify-to-position
function Session:_run(kind, pos)
  if not self.alive then
    return false
  end
  for _, f in ipairs(self.fragments) do
    f.seen = false
  end
  self.global_issues = {}
  local args = {
    kind = kind,
    code = self:_text(),
    line = 0,
    column = 0,
    ["with-symbols"] = false,
  }
  if pos then
    args["to-position"] = { line = pos[1], column = pos[2] }
  end
  self.sent_tick = self:_tick()
  self.sent_seq = self.edit_seq or 0
  self.running = kind
  self.current_fragment = nil
  local qid, err = self.transport:request("full-buffer", args, {
    persistent = true,
    on_message = function(msg)
      self:_on_run_message(msg)
    end,
  })
  if not qid then
    self.running = nil
    self.notify("neostar: could not send check to F*: " .. tostring(err), vim.log.levels.ERROR)
    self:emit("state")
    return false
  end
  self.run_qid = qid
  self:_start_pinging()
  self:emit("state")
  return true
end

function Session:_run_pending()
  local p = self.pending
  if not p or self.running or not self.alive then
    return
  end
  self.pending = nil
  self:_run(p.kind, p.pos)
end

--- Request a check. If one is running it is cancelled first; the new check
--- starts when F* reports the old one finished.
---@param kind neostar.CheckKind
---@param pos? integer[]
function Session:check(kind, pos)
  stop_timer(self.debounce_timer)
  self.pending = { kind = kind, pos = pos }
  if self.running then
    self:_cancel_running()
  else
    self:_run_pending()
  end
end

--- Debounced lax check after an edit.
--- Count an edit (called synchronously from on_bytes); returns its number.
function Session:note_edit()
  self.edit_seq = (self.edit_seq or 0) + 1
  return self.edit_seq
end

---@param seq? integer number of the edit (from note_edit). on_edit runs
--- scheduled, so a check may have been sent after the edit but before this:
--- such a check already contains the edit and is not stale.
function Session:on_edit(seq)
  if seq and self.running and (self.sent_seq or 0) >= seq then
    return
  end
  stop_timer(self.debounce_timer)
  self.debounce_timer:start(
    self.debounce_ms,
    0,
    vim.schedule_wrap(function()
      if self.stopped then
        return
      end
      if self.sent_tick == self:_tick() and not self.running then
        return
      end
      self:check("lax")
    end)
  )
  -- An edit makes a running check's results stale: cancel it right away.
  if self.running and not self.cancelling then
    self:_cancel_running()
  end
end

--- Called on BufWritePost: only checks if the contents were never sent.
function Session:on_save()
  if self.debounce_timer:is_active() then
    stop_timer(self.debounce_timer)
    self:check("lax")
    return
  end
  if not self.running and self.sent_tick ~= self:_tick() then
    self:check("lax")
  end
end

--- Buffer reloaded from disk (e.g. an agent rewrote the file).
function Session:on_reload()
  for _, f in ipairs(self.fragments) do
    f.status = "unreached"
  end
  self:emit("fragments")
  self:check("lax")
end

function Session:_cancel_running()
  if not self.running or not self.transport then
    return
  end
  if self.cancelling then
    return
  end
  self.cancelling = true
  self.transport:request("cancel", { ["cancel-line"] = 1, ["cancel-column"] = 0 })
  -- The cancel empties F*'s queue, including any ping we had in flight.
  self.pings_out = 0
  self.ping_age = 0
  self.cancel_timer:start(
    self.cancel_timeout_ms,
    0,
    vim.schedule_wrap(function()
      if not self.running or not self.cancelling then
        return
      end
      local function kill()
        if self.running and self.cancelling then
          local pending = self.pending
          self:restart()
          if pending and pending.kind ~= "lax" then
            self:check(pending.kind, pending.pos)
          end
        end
      end
      if self.confirm_kill then
        self.confirm_kill(kill)
      else
        vim.ui.select({ "Kill and restart F*", "Keep waiting" }, {
          prompt = "F* has not stopped yet (a long SMT query may be running). Verified status will be lost if it is restarted.",
        }, function(choice)
          if choice == "Kill and restart F*" then
            kill()
          end
        end)
      end
    end)
  )
  self:emit("state")
end

--- User cancel: stop the running check, do not start another.
function Session:cancel()
  self.pending = nil
  stop_timer(self.debounce_timer)
  if self.running then
    self.cancelled_by_user = true
  end
  self:_cancel_running()
end

--- Re-read dependencies from disk, then lax-check.
--- F*'s own `reload-deps` keeps reusing unchanged declarations that were
--- checked against the old dependency, so dependents would show stale
--- results. A fresh process re-reads every dependency; verified marks are
--- dropped, which is right because a dependency changed.
function Session:reload_deps()
  self:restart()
end

-- queries --------------------------------------------------------------------

function Session:_fail_waiters()
  local ws = self.waiters
  self.waiters = {}
  for _, w in ipairs(ws) do
    close_timer(w.timer)
    w.cb("busy", nil)
  end
end

function Session:_flush_waiters()
  local ws = self.waiters
  self.waiters = {}
  for _, w in ipairs(ws) do
    close_timer(w.timer)
    self:_send_query(w.query, w.args, w.cb)
  end
end

function Session:_send_query(query, args, cb)
  if not self.alive or not self.transport then
    cb("unavailable", "F* is not running")
    return
  end
  local tick = self:_tick()
  local qid, err = self.transport:request(query, args, {
    on_response = function(status, response)
      if not vim.api.nvim_buf_is_loaded(self.bufnr) or self:_tick() ~= tick then
        cb("unavailable", "the buffer changed during the query; refresh neostar_context and retry")
      else
        cb(status, response)
      end
    end,
  })
  if not qid then
    cb("unavailable", err)
  end
end

--- Send a non-checking query, honouring the busy policy:
--- idle -> now; lax check -> wait (with timeout); full check -> "busy".
---@param query string
---@param args table
---@param cb fun(status: "success"|"failure"|"busy"|"unavailable", response: any)
function Session:query(query, args, cb)
  local cls = self:running_class()
  if cls == "full" then
    cb("busy", nil)
    return
  end
  if self.alive and not self.running and self.sent_tick ~= self:_tick() then
    self:check("lax")
    cls = self:running_class()
  end
  if cls == "lax" or self.pending then
    local w = { query = query, args = args, cb = cb, timer = new_timer() }
    table.insert(self.waiters, w)
    w.timer:start(
      self.lax_request_timeout_ms,
      0,
      vim.schedule_wrap(function()
        for i, x in ipairs(self.waiters) do
          if x == w then
            table.remove(self.waiters, i)
            close_timer(w.timer)
            cb("busy", nil)
            return
          end
        end
      end)
    )
    return
  end
  self:_send_query(query, args, cb)
end

M.Session = Session
return M
