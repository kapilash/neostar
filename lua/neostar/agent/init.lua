--- Agent runs per buffer: at most one at a time; stopping a run also stops
--- its scratch checker and revokes its MCP token.

local M = {}

---@class neostar.AgentRun
---@field kind "explain"|"prove"
---@field phase? "running"|"reviewing"|"rechecking"
---@field handle? table runner handle
---@field token? string MCP token
---@field scratch? neostar.Scratch
---@field timer? uv.uv_timer_t
---@field docs? table documentation backend lease
---@field on_stop? fun(reason: string)
---@field ended? boolean

---@type table<integer, neostar.AgentRun>
M.runs = {}

--- Project root for agent runs: the config directory, else the file's directory.
---@param session neostar.Session
function M.project_root(session)
  return session.root or vim.fn.fnamemodify(session.file, ":h")
end

function M.release_docs(run)
  if run.docs then
    require("neostar.agent.docs").release(run.docs)
    run.docs = nil
  end
end

local function release(run)
  M.release_docs(run)
  if run.timer and not run.timer:is_closing() then
    run.timer:stop()
    run.timer:close()
  end
  run.timer = nil
  if run.token then
    require("neostar.agent.mcp").revoke(run.token)
    run.token = nil
  end
  if run.scratch then
    run.scratch:close()
    run.scratch = nil
  end
end

--- Register a new run for a buffer, stopping any previous one.
---@param bufnr integer
---@param run neostar.AgentRun
function M.begin(bufnr, run)
  M.stop(bufnr, "replaced by a new request")
  M.runs[bufnr] = run
  return run
end

--- Finish a request, including any proof review or accept-time re-check.
function M.finish(bufnr, run)
  if run.ended then
    return
  end
  run.ended = true
  release(run)
  if M.runs[bufnr] == run then
    M.runs[bufnr] = nil
  end
end

--- Stop the buffer's run, if any. Returns true if one was running.
---@param bufnr integer
---@param reason? string
function M.stop(bufnr, reason)
  local run = M.runs[bufnr]
  if not run then
    return false
  end
  M.runs[bufnr] = nil
  if run.ended then
    return false
  end
  run.ended = true
  if run.handle then
    run.handle.stop()
  end
  release(run)
  if run.on_stop then
    run.on_stop(reason or "stopped")
  end
  return true
end

function M.stop_all()
  for bufnr in pairs(M.runs) do
    M.stop(bufnr, "Neovim is exiting")
  end
end

---@param bufnr integer
---@return neostar.AgentRun?
function M.current(bufnr)
  return M.runs[bufnr]
end

return M
