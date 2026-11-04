--- Claude Code headless runner: `claude -p` with stream-json output, a strict
--- MCP config pointing at neostar's server, and only read-only built-in tools.

local M = {}

M.builtin_tools = { "Read", "Grep", "Glob" }

---@class neostar.RunnerOpts
---@field cmd string executable
---@field cwd string
---@field prompt string
---@field system_prompt? string
---@field mcp_server table MCP config entry for neostar (url, headers)
---@field model? string
---@field resume? string session id to continue
---@field on_text? fun(chunk: string)
---@field on_tool? fun(name: string, input: table) plain tool name (`check_proof`, `Read`)
---@field on_done? fun(res: {ok: boolean, error?: string, stopped?: boolean, session_id?: string})
---@field spawn? function vim.system replacement (tests)

--- Command line for a run (without the prompt, which goes to stdin).
---@param opts neostar.RunnerOpts
---@param mcp_config_path string
function M.build_args(opts, mcp_config_path)
  local allowed = vim.deepcopy(M.builtin_tools)
  table.insert(allowed, "mcp__neostar__*")
  local args = {
    opts.cmd,
    "-p",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--mcp-config",
    mcp_config_path,
    "--strict-mcp-config",
    "--tools",
    table.concat(M.builtin_tools, ","),
    "--allowedTools",
    table.concat(allowed, ","),
  }
  if opts.system_prompt and opts.system_prompt ~= "" then
    vim.list_extend(args, { "--append-system-prompt", opts.system_prompt })
  end
  if opts.model and opts.model ~= "" then
    vim.list_extend(args, { "--model", opts.model })
  end
  if opts.resume then
    vim.list_extend(args, { "--resume", opts.resume })
  end
  return args
end

--- MCP tool names reach the runner callbacks without Claude's server prefix.
---@param name string
function M.plain_tool_name(name)
  return (tostring(name):gsub("^mcp__neostar__", ""))
end

--- Stream-json message handler.
local function make_parser(opts)
  local had_text = false
  return function(msg, state)
    local t = msg.type
    if t == "system" and msg.subtype == "init" then
      state.session_id = msg.session_id or state.session_id
    elseif t == "stream_event" and type(msg.event) == "table" then
      local ev = msg.event
      if ev.type == "content_block_start" and ev.content_block and ev.content_block.type == "text" then
        if had_text and opts.on_text then
          opts.on_text("\n\n")
        end
      elseif ev.type == "content_block_delta" and ev.delta and ev.delta.type == "text_delta" then
        if ev.delta.text and ev.delta.text ~= "" then
          had_text = true
          if opts.on_text then
            opts.on_text(ev.delta.text)
          end
        end
      end
    elseif t == "assistant" and msg.message and type(msg.message.content) == "table" then
      for _, c in ipairs(msg.message.content) do
        if c.type == "tool_use" and opts.on_tool then
          opts.on_tool(M.plain_tool_name(c.name), c.input or {})
        end
      end
    elseif t == "result" then
      state.session_id = msg.session_id or state.session_id
      state.result = msg
    end
  end
end

--- Outcome of a run that exited on its own.
local function result(state, out)
  local r = state.result
  if r and not r.is_error and (r.subtype == nil or r.subtype == "success") then
    return { ok = true }
  elseif r then
    local err = type(r.result) == "string" and r.result ~= "" and r.result
      or (r.subtype and ("agent run ended: " .. r.subtype))
      or "the agent reported an error"
    return { ok = false, error = err }
  end
  return {
    ok = false,
    error = require("neostar.agent.proc").stderr_tail(state) or ("the agent exited with code " .. tostring(out.code)),
  }
end

--- Start a run. Returns a handle {stop(), session_id(), is_done()} or nil and an error.
---@param opts neostar.RunnerOpts
---@return table? handle, string? err
function M.start(opts)
  local exe = opts.cmd or "claude"
  return require("neostar.agent.proc").start({
    exe = exe,
    missing = ("neostar: the agent executable `%s` was not found. Install Claude Code, or set `agent.claude.cmd` in require('neostar').setup()."):format(
      exe
    ),
    mcp_config = { mcpServers = { neostar = opts.mcp_server } },
    args = function(cfg_path)
      return M.build_args(opts, cfg_path)
    end,
    stdin = opts.prompt,
    cwd = opts.cwd,
    spawn = opts.spawn,
    on_message = make_parser(opts),
    result = result,
    on_done = opts.on_done,
  })
end

return M
