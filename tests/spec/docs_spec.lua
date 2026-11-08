local util = require("helpers.util")
local helper = require("helpers.docs")
local docs = require("neostar.agent.docs")

local function prepare(config)
  local run, tools, err = {}
  docs.prepare(run, config or helper.config(), function(t, e) tools, err = t, e end)
  util.wait(function() return tools ~= nil end)
  return run, tools, err
end

local function call(tool, args)
  local text, err
  tool.handler(args or {}, {}, function(t, e) text, err = t, e end)
  util.wait(function() return text ~= nil end)
  return text, err
end

describe("documentation retrieval", function()
  after_each(function()
    require("neostar.agent.mcp").stop()
    docs.shutdown()
    docs._spawn = nil
    docs.timeout_ms = 10000
    docs.last_error = nil
    require("neostar").setup()
  end)

  it("normalizes setup paths and keeps missing optional docs from resetting agent options", function()
    local n = require("neostar")
    n.setup({ agent = { runner = "copilot", docs = { enabled = true, server = "missing.py", index = "missing.json" } } })
    assert.equals("copilot", n.options.agent.runner)
    assert.equals(vim.fn.getcwd() .. "/missing.py", n.options.agent.docs.server)
    local _, tools, err = prepare(n.options.agent.docs)
    assert.same({}, tools)
    assert.matches("server is not readable", err)
  end)

  it("does not start a process when disabled", function()
    docs._spawn = function() error("unexpected spawn") end
    local _, tools, err = prepare({ enabled = false })
    assert.same({}, tools)
    assert.is_nil(err)
  end)

  it("reports documentation health without an agent or starting a backend", function()
    local n = require("neostar")
    n.setup({ agent = { runner = "auto",
      claude = { cmd = "/missing-claude" }, copilot = { cmd = "/missing-copilot" },
      docs = helper.config(),
    } })
    docs._spawn = function() error("health must not spawn") end
    local old, messages = vim.health, {}
    vim.health = {}
    for _, level in ipairs({ "start", "info", "warn", "ok", "error" }) do
      vim.health[level] = function(text) messages[#messages + 1] = text end
    end
    local ok, err = pcall(require("neostar.health").check)
    vim.health = old
    assert.is_true(ok, err)
    assert.matches("Documentation index", table.concat(messages, "\n"))
    assert.matches("no agent found", table.concat(messages, "\n"))
  end)

  it("handshakes and proxies only the six approved tools, preserving text", function()
    local spawn, connections = helper.fake()
    docs._spawn = spawn
    local run, tools, err = prepare()
    assert.is_nil(err)
    assert.equals(6, vim.tbl_count(tools))
    assert.is_nil(tools.fstardoc_shell)
    assert.same({ vim.v.progpath, helper.config().server, "serve", "--index", helper.config().index }, connections[1].argv)
    assert.equals("notifications/initialized", connections[1].messages[2].method)
    assert.equals("indexed find_by_contract", call(tools.fstardoc_find_by_contract, { name = "slice" }))
    docs.release(run.docs)
    util.wait(function() return connections[1].exited end)
  end)

  it("shares the process and cancels only the released lease's pending requests", function()
    local spawn, cs = helper.fake({ hold_calls = true })
    docs._spawn = spawn
    local one, t1 = prepare()
    local two, t2 = prepare()
    assert.equals(1, #cs)
    local result1, result2
    t1.fstardoc_lookup.handler({}, {}, function(text) result1 = text end)
    t2.fstardoc_lookup.handler({}, {}, function(text) result2 = text end)
    docs.release(one.docs)
    assert.equals("documentation request ended", result1)
    assert.is_nil(cs[1].killed)
    local msg = cs[1].messages[#cs[1].messages]
    cs[1].reply(msg, { content = { { type = "text", text = "second" } } })
    util.wait(function() return result2 ~= nil end)
    assert.equals("second", result2)
    docs.release(two.docs)
    assert.equals(15, cs[1].killed)
  end)

  it("reloads without replacing tool handles and ignores old generation replies", function()
    local spawn, cs = helper.fake({ hold_calls = true })
    docs._spawn = spawn
    local _, tools = prepare()
    local first
    tools.fstardoc_lookup.handler({}, {}, function(t) first = t end)
    local old = cs[1].messages[#cs[1].messages]
    docs.reload()
    assert.matches("reloaded", first)
    local second
    tools.fstardoc_lookup.handler({}, {}, function(t) second = t end)
    util.wait(function() return #cs == 2 and #cs[2].messages == 4 end)
    cs[1].reply(old, { content = { { type = "text", text = "stale" } } })
    cs[2].reply(cs[2].messages[4], { content = { { type = "text", text = "replacement" } } })
    util.wait(function() return second ~= nil end)
    assert.equals("replacement", second)
  end)

  it("reports timeout without automatically restarting the failed backend", function()
    local spawn, cs = helper.fake({ hold_calls = true })
    docs._spawn, docs.timeout_ms = spawn, 30
    local _, tools = prepare()
    local text, err = call(tools.fstardoc_lookup)
    assert.is_true(err)
    assert.matches("timed out", text)
    local again = call(tools.fstardoc_lookup)
    assert.matches("timed out", again)
    assert.equals(1, #cs)
  end)

  it("fails preparation on missing tools or startup timeout", function()
    docs._spawn = helper.fake({ tools = {} })
    local _, tools, err = prepare()
    assert.same({}, tools)
    assert.matches("missing tool", err)
    docs.shutdown()
    docs._spawn = helper.fake({ silent = true })
    docs.timeout_ms = 30
    local _, _, timeout = prepare()
    assert.matches("timed out", timeout)
  end)

  it("preserves upstream errors and rejects unsupported content", function()
    local spawn, cs = helper.fake({ hold_calls = true })
    docs._spawn = spawn
    local _, tools = prepare()
    local result, failed
    tools.fstardoc_lookup.handler({}, {}, function(t, e) result, failed = t, e end)
    cs[1].reply(cs[1].messages[4], { content = { { type = "text", text = "ambiguous; definition_truncated" } }, isError = true })
    util.wait(function() return result ~= nil end)
    assert.is_true(failed)
    assert.equals("ambiguous; definition_truncated", result)
    result = nil
    tools.fstardoc_lookup.handler({}, {}, function(t, e) result, failed = t, e end)
    cs[1].reply(cs[1].messages[5], { content = { { type = "image", data = "x" } } })
    util.wait(function() return result ~= nil end)
    assert.is_true(failed)
    assert.matches("unsupported content", result)
  end)

  it("warns once on backend failure and leaves other MCP tools callable", function()
    local spawn, cs = helper.fake({ hold_calls = true })
    docs._spawn = spawn
    local messages, tools = {}
    local run = {}
    local window = {
      is_open = function() return true end,
      append = function(_, text) messages[#messages + 1] = text end,
    }
    docs.prepare_run(run, helper.config(), window, function(t) tools = t end)
    util.wait(function() return tools ~= nil end)
    local mcp = require("neostar.agent.mcp")
    local http = require("helpers.http")
    tools.checker = { description = "checker", inputSchema = { type = "object" },
      handler = function(_, _, respond) respond("still available") end }
    local token = mcp.register({ tools = tools })
    cs[1].exit()
    util.wait(function() return cs[1].exited and docs.last_error ~= nil end)
    for _ = 1, 2 do
      local result = http.call_tool(mcp.port(), token, "fstardoc_lookup", {})
      assert.is_true(result.isError)
    end
    assert.equals(1, #messages)
    assert.matches("Documentation warning", messages[1])
    assert.equals("still available", http.text(http.call_tool(mcp.port(), token, "checker", {})))
    mcp.revoke(token)
    mcp.stop()
  end)

  it("cancels one startup waiter without preventing another run from preparing", function()
    local spawn, cs = helper.fake({ silent = true })
    docs._spawn = spawn
    local one, two, ready1, ready2 = {}, {}
    docs.prepare(one, helper.config(), function() ready1 = true end)
    docs.prepare(two, helper.config(), function() ready2 = true end)
    docs.release(one.docs)
    cs[1].reply(cs[1].messages[1], { capabilities = { tools = {} } })
    util.wait(function() return #cs[1].messages == 3 end)
    local tools = {}
    for _, name in ipairs(helper.names) do
      tools[#tools + 1] = { name = name, description = name, inputSchema = { type = "object" } }
    end
    cs[1].reply(cs[1].messages[3], { tools = tools })
    util.wait(function() return ready2 end)
    assert.is_nil(ready1)
    assert.is_nil(cs[1].killed)
  end)

  it("fails pending calls on malformed output and process exit", function()
    for _, failure in ipairs({ "malformed", "exit" }) do
      local spawn, cs = helper.fake({ hold_calls = true })
      docs._spawn = spawn
      local _, tools = prepare()
      local result, err
      tools.fstardoc_lookup.handler({}, {}, function(t, e) result, err = t, e end)
      if failure == "malformed" then
        cs[1].raw("not-json\n")
      else
        cs[1].exit()
      end
      util.wait(function() return result ~= nil end)
      assert.is_true(err)
      docs.shutdown()
    end
  end)
end)
