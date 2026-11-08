--- Run-scoped library documentation tools for agents. By default they are
--- answered in process from the fstardoc index (neostar.fstardoc); when
--- `server` is set, they are proxied to that fstardoc stdio MCP server instead.
local M = {}
local uv = vim.uv
local pools, leases = {}, {}
local names = { "find_by_contract", "find_by_type", "lookup", "used_by", "list_module", "modules" }
local approved = {}
for _, name in ipairs(names) do
  approved[name] = true
end
local MAX_BYTES = 8 * 1024 * 1024
M.timeout_ms = 10000
M.last_error = nil

function M.normalize(config)
  local c = vim.deepcopy(config)
  for _, key in ipairs({ "server", "index", "python" }) do
    local path = c[key]
    if path and (key ~= "python" or path:find("[/\\]") or path:sub(1, 1) == "~") then
      c[key] = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
    end
  end
  return c
end

--- "local" (in-process index reader) or "server" (external fstardoc_mcp.py).
function M.backend(c)
  return (c.server and c.server ~= "") and "server" or "local"
end

function M.problem(c)
  if not c.enabled then
    return "documentation retrieval is disabled"
  elseif M.backend(c) == "local" then
    if vim.fn.filereadable(c.index) ~= 1 then
      return "documentation index is not readable: " .. c.index
    end
    return nil
  elseif vim.fn.executable(c.python) ~= 1 then
    return "documentation Python executable not found: " .. c.python
  elseif not c.server or vim.fn.filereadable(c.server) ~= 1 then
    return "documentation server is not readable: " .. (c.server or "set agent.docs.server")
  elseif vim.fn.filereadable(c.index) ~= 1 then
    return "documentation index is not readable: " .. c.index
  end
end

local function timer_close(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function complete(pool, id, result, err)
  local request = pool.pending[id]
  if not request then
    return
  end
  pool.pending[id] = nil
  timer_close(request.timer)
  request.callback(result, err)
end

local function close(pool, err, reloading)
  if pool.closed then
    return
  end
  pool.closed = true
  if pools[pool.key] == pool then
    pools[pool.key] = nil
  end
  if err then
    M.last_error = err
  end
  for lease in pairs(pool.users) do
    if not reloading then
      lease.failed = err or "documentation request ended"
    end
  end
  if pool.proc and not pool.exited then
    pcall(pool.proc.write, pool.proc, nil)
    pcall(pool.proc.kill, pool.proc, 15)
    pool.kill_timer = uv.new_timer()
    pool.kill_timer:start(1000, 0, vim.schedule_wrap(function()
      timer_close(pool.kill_timer)
      pool.kill_timer = nil
      if not pool.exited then
        pcall(pool.proc.kill, pool.proc, 9)
      end
    end))
  end
  for _, id in ipairs(vim.tbl_keys(pool.pending)) do
    complete(pool, id, nil, err or "documentation request ended")
  end
  local waiters = pool.waiters
  pool.waiters = {}
  for _, waiter in ipairs(waiters) do
    waiter.callback(nil, err or "documentation request ended")
  end
end

local function write(pool, message)
  local ok, err = pcall(pool.proc.write, pool.proc, vim.json.encode(message) .. "\n")
  if not ok then
    close(pool, "cannot write to documentation server: " .. tostring(err))
  end
  return ok
end

local function request(pool, method, params, owner, callback)
  if pool.closed then
    callback(nil, "documentation server is unavailable")
    return
  end
  pool.next_id = pool.next_id + 1
  local id = pool.next_id
  local timer = uv.new_timer()
  pool.pending[id] = { callback = callback, owner = owner, timer = timer }
  timer:start(M.timeout_ms, 0, vim.schedule_wrap(function()
    close(pool, "documentation server timed out")
  end))
  write(pool, { jsonrpc = "2.0", id = id, method = method, params = params })
end

local function on_line(pool, line)
  if pool.closed or line == "" then
    return
  end
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= "table" or msg.jsonrpc ~= "2.0" then
    close(pool, "documentation server returned invalid JSON-RPC")
    return
  end
  if msg.id == nil then
    return
  end
  if not pool.pending[msg.id] then
    return
  end
  if msg.error then
    complete(pool, msg.id, nil, "documentation RPC error: " .. vim.inspect(msg.error))
  elseif type(msg.result) == "table" then
    complete(pool, msg.id, msg.result)
  else
    close(pool, "documentation server returned an invalid result")
  end
end

local function start(c, key)
  local pool = { key = key, pending = {}, waiters = {}, next_id = 0, partial = "", stderr = "", users = {} }
  pools[key] = pool
  local ok, proc = pcall(M._spawn or vim.system, { c.python, c.server, "serve", "--index", c.index }, {
    stdin = true,
    text = true,
    stdout = function(err, data)
      vim.schedule(function()
        if pool.closed then
          return
        end
        if err then
          close(pool, "documentation stdout error: " .. tostring(err))
        elseif data then
          local text = pool.partial .. data
          if #text > MAX_BYTES then
            close(pool, "documentation response exceeds size limit")
            return
          end
          local pos = 1
          while not pool.closed do
            local ending = text:find("\n", pos, true)
            if not ending then
              break
            end
            on_line(pool, text:sub(pos, ending - 1))
            pos = ending + 1
          end
          pool.partial = text:sub(pos)
        end
      end)
    end,
    stderr = function(_, data)
      if data then
        pool.stderr = (pool.stderr .. data):sub(-65536)
      end
    end,
  }, function(out)
    vim.schedule(function()
      pool.exited = true
      timer_close(pool.kill_timer)
      pool.kill_timer = nil
      close(pool, "documentation server exited (" .. tostring(out.code) .. "): " .. pool.stderr)
    end)
  end)
  if not ok then
    close(pool, "cannot start documentation server: " .. tostring(proc))
    return pool
  end
  pool.proc = proc
  request(pool, "initialize", {
    protocolVersion = "2025-06-18",
    capabilities = vim.empty_dict(),
    clientInfo = { name = "neostar", version = "0.2.0" },
  }, nil, function(result, err)
    if err then
      close(pool, err)
      return
    end
    if type(result.capabilities) ~= "table" or type(result.capabilities.tools) ~= "table" then
      close(pool, "documentation server does not support MCP tools")
      return
    end
    if not write(pool, { jsonrpc = "2.0", method = "notifications/initialized" }) then
      return
    end
    request(pool, "tools/list", vim.empty_dict(), nil, function(list, list_err)
      if list_err then
        close(pool, list_err)
        return
      end
      local tools = {}
      for _, tool in ipairs(type(list.tools) == "table" and list.tools or {}) do
        if type(tool) ~= "table" or type(tool.name) ~= "string" then
          close(pool, "documentation server returned an invalid tool contract")
          return
        end
        if approved[tool.name] then
          if tools[tool.name] or type(tool.description) ~= "string"
            or type(tool.inputSchema) ~= "table" or tool.inputSchema.type ~= "object" then
            close(pool, "documentation server returned an invalid tool contract")
            return
          end
          tools[tool.name] = tool
        end
      end
      for _, name in ipairs(names) do
        if not tools[name] then
          close(pool, "documentation server is missing tool: " .. name)
          return
        end
      end
      pool.tools = tools
      M.last_error = nil
      local waiters = pool.waiters
      pool.waiters = {}
      for _, waiter in ipairs(waiters) do
        waiter.callback(pool)
      end
    end)
  end)
  return pool
end

local function ensure(lease, callback)
  if lease.released then
    callback(nil, "documentation request ended")
    return
  elseif lease.failed then
    callback(nil, lease.failed)
    return
  end
  local pool = pools[lease.key]
  if not pool then
    pool = start(lease.config, lease.key)
  end
  lease.pool = pool
  pool.users[lease] = true
  if pool.closed then
    callback(nil, M.last_error)
  elseif pool.tools then
    callback(pool)
  else
    table.insert(pool.waiters, { owner = lease, callback = callback })
  end
end

local function result_text(result)
  if type(result.content) ~= "table" or not vim.islist(result.content) then
    return nil, "documentation server returned unsupported content"
  end
  local text = {}
  for _, part in ipairs(result.content) do
    if type(part) ~= "table" or part.type ~= "text" or type(part.text) ~= "string" then
      return nil, "documentation server returned unsupported content"
    end
    text[#text + 1] = part.text
  end
  return table.concat(text, "\n")
end

function M.release(lease)
  if not lease or lease.released then
    return
  end
  lease.released = true
  leases[lease] = nil
  local pool = lease.pool
  if pool then
    pool.users[lease] = nil
    for _, id in ipairs(vim.tbl_keys(pool.pending)) do
      if pool.pending[id] and pool.pending[id].owner == lease then
        complete(pool, id, nil, "documentation request ended")
      end
    end
    local remaining = {}
    for _, waiter in ipairs(pool.waiters) do
      if waiter.owner == lease then
        waiter.callback(nil, "documentation request ended")
      else
        remaining[#remaining + 1] = waiter
      end
    end
    pool.waiters = remaining
    if not next(pool.users) then
      close(pool)
    end
  end
end

--- Tools answered in process from the index file. The index is loaded when
--- the run starts, and each call re-reads it if the file has changed.
local function prepare_local(run, config, callback)
  local index = require("neostar.fstardoc")
  local _, err = index.load(config.index)
  if err then
    M.last_error = err
    callback({}, err)
    return
  end
  M.last_error = nil
  local lease = { config = vim.deepcopy(config), backend = "local" }
  leases[lease] = true
  run.docs = lease
  local tools = {}
  for _, contract in ipairs(index.contracts) do
    local name = contract.name
    tools["fstardoc_" .. name] = {
      description = contract.description,
      inputSchema = vim.deepcopy(contract.inputSchema),
      handler = function(args, _, respond)
        if lease.released then
          respond("documentation request ended", true)
          return
        end
        local idx, load_err = index.load(lease.config.index)
        if not idx then
          M.last_error = load_err
          if lease.on_error then lease.on_error(load_err) end
          respond(load_err, true)
          return
        end
        respond(index.call(idx, name, args))
      end,
    }
  end
  -- Asynchronous like the server backend, so callers see one behaviour.
  vim.schedule(function()
    if not lease.released then
      callback(tools)
    end
  end)
end

function M.prepare(run, config, callback)
  if not config.enabled then
    callback({})
    return
  end
  local err = M.problem(config)
  if err then
    M.last_error = err
    callback({}, err)
    return
  end
  if M.backend(config) == "local" then
    prepare_local(run, config, callback)
    return
  end
  local lease = { config = vim.deepcopy(config), key = vim.json.encode({ config.python, config.server, config.index }) }
  leases[lease] = true
  run.docs = lease
  ensure(lease, function(pool, problem)
    if lease.released then
      return
    end
    if problem then
      callback({}, problem)
      return
    end
    local tools = {}
    for _, name in ipairs(names) do
      local tool = pool.tools[name]
      tools["fstardoc_" .. name] = {
        description = tool.description,
        inputSchema = vim.deepcopy(tool.inputSchema),
        handler = function(args, _, respond)
          if lease.released then
            respond("documentation request ended", true)
            return
          end
          ensure(lease, function(current, ready_err)
            if ready_err then
              if lease.on_error then lease.on_error(ready_err) end
              respond(ready_err, true)
              return
            end
            request(current, "tools/call", { name = name, arguments = args }, lease, function(result, call_err)
              local text, content_err
              if result then
                text, content_err = result_text(result)
              end
              call_err = call_err or content_err
              if call_err and not lease.released and lease.on_error then
                lease.on_error(call_err)
              end
              respond(call_err or text, call_err ~= nil or result.isError == true)
            end)
          end)
        end,
      }
    end
    callback(tools)
  end)
end

M.guidance = table.concat({
  "Static library documentation is available through fstardoc_find_by_contract (discover lemmas by",
  "requires/ensures), fstardoc_find_by_type (type shape), fstardoc_lookup (inspect a declaration),",
  "fstardoc_used_by (worked uses), fstardoc_list_module and fstardoc_modules.",
  "Use these to discover existing lemmas instead of guessing names. The index covers only exported",
  "public declarations and may be stale or incomplete; no match does not prove nonexistence.",
  "Preserve ambiguity and approximate-match warnings, and distinguish undocumented types from author documentation.",
  "Use fstar_lookup for live checker context and neostar_context for authoritative unsaved text.",
  "Indexed results are not proof verification; proofs still require check_proof and reviewed propose_proof.",
}, " ")

function M.prepare_run(run, config, window, callback)
  local warned = false
  local function warn(err)
    if not run.ended and not warned then
      warned = true
      if window:is_open() then
        window:append("\n\n**Documentation warning:** " .. err .. ". Continuing with checker tools.\n\n")
      end
    end
  end
  M.prepare(run, config, function(tools, err)
    if run.ended then
      return
    end
    if err then warn(err) end
    if run.docs then run.docs.on_error = warn end
    local guidance = next(tools) and M.guidance
      or (config.enabled and "Static documentation tools are unavailable this turn; use the live checker tools." or "")
    callback(tools, guidance)
  end)
end

function M.reload()
  if package.loaded["neostar.fstardoc"] then
    require("neostar.fstardoc").clear()
  end
  for lease in pairs(leases) do
    lease.failed = nil
  end
  for _, pool in pairs(vim.tbl_extend("force", {}, pools)) do
    close(pool, "documentation index reloaded; retry the tool call", true)
  end
end

function M.shutdown()
  for lease in pairs(vim.tbl_extend("force", {}, leases)) do
    M.release(lease)
  end
  M.reload()
end

return M
