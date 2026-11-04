--- A fake `fstar.exe --ide` process that replays recorded transcripts.
---
--- It plugs into the real transport through its `spawn` hook, so tests
--- exercise JSON framing and routing too. Each query the plugin writes is
--- matched against an unused recorded step (same query; same kind / symbol /
--- term / partial-symbol when recorded) and the recorded messages are
--- replayed with their query ids rewritten to the plugin's id.

local transport = require("neostar.fstar.transport")

local M = {}

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
M.fixtures = root .. "/fixtures"

function M.read(path)
  local fd = assert(io.open(path, "r"))
  local s = fd:read("*a")
  fd:close()
  return s
end

function M.transcript(name)
  return vim.json.decode(M.read(M.fixtures .. "/transcripts/" .. name .. ".json"), { luanil = { object = true, array = true } })
end

function M.file(name)
  return M.fixtures .. "/files/" .. name
end

---@class FakeFStar
local Fake = {}
Fake.__index = Fake

--- opts:
---   auto (default true): deliver replies immediately; otherwise use :pump()
---   on_cancel: "finish" (default) drops queued messages and finishes the run;
---              "hang" ignores the cancel
---   start_error: make spawn fail with this message
function M.new(transcript, opts)
  opts = opts or {}
  return setmetatable({
    transcript = transcript,
    used = {},
    sent = {},
    queue = {},
    auto = opts.auto ~= false,
    on_cancel = opts.on_cancel or "finish",
    any_kind = opts.any_kind,
    start_error = opts.start_error,
    running_root = nil,
    exited = false,
    spawned = 0,
  }, Fake)
end

local function key_of(args)
  return args.kind or args.symbol or args.term or args["partial-symbol"]
end

function Fake:_match(query, args)
  if self.any_kind and query == "full-buffer" then
    args = vim.tbl_extend("force", args, { kind = false })
  end
  -- first an unused step, then (e.g. after a restart) any step
  for pass = 1, 2 do
    local fallback
    for i, step in ipairs(self.transcript.steps) do
      if (pass == 2 or not self.used[i]) and step.send.query == query then
        local rk = key_of(step.send.args)
        if rk == nil or rk == key_of(args) or (args.kind == false) then
          return i
        end
        fallback = fallback or (query ~= "full-buffer" and i or nil)
      end
    end
    if fallback then
      return fallback
    end
  end
  return nil
end

function Fake:_emit(msg)
  if self.exited then
    return
  end
  self.stdout(nil, vim.json.encode(msg) .. "\n")
end

function Fake:_enqueue(msgs)
  for _, m in ipairs(msgs) do
    table.insert(self.queue, m)
  end
  if self.auto then
    self:pump()
  end
end

--- Deliver up to n queued messages (all when n is nil).
function Fake:pump(n)
  local count = 0
  while #self.queue > 0 and (n == nil or count < n) do
    local m = table.remove(self.queue, 1)
    self:_emit(m)
    count = count + 1
  end
  return count
end

local function rewrite(msg, old, new)
  local m = vim.deepcopy(msg)
  local qid = m["query-id"]
  if type(qid) == "string" and (qid == old or qid:sub(1, #old + 1) == old .. ".") then
    m["query-id"] = new .. qid:sub(#old + 1)
  end
  return m
end

function Fake:_on_query(q)
  table.insert(self.sent, q)
  local query, args, qid = q.query, q.args or {}, q["query-id"]
  if query == "describe-protocol" then
    self:_enqueue({ { kind = "response", ["query-id"] = qid, status = "success", response = { version = 3 } } })
    return
  end
  if query == "cancel" then
    if self.on_cancel == "finish" and self.running_root then
      -- drop the rest of the run, keep later unrelated replies
      local keep = {}
      for _, m in ipairs(self.queue) do
        if transport.root_qid(m["query-id"]) ~= self.running_root then
          table.insert(keep, m)
        end
      end
      self.queue = keep
      local root_id = self.running_root
      self.running_root = nil
      self:_enqueue({
        { kind = "message", ["query-id"] = root_id, level = "progress", contents = { stage = "full-buffer-finished" } },
      })
    end
    return
  end
  local i = self:_match(query, args)
  if not i then
    self:_enqueue({ { kind = "response", ["query-id"] = qid, status = "failure", response = "fake: no recorded step for " .. query } })
    return
  end
  self.used[i] = true
  local step = self.transcript.steps[i]
  local old = step.send["query-id"]
  local msgs = {}
  for _, m in ipairs(step.recv) do
    table.insert(msgs, rewrite(m, old, qid))
  end
  if query == "full-buffer" then
    self.running_root = qid
  end
  self:_enqueue(msgs)
end

--- `spawn` replacement for the transport.
function Fake:spawn(cmd, sys_opts, on_exit)
  self.spawned = self.spawned + 1
  self.cmd = cmd
  if self.start_error then
    error(self.start_error)
  end
  self.stdout = sys_opts.stdout
  self.stderr_cb = sys_opts.stderr
  self.on_exit_cb = on_exit
  self.exited = false
  self.queue = {}
  local fake = self
  local partial = ""
  return {
    write = function(_, data)
      partial = partial .. data
      while true do
        local nl = partial:find("\n", 1, true)
        if not nl then
          break
        end
        local line = partial:sub(1, nl - 1)
        partial = partial:sub(nl + 1)
        fake:_on_query(vim.json.decode(line))
      end
    end,
    kill = function()
      fake.exited = true
    end,
  }
end

--- Simulate the process dying.
function Fake:exit(code, stderr)
  if stderr and self.stderr_cb then
    self.stderr_cb(nil, stderr)
  end
  self.exited = true
  self.on_exit_cb({ code = code, signal = 0, stdout = "", stderr = stderr or "" })
end

--- Transport factory for Session options.
function Fake:factory()
  return function(topts)
    topts.spawn = function(cmd, sys_opts, on_exit)
      return self:spawn(cmd, sys_opts, on_exit)
    end
    return transport.new(topts)
  end
end

--- Queries sent so far with the given name.
function Fake:sent_of(query)
  local out = {}
  for _, q in ipairs(self.sent) do
    if q.query == query then
      table.insert(out, q)
    end
  end
  return out
end

M.Fake = Fake
return M
