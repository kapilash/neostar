--- Agent runner interface. A runner starts one agent run:
---
---   runner.start{ cmd, cwd, prompt, system_prompt, mcp_server, model, resume,
---                 on_text, on_tool, on_done } -> handle | nil, err
---
--- on_tool(name, input) gets the plain tool name: the MCP tool's own name
--- (`check_proof`) or the agent's built-in tool name (`Read`, `view`).
---   handle: stop(), session_id(), is_done()
---
--- Runners must give the agent read-only access to the project plus the MCP
--- server described by `mcp_server`, and nothing else.

local M = {}

---@type table<string, {start: fun(opts: table): (table?, string?)}>
M.registry = {
  claude = require("neostar.agent.claude"),
  copilot = require("neostar.agent.copilot"),
}

--- Order in which "auto" tries the agents.
M.auto_order = { "claude", "copilot" }

--- Pick the runner for a run: `name` (a follow-up's runner), else the
--- configured one; "auto" takes the first agent whose executable is found.
---@param config table agent options
---@param name? string
---@return string? runner, string? err
function M.resolve(config, name)
  name = name or config.runner or "auto"
  if name ~= "auto" then
    if not M.registry[name] then
      return nil, ("neostar: unknown agent runner `%s`"):format(tostring(name))
    end
    return name
  end
  local cmds = {}
  for _, n in ipairs(M.auto_order) do
    local cmd = (config[n] or {}).cmd or n
    if vim.fn.executable(cmd) == 1 then
      return n
    end
    table.insert(cmds, ("`%s`"):format(cmd))
  end
  return nil,
    ("neostar: no agent found: neither %s is on PATH. Install Claude Code or GitHub Copilot CLI, or set `agent.claude.cmd` / `agent.copilot.cmd` in require('neostar').setup()."):format(
      table.concat(cmds, " nor ")
    )
end

--- Start a run with the configured (or given) runner.
---@param opts table runner options (see neostar.RunnerOpts); opts.runner forces a runner
---@param config? table agent options; defaults to setup() options
---@return table? handle, string? err, string? runner name of the runner used
function M.start(opts, config)
  config = config or require("neostar").options.agent
  local name, err = M.resolve(config, opts.runner)
  if not name then
    return nil, err
  end
  local rc = config[name] or {}
  opts = vim.tbl_extend("keep", opts, rc)
  opts.runner = nil
  local handle, start_err = M.registry[name].start(opts)
  if not handle then
    return nil, start_err, name
  end
  handle.runner = name
  handle.config = {
    runner = name,
    [name] = vim.tbl_extend("force", rc, {
      cmd = handle.cmd or opts.cmd,
      transport = handle.transport or opts.transport,
      helper = handle.helper or opts.helper,
    }),
  }
  return handle, nil, name
end

function M.label(handle)
  local config = handle.config[handle.runner]
  return ("%s%s; model: %s"):format(
    handle.runner,
    handle.transport and ("/" .. handle.transport) or "",
    config.model or "agent default"
  )
end

return M
