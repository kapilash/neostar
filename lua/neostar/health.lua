local M = {}

function M.check()
  local health = vim.health
  local neostar = require("neostar")
  health.start("neostar")
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" or vim.bo.buftype ~= "" then
    file = vim.fn.getcwd() .. "/Health.fst"
  end
  local config, err = require("neostar.config").for_file(
    file,
    neostar.options.fstar_exe
  )
  if config then
    if vim.fn.executable(config.fstar_exe) == 1 then
      health.ok("F* executable: " .. vim.fn.exepath(config.fstar_exe))
    else
      health.error("F* executable missing: " .. config.fstar_exe)
    end
    if config.warning then health.warn(config.warning) end
  else
    health.error("F* configuration: " .. tostring(err))
  end
  for _, parser in ipairs({ "fstar", "pulse", "markdown" }) do
    if pcall(vim.treesitter.language.add, parser) then
      health.ok(parser .. " parser available")
    else
      health.warn(parser .. " parser missing; highlighting may be unavailable (agent windows still work)")
    end
    local docs = require("neostar.agent.docs")
    local dc = neostar.options.agent.docs
    if dc.enabled then
      health.info("Documentation index: " .. dc.index)
      local backend = docs.backend(dc)
      if backend == "server" then
        health.info("Documentation server: " .. dc.server .. " (" .. dc.python .. ")")
      else
        health.info("Documentation backend: in process (set agent.docs.server to use fstardoc_mcp.py instead)")
      end
      local problem = docs.problem(dc)
      if problem then
        health.warn(problem)
      else
        health.ok("Documentation retrieval prerequisites available")
      end
      if docs.last_error then health.warn("Last documentation error: " .. docs.last_error) end
    else
      health.info("Documentation retrieval: disabled (agent.docs.enabled)")
    end
  end
  local name, runner_error = require("neostar.agent.runner").resolve(neostar.options.agent)
  if not name then
    health.warn(runner_error)
    return
  end
  local agent = neostar.options.agent[name]
  if vim.fn.executable(agent.cmd) == 1 then
    health.ok("Agent: " .. name .. " (" .. vim.fn.exepath(agent.cmd) .. "); model: " .. (agent.model or "agent default"))
  else
    health.error("Agent executable missing: " .. agent.cmd)
  end
  if name == "copilot" then
    local helper = vim.fn.exepath(agent.helper)
    if agent.transport == "cli" then
      health.info("Copilot transport: CLI (one process per turn)")
    elseif helper ~= "" then
      health.ok("Copilot transport: persistent Rust SDK (" .. helper .. ")")
    elseif agent.transport == "sdk" then
      health.error("Copilot SDK helper missing; cargo install --locked --path tools/copilot")
    else
      health.info("Copilot transport: CLI fallback; install the optional Rust helper for a persistent runtime")
    end
    health.info("Authenticate with `copilot login`. Organization policy must allow MCP servers.")
  end
end

return M
