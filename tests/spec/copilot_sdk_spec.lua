local util = require("helpers.util")
local sdk = require("neostar.agent.copilot_sdk")
local copilot = require("neostar.agent.copilot")
local original_log = vim.env.NEOSTAR_SDK_TEST_LOG

local function fake_helper()
  local connections = {}
  local function spawn(argv, opts, on_exit)
    local connection = { argv = argv, messages = {} }
    connections[#connections + 1] = connection
    function connection.emit(message)
      opts.stdout(nil, vim.json.encode(message) .. "\n")
    end
    function connection.exit(error)
      if error then opts.stderr(nil, error) end
      on_exit({ code = error and 1 or 0 })
    end
    local process = {
      write = function(_, text)
        if not text then
          connection.eof = true
          connection.exit()
          return
        end
        local message = vim.json.decode(text)
        connection.messages[#connection.messages + 1] = message
        if message.op == "shutdown" then connection.exit() end
      end,
      kill = function() connection.exit() end,
    }
    vim.schedule(function() connection.emit({ type = "ready", protocol = 1 }) end)
    return process
  end
  return spawn, connections
end

local function start(spawn, extra)
  local texts, results = {}, {}
  local handle, err = copilot.start(vim.tbl_extend("force", {
    cmd = vim.v.progpath,
    helper = vim.v.progpath,
    transport = "sdk",
    spawn = spawn,
    cwd = vim.fn.getcwd(),
    prompt = "first question",
    system_prompt = "read only",
    mcp_server = { type = "http", url = "http://127.0.0.1:1", headers = { Authorization = "first" } },
    on_text = function(text) texts[#texts + 1] = text end,
    on_done = function(result) results[#results + 1] = result end,
  }, extra or {}))
  assert.is_nil(err)
  return handle, texts, results
end

describe("Persistent Copilot SDK transport", function()
  after_each(function()
    sdk.shutdown()
    vim.env.NEOSTAR_SDK_TEST_LOG = original_log
  end)

  it("reuses the runtime and resumes with the new turn's MCP credentials", function()
    local spawn, connections = fake_helper()
    local first, _, first_results = start(spawn)
    util.wait(function() return #connections[1].messages == 1 end)
    local connection = connections[1]
    local one = connection.messages[1]
    connection.emit({ type = "session", id = one.id, session_id = "conversation" })
    connection.emit({ type = "done", id = one.id, ok = true })
    util.wait(function() return first.is_done() end)
    assert.equals("conversation", first_results[1].session_id)
    local second, _, results = start(spawn, {
      resume = first.session_id(),
      prompt = "follow up",
      mcp_server = { type = "http", url = "http://127.0.0.1:2", headers = { Authorization = "second" } },
    })
    assert.equals(1, #connections)
    local two = connection.messages[2]
    assert.equals("conversation", two.resume)
    assert.equals("second", two.mcp_server.headers.Authorization)
    assert.equals("follow up", two.prompt)
    assert.is_false(vim.tbl_contains(connection.argv, "first question"))
    assert.is_nil(table.concat(connection.argv):find("Authorization", 1, true))
    connection.emit({ type = "session", id = two.id, session_id = "conversation" })
    connection.emit({ type = "done", id = two.id, ok = true })
    util.wait(function() return second.is_done() end)
    assert.is_true(results[1].ok)
  end)

  it("round-trips through the compiled Rust helper and actual SDK without inference", function()
    local helper = vim.env.NEOSTAR_TEST_SDK_HELPER
    if not helper then
      pending("set NEOSTAR_TEST_SDK_HELPER to the compiled native helper")
      return
    end
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
    vim.env.NEOSTAR_SDK_TEST_LOG = vim.fn.has("win32") == 1 and "NUL" or "/dev/null"
    local texts, results = {}, {}
    local function run(resume, token)
      local handle, err = copilot.start({
        transport = "sdk", helper = helper, cmd = root .. "/tools/copilot/tests/fake_runtime.py",
        cwd = root, prompt = "explain", system_prompt = "read only", resume = resume,
        keep_session = true,
        mcp_server = { type = "http", url = "http://127.0.0.1:1", headers = { Authorization = token } },
        on_text = function(text) texts[#texts + 1] = text end,
        on_done = function(result) results[#results + 1] = result end,
      })
      assert.is_nil(err)
      util.wait(handle.is_done, 10000)
      assert.is_true(results[#results].ok, results[#results].error)
      return handle
    end
    local first = run(nil, "first")
    local second = run(first.session_id(), "second")
    assert.equals(first.session_id(), second.session_id())
    assert.same({ "first", "second" }, texts)
    second.release()
  end)

  it("cancels just its request and ignores late events without interrupting another buffer", function()
    local spawn, connections = fake_helper()
    local first, first_texts, first_results = start(spawn, { bufnr = 41, prompt = "first" })
    local second, second_texts, second_results = start(spawn, { bufnr = 42, prompt = "second" })
    util.wait(function() return #connections[1].messages == 2 end)
    local connection = connections[1]
    local one, two
    for _, message in ipairs(connection.messages) do
      if message.prompt == "first" then one = message.id else two = message.id end
    end
    first.stop()
    assert.is_true(first_results[1].stopped)
    assert.equals(one, connection.messages[3].id)
    assert.equals("cancel", connection.messages[3].op)
    for _, id in ipairs({ one, two }) do
      connection.emit({ type = "event", id = id, event = {
        type = "assistant.message_delta", data = { messageId = "answer", deltaContent = "answer" },
      } })
      connection.emit({ type = "done", id = id, ok = true })
    end
    util.wait(function() return second.is_done() end)
    assert.same({}, first_texts)
    assert.equals(1, #first_results)
    assert.same({ "answer" }, second_texts)
    assert.is_true(second_results[1].ok)
    sdk.detach(41)
    assert.is_nil(connection.eof)
    sdk.detach(42)
    assert.is_true(connection.eof)
  end)

  it("does not submit a request that was stopped before the runtime became ready", function()
    local spawn, connections = fake_helper()
    local handle = start(spawn)
    handle.stop()
    vim.wait(20, function() return false end)
    assert.equals(1, #connections[1].messages)
    assert.equals("cancel", connections[1].messages[1].op)
  end)

  it("reports helper death once, without retrying through another transport", function()
    local spawn, connections = fake_helper()
    local handle, _, results = start(spawn)
    util.wait(function() return #connections[1].messages == 1 end)
    connections[1].exit("Copilot authentication failed")
    util.wait(function() return handle.is_done() end)
    assert.equals(1, #connections)
    assert.equals(1, #results)
    assert.is_false(results[1].ok)
    assert.matches("authentication failed", results[1].error, 1, true)
  end)

  it("rejects an incompatible helper protocol", function()
    local spawn, connections = fake_helper()
    local handle, _, results = start(spawn)
    connections[1].emit({ type = "ready", protocol = 99 })
    util.wait(function() return handle.is_done() end)
    assert.is_false(results[1].ok)
    assert.matches("Incompatible", results[1].error, 1, true)
  end)

  it("requires the helper in sdk mode rather than silently falling back", function()
    local handle, err = copilot.start({ transport = "sdk", helper = "/nonexistent/neostar-copilot" })
    assert.is_nil(handle)
    assert.matches("helper not found", err, 1, true)
  end)

  it("automatically uses CLI mode only when the helper is absent", function()
    local args
    local handle, err = copilot.start({
      cmd = vim.v.progpath,
      helper = "/nonexistent/neostar-copilot",
      transport = "auto",
      prompt = "hello",
      spawn = function(argv, _, on_exit)
        args = argv
        vim.schedule(function() on_exit({ code = 0 }) end)
        return { kill = function() end }
      end,
    })
    assert.is_nil(err)
    assert.equals("cli", handle.transport)
    assert.is_true(vim.tbl_contains(args, "--output-format"))
    util.wait(function() return handle.is_done() end)
  end)
end)
