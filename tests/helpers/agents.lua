--- The fake agents, so feature specs can run once per runner.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local M = {}

---@class tests.Agent
---@field name string runner name
---@field fake string fake executable
---@field plan_var string
---@field log_var string
---@field resume_id fun(argv: string[]): string? session id passed to resume

---@type tests.Agent[]
M.list = {
  {
    name = "claude",
    fake = root .. "/fake_claude.py",
    plan_var = "NEOSTAR_FAKE_CLAUDE_PLAN",
    log_var = "NEOSTAR_FAKE_CLAUDE_LOG",
    resume_id = function(argv)
      local i = vim.fn.index(argv, "--resume")
      return i >= 0 and argv[i + 2] or nil
    end,
  },
  {
    name = "copilot",
    fake = root .. "/fake_copilot.py",
    plan_var = "NEOSTAR_FAKE_COPILOT_PLAN",
    log_var = "NEOSTAR_FAKE_COPILOT_LOG",
    resume_id = function(argv)
      for _, a in ipairs(argv) do
        local id = a:match("^%-%-resume=(.+)$")
        if id then
          return id
        end
      end
    end,
  },
}

---@param name string
---@return tests.Agent
function M.get(name)
  for _, a in ipairs(M.list) do
    if a.name == name then
      return a
    end
  end
  error("no fake agent " .. name)
end

--- Agent options that select this fake, merged with `extra`.
---@param a tests.Agent
---@param extra? table
function M.options(a, extra)
  return vim.tbl_deep_extend("force", {
    runner = a.name,
    copilot = { transport = "cli" },
    [a.name] = { cmd = a.fake, transport = a.name == "copilot" and "cli" or nil },
  }, extra or {})
end

--- Give the fake a plan; returns the log path.
---@param a tests.Agent
---@param plan table
function M.use_plan(a, plan)
  local log = vim.fn.tempname()
  vim.env[a.log_var] = log
  vim.env[a.plan_var] = vim.json.encode(plan)
  return log
end

--- Runs recorded by a fake ({argv, cwd, stdin} each).
---@param log string
function M.runs(log)
  local out = {}
  if vim.fn.filereadable(log) == 1 then
    for _, l in ipairs(vim.fn.readfile(log)) do
      table.insert(out, vim.json.decode(l))
    end
  end
  return out
end

--- Forget all fake plans and logs.
function M.clear()
  for _, a in ipairs(M.list) do
    vim.env[a.plan_var] = nil
    vim.env[a.log_var] = nil
  end
end

return M
