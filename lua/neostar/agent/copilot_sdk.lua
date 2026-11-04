--- Persistent native SDK helpers, shared by conversations in the same project.
local M = {}
local pools, next_id = {}, 0

local function finish(pool, id, result)
  local run = pool.runs[id]
  if not run then
    return
  end
  pool.runs[id] = nil
  run.done = true
  result.session_id = run.session_id
  if run.opts.on_done then
    run.opts.on_done(result)
  end
end

local function write(pool, message)
  if pool.closing then
    return false
  end
  return pcall(pool.proc.write, pool.proc, vim.json.encode(message) .. "\n")
end

local function close(pool, error)
  if pool.closing then
    return
  end
  write(pool, { op = "shutdown" })
  pool.closing = true
  if pools[pool.key] == pool then
    pools[pool.key] = nil
  end
  if pool.timer then
    pool.timer:stop()
    pool.timer:close()
    pool.timer = nil
  end
  pcall(pool.proc.write, pool.proc, nil)
  for _, id in ipairs(vim.tbl_keys(pool.runs)) do
    finish(pool, id, { ok = false, error = error or "Copilot SDK helper shut down" })
  end
  vim.defer_fn(function()
    if not pool.exited then
      pcall(pool.proc.kill, pool.proc, 15)
    end
  end, 15000)
end

local function send_run(pool, id, run)
  local opts = run.opts
  if not write(pool, {
    op = "run",
    id = id,
    prompt = opts.prompt,
    system_prompt = opts.system_prompt or "",
    model = opts.model,
    resume = opts.resume,
    keep_session = opts.keep_session == true,
    mcp_server = vim.tbl_extend("force", opts.mcp_server or {}, { tools = { "*" } }),
  }) then
    close(pool, "Could not write to Copilot SDK helper")
  end
end

local function on_line(pool, line)
  if pool.closing or line == "" then
    return
  end
  local ok, message = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(message) ~= "table" then
    close(pool, "Copilot SDK helper returned invalid JSON")
    return
  end
  if message.type == "ready" then
    if pool.ready or message.protocol ~= 1 then
      close(pool, "Incompatible Copilot SDK helper protocol; rebuild neostar-copilot")
      return
    end
    pool.ready = true
    pool.timer:stop()
    pool.timer:close()
    pool.timer = nil
    for id, run in pairs(pool.runs) do
      send_run(pool, id, run)
    end
    return
  end
  local run = pool.runs[message.id]
  if not run then
    return
  end
  if message.type == "session" then
    run.session_id = message.session_id
    local owned = pool.buffers[run.opts.bufnr]
    if owned and run.opts.keep_session then
      owned[run.session_id] = true
    end
  elseif message.type == "event" and type(message.event) == "table" then
    run.parse(message.event, run)
  elseif message.type == "done" then
    finish(pool, message.id, { ok = message.ok == true, error = message.error })
  end
end

local function connect(opts, helper, cli, key)
  local pool = { key = key, runs = {}, buffers = {}, partial = "", stderr = {} }
  local state_dir = vim.fn.stdpath("state") .. "/neostar/copilot"
  vim.fn.mkdir(state_dir, "p", tonumber("700", 8))
  local ok, proc = pcall(opts.spawn or vim.system, {
    helper, "--cli", cli, "--cwd", opts.cwd, "--state-dir", state_dir,
  }, {
    cwd = opts.cwd,
    stdin = true,
    text = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          local text = pool.partial .. data
          local start = 1
          while true do
            local newline = text:find("\n", start, true)
            if not newline then
              break
            end
            on_line(pool, text:sub(start, newline - 1))
            start = newline + 1
          end
          pool.partial = text:sub(start)
        end)
      end
    end,
    stderr = function(_, data)
      if data then
        pool.stderr = { (table.concat(pool.stderr) .. data):sub(-65536) }
      end
    end,
  }, function(out)
    vim.schedule(function()
      pool.exited = true
      close(pool, require("neostar.agent.proc").stderr_tail(pool)
        or ("Copilot SDK helper exited with code " .. tostring(out.code)))
    end)
  end)
  if not ok then
    return nil, "Could not start Copilot SDK helper: " .. tostring(proc)
  end
  pool.proc = proc
  pools[key] = pool
  pool.timer = assert(vim.uv.new_timer())
  pool.timer:start(30000, 0, vim.schedule_wrap(function()
    close(pool, "Timed out starting Copilot SDK helper; check CLI authentication and version")
  end))
  return pool
end

function M.start(opts)
  local helper = vim.fn.exepath(opts.helper or "neostar-copilot")
  local cli = vim.fn.exepath(opts.cmd or "copilot")
  if helper == "" then
    return nil, "neostar: native Copilot helper not found; build tools/copilot or use agent.copilot.transport = 'cli'"
  end
  if cli == "" then
    return nil, "neostar: Copilot CLI not found; check agent.copilot.cmd"
  end
  opts = vim.tbl_extend("force", opts, { cwd = opts.cwd or vim.fn.getcwd() })
  local key = table.concat({ helper, cli, opts.cwd }, "\n")
  local pool, err = pools[key], nil
  if not pool then
    pool, err = connect(opts, helper, cli, key)
    if not pool then
      return nil, err
    end
  end
  next_id = next_id + 1
  local id = next_id
  local run = { opts = opts, session_id = opts.resume, parse = require("neostar.agent.copilot").make_parser(opts) }
  function run.fail(error)
    write(pool, { op = "cancel", id = id })
    finish(pool, id, { ok = false, error = error })
  end
  pool.runs[id] = run
  if opts.bufnr then
    pool.buffers[opts.bufnr] = pool.buffers[opts.bufnr] or {}
  end
  if pool.ready then
    send_run(pool, id, run)
  end
  return {
    transport = "sdk",
    helper = helper,
    cmd = cli,
    release = function()
      if run.session_id then
        write(pool, { op = "release", session_id = run.session_id })
        local owned = pool.buffers[opts.bufnr]
        if owned then
          owned[run.session_id] = nil
        end
      end
    end,
    stop = function()
      if not run.done then
        write(pool, { op = "cancel", id = id })
        finish(pool, id, { ok = false, stopped = true, error = "stopped" })
      end
    end,
    session_id = function() return run.session_id end,
    is_done = function() return run.done == true end,
  }
end

function M.detach(bufnr)
  for _, pool in pairs(vim.tbl_extend("force", {}, pools)) do
    for session_id in pairs(pool.buffers[bufnr] or {}) do
      write(pool, { op = "release", session_id = session_id })
    end
    pool.buffers[bufnr] = nil
    if next(pool.buffers) == nil then
      close(pool)
    end
  end
end

function M.shutdown()
  for _, pool in pairs(vim.tbl_extend("force", {}, pools)) do
    close(pool)
  end
end

return M
