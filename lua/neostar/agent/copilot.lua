--- GitHub Copilot CLI runner: `copilot` in prompt mode with JSONL output, the
--- prompt on stdin, neostar's MCP server added for the run, and only read-only
--- built-in tools visible to the model.

local M = {}

--- Read-only built-in tools (file view, glob, ripgrep).
M.builtin_tools = { "view", "glob", "rg" }

--- Separator between the system prompt and the task (Copilot has no
--- system-prompt option).
M.separator = "\n\n---\n\n"

M.no_mcp_message =
  "Copilot could not connect to neostar's tool server (MCP servers may be disabled by your organization's Copilot policy)"

--- Command line for a run (the prompt goes to stdin).
---@param opts neostar.RunnerOpts
---@param mcp_config_path string
function M.build_args(opts, mcp_config_path)
  local available = vim.deepcopy(M.builtin_tools)
  table.insert(available, "neostar")
  local args = {
    opts.cmd,
    "--output-format",
    "json",
    "--stream",
    "on",
    "--additional-mcp-config",
    "@" .. mcp_config_path,
    "--available-tools",
  }
  vim.list_extend(args, available)
  vim.list_extend(args, {
    "--allow-tool",
    "neostar",
    "--deny-tool",
    "shell",
    "--deny-tool",
    "write",
    "--no-ask-user",
    "--disable-builtin-mcps",
    "--disallow-temp-dir",
    "--no-color",
  })
  if opts.model and opts.model ~= "" then
    vim.list_extend(args, { "--model", opts.model })
  end
  if opts.resume then
    table.insert(args, "--resume=" .. opts.resume)
  end
  return args
end

--- Prompt text sent on stdin. A resumed conversation already holds the
--- system prompt, so it is only sent with the first prompt.
---@param opts neostar.RunnerOpts
function M.stdin(opts)
  if opts.system_prompt and opts.system_prompt ~= "" and not opts.resume then
    return opts.system_prompt .. M.separator .. opts.prompt
  end
  return opts.prompt
end

--- Name reported to on_tool: the MCP tool's own name for neostar's tools,
--- otherwise Copilot's tool name.
local function tool_name(d)
  if d.mcpServerName == "neostar" and type(d.mcpToolName) == "string" then
    return d.mcpToolName
  end
  local name = tostring(d.toolName or "?")
  return (name:gsub("^neostar%-", ""))
end

--- JSONL event handler.
---@param opts neostar.RunnerOpts
function M.make_parser(opts)
  local had_text, need_sep = false, false
  local streamed = {} -- messageIds that produced deltas
  local function text(t)
    if t == nil or t == "" then
      return
    end
    if need_sep then
      need_sep = false
      if opts.on_text then
        opts.on_text("\n\n")
      end
    end
    had_text = true
    if opts.on_text then
      opts.on_text(t)
    end
  end
  return function(msg, state)
    local t, d = msg.type, type(msg.data) == "table" and msg.data or {}
    if t == "assistant.message_start" then
      need_sep = had_text
    elseif t == "assistant.message_delta" then
      if d.messageId then
        streamed[d.messageId] = true
      end
      text(d.deltaContent)
    elseif t == "assistant.message" then
      if type(d.content) == "string" and d.content ~= "" and not (d.messageId and streamed[d.messageId]) then
        text(d.content)
      end
    elseif t == "tool.execution_start" then
      if opts.on_tool then
        opts.on_tool(tool_name(d), type(d.arguments) == "table" and d.arguments or {})
      end
    elseif t == "session.mcp_servers_loaded" then
      local connected = false
      for _, s in ipairs(type(d.servers) == "table" and d.servers or {}) do
        if s.name == "neostar" and s.status == "connected" then
          connected = true
        end
      end
      if not connected then
        state.fail(M.no_mcp_message)
      end
    elseif t == "result" then
      state.session_id = msg.sessionId or state.session_id
      state.result = msg
    end
  end
end

--- Outcome of a run that exited on its own.
local function result(state, out)
  local proc = require("neostar.agent.proc")
  local r = state.result
  local code = r and r.exitCode or out.code
  if r and (code == 0 or code == nil) and out.code == 0 then
    return { ok = true }
  end
  return {
    ok = false,
    error = proc.stderr_tail(state) or ("Copilot exited with code " .. tostring(code)),
  }
end

--- Start a run. Returns a handle {stop(), session_id(), is_done()} or nil and an error.
---@param opts neostar.RunnerOpts
---@return table? handle, string? err
function M.start(opts)
  local transport = opts.transport or "auto"
  if transport == "sdk" or (transport == "auto" and vim.fn.executable(opts.helper or "neostar-copilot") == 1) then
    return require("neostar.agent.copilot_sdk").start(opts)
  end
  local exe = opts.cmd or "copilot"
  opts = vim.tbl_extend("force", opts, { cmd = exe })
  local server = vim.tbl_extend("force", opts.mcp_server or {}, { tools = { "*" } })
  local handle, err = require("neostar.agent.proc").start({
    exe = exe,
    missing = ("neostar: the agent executable `%s` was not found. Install GitHub Copilot CLI, or set `agent.copilot.cmd` in require('neostar').setup()."):format(
      exe
    ),
    mcp_config = { mcpServers = { neostar = server } },
    args = function(cfg_path)
      return M.build_args(opts, cfg_path)
    end,
    stdin = M.stdin(opts),
    cwd = opts.cwd,
    spawn = opts.spawn,
    on_message = M.make_parser(opts),
    result = result,
    on_done = opts.on_done,
  })
  if handle then
    handle.transport = "cli"
  end
  return handle, err
end

return M
