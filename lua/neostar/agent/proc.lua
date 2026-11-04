--- Process plumbing shared by agent runners: the private MCP config file, the
--- executable check, line-buffered JSON stdout, stderr capture and stopping.

local M = {}

---@class neostar.ProcSpec
---@field exe string executable (checked unless opts.spawn is set)
---@field missing string error message when the executable is not found
---@field mcp_config table contents of the MCP config file
---@field args fun(cfg_path: string): string[] full command line
---@field stdin string
---@field cwd? string
---@field spawn? function vim.system replacement (tests)
---@field on_message fun(msg: table, state: table) one decoded JSON line
---@field result fun(state: table, out: table): table on_done result after a normal exit
---@field on_done? fun(res: table)

--- Write `data` as JSON to a 0600 file in a fresh 0700 directory.
---@return string path, string dir
function M.private_json(data)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p", tonumber("700", 8))
  local path = dir .. "/mcp.json"
  local fd = assert(io.open(path, "w"))
  fd:write(vim.json.encode(data))
  fd:close()
  vim.uv.fs_chmod(path, tonumber("600", 8))
  return path, dir
end

--- Last non-empty stderr text, trimmed (at most `max` lines).
---@param state table
---@param max? integer
function M.stderr_tail(state, max)
  local text = vim.trim(table.concat(state.stderr))
  if text == "" then
    return nil
  end
  local lines = vim.split(text, "\n", { plain = true })
  max = max or 10
  if #lines > max then
    lines = vim.list_slice(lines, #lines - max + 1)
  end
  return table.concat(lines, "\n")
end

--- Start the process. Returns a handle {stop(), session_id(), is_done()} or nil and an error.
--- `state.fail(err)` (available to on_message) kills the process and ends the run with `err`.
---@param spec neostar.ProcSpec
---@return table? handle, string? err
function M.start(spec)
  if not spec.spawn and vim.fn.executable(spec.exe) ~= 1 then
    return nil, spec.missing
  end
  local cfg_path, dir = M.private_json(spec.mcp_config)
  local state = { done = false, stopped = false, stderr = {}, partial = "" }
  local proc

  local function finish(res)
    if state.done then
      return
    end
    state.done = true
    vim.fn.delete(dir, "rf")
    res.session_id = res.session_id or state.session_id
    if spec.on_done then
      spec.on_done(res)
    end
  end

  function state.fail(err)
    if state.done or state.stopped or state.failed then
      return
    end
    state.failed = err
    pcall(function()
      proc:kill(15)
    end)
  end

  local function on_line(line)
    if state.failed or not line:match("%S") then
      return
    end
    local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(msg) == "table" then
      spec.on_message(msg, state)
    end
  end

  local spawn = spec.spawn or vim.system
  local ok
  ok, proc = pcall(spawn, spec.args(cfg_path), {
    cwd = spec.cwd,
    stdin = spec.stdin,
    text = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          local buf = state.partial .. data
          local start = 1
          while true do
            local nl = buf:find("\n", start, true)
            if not nl then
              break
            end
            on_line(buf:sub(start, nl - 1))
            start = nl + 1
          end
          state.partial = buf:sub(start)
        end)
      end
    end,
    stderr = function(_, data)
      if data then
        table.insert(state.stderr, data)
      end
    end,
  }, function(out)
    vim.schedule(function()
      if state.partial ~= "" then
        on_line(state.partial)
        state.partial = ""
      end
      if state.stopped then
        finish({ ok = false, stopped = true, error = "stopped" })
      elseif state.failed then
        finish({ ok = false, error = state.failed })
      else
        finish(spec.result(state, out))
      end
    end)
  end)
  if not ok then
    vim.fn.delete(dir, "rf")
    return nil, "neostar: could not start the agent: " .. tostring(proc)
  end

  return {
    stop = function()
      if state.done or state.stopped then
        return
      end
      state.stopped = true
      pcall(function()
        proc:kill(15)
      end)
    end,
    session_id = function()
      return state.session_id
    end,
    is_done = function()
      return state.done
    end,
  }
end

return M
