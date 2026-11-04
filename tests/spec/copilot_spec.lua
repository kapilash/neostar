local util = require("helpers.util")
local copilot = require("neostar.agent.copilot")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local FIX = root .. "/fixtures/agent/"
local FAKE = root .. "/helpers/fake_copilot.py"

--- A vim.system stand-in that prints `lines` on stdout, `stderr` on stderr,
--- then exits with `code`. Records the argv, options and the config file.
local function fake_spawn(lines, code, stderr, keep_running)
  local rec = {}
  local spawn = function(argv, o, on_exit)
    rec.argv, rec.opts = argv, o
    local i = vim.fn.index(argv, "--additional-mcp-config")
    if i >= 0 then
      local path = argv[i + 2]:sub(2)
      rec.cfg_path = path
      rec.cfg = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
      rec.cfg_mode = vim.uv.fs_stat(path).mode % 512
    end
    local killed = false
    local function exit(c)
      on_exit({ code = c, signal = 0 })
    end
    vim.schedule(function()
      for _, l in ipairs(lines) do
        if killed then
          break
        end
        o.stdout(nil, l .. "\n")
      end
      if stderr then
        o.stderr(nil, stderr)
      end
      if not keep_running and not killed then
        exit(code or 0)
      end
    end)
    return {
      kill = function()
        if not killed then
          killed = true
          rec.killed = true
          vim.schedule(function()
            exit(143)
          end)
        end
      end,
    }
  end
  return spawn, rec
end

local function fixture(name)
  return vim.fn.readfile(FIX .. name)
end

local function start(spawn, extra)
  local chunks, tools, done = {}, {}, nil
  local opts = vim.tbl_extend("force", {
    cmd = "copilot",
    transport = "cli",
    cwd = root,
    prompt = "explain this",
    system_prompt = "be brief",
    mcp_server = { type = "http", url = "http://127.0.0.1:1/mcp", headers = { Authorization = "Bearer x" } },
    spawn = spawn,
    on_text = function(t)
      table.insert(chunks, t)
    end,
    on_tool = function(name, input)
      table.insert(tools, { name, input })
    end,
    on_done = function(r)
      done = r
    end,
  }, extra or {})
  local h, err = copilot.start(opts)
  return h,
    err,
    chunks,
    tools,
    function()
      util.wait(function()
        return done ~= nil
      end, 10000)
      return done
    end
end

local function ev(t, data, extra)
  return vim.json.encode(vim.tbl_extend("force", { type = t, data = data or vim.empty_dict() }, extra or {}))
end

local CONNECTED = ev("session.mcp_servers_loaded", { servers = { { name = "neostar", status = "connected" } } })

describe("Copilot runner", function()
  it("builds a read-only command line with the prompt kept out of argv", function()
    local args = copilot.build_args({ cmd = "copilot" }, "/tmp/m.json")
    assert.same({
      "copilot",
      "--output-format", "json", "--stream", "on",
      "--additional-mcp-config", "@/tmp/m.json",
      "--available-tools", "view", "glob", "rg", "neostar",
      "--allow-tool", "neostar",
      "--deny-tool", "shell", "--deny-tool", "write",
      "--no-ask-user", "--disable-builtin-mcps", "--disallow-temp-dir", "--no-color",
    }, args)
    for _, flag in ipairs({ "-p", "--prompt", "--model", "--no-auto-update", "--allow-all-tools", "--allow-all", "--yolo", "--no-custom-instructions", "--trust-folder" }) do
      assert.is_false(vim.tbl_contains(args, flag), flag)
    end
  end)

  it("adds --model only when set, and --resume=<id> for follow-ups", function()
    local args = copilot.build_args({ cmd = "/opt/copilot", model = "mai-code-2-flash", resume = "abc" }, "/m.json")
    assert.equals("/opt/copilot", args[1])
    assert.equals("mai-code-2-flash", args[vim.fn.index(args, "--model") + 2])
    assert.equals("--resume=abc", args[#args])
    assert.is_false(vim.tbl_contains(copilot.build_args({ cmd = "c", model = "" }, "/m.json"), "--model"))
  end)

  it("sends the system prompt and the task on stdin, and a private MCP config", function()
    local spawn, rec = fake_spawn(fixture("copilot_tool_run.jsonl"))
    local _, _, _, _, wait = start(spawn)
    assert.is_true(wait().ok)
    assert.equals("be brief" .. copilot.separator .. "explain this", rec.opts.stdin)
    assert.equals(vim.fs.normalize(root), vim.fs.normalize(rec.opts.cwd))
    assert.same({ "*" }, rec.cfg.mcpServers.neostar.tools)
    assert.equals("Bearer x", rec.cfg.mcpServers.neostar.headers.Authorization)
    assert.equals(tonumber("600", 8), rec.cfg_mode)
    assert.equals(0, vim.fn.filereadable(rec.cfg_path), "config file is removed after the run")
  end)

  it("sends only the question when resuming", function()
    local spawn, rec = fake_spawn(fixture("copilot_followup.jsonl"))
    local _, _, chunks, _, wait = start(spawn, { prompt = "and then?", resume = "00000000-0000-4000-8000-000000000001" })
    local r = wait()
    assert.is_true(r.ok)
    assert.equals("and then?", rec.opts.stdin)
    assert.equals("--resume=00000000-0000-4000-8000-000000000001", rec.argv[#rec.argv])
    assert.equals("neovim — PELICAN-42", table.concat(chunks))
  end)

  it("replays a recorded tool run: streamed text, plain tool names, session id", function()
    local spawn = fake_spawn(fixture("copilot_tool_run.jsonl"))
    local _, _, chunks, tools, wait = start(spawn)
    local r = wait()
    assert.is_true(r.ok)
    assert.equals("00000000-0000-4000-8000-000000000001", r.session_id)
    assert.same({ { "secret_word", { topic = "neovim" } } }, tools)
    local text = table.concat(chunks)
    assert.matches("**Secret word:** PELICAN-42", text, 1, true)
    assert.is_true(#chunks > 5, "text arrives in many chunks")
    assert.is_nil(text:find("Clarifying", 1, true), "reasoning is not shown")
  end)

  it("uses complete messages when the model does not stream, and separates messages", function()
    local spawn = fake_spawn({
      CONNECTED,
      ev("assistant.message_start", { messageId = "m1" }),
      ev("assistant.message", { messageId = "m1", content = "First." }),
      ev("tool.execution_start", { toolName = "view", arguments = { path = "A.fst" } }),
      ev("assistant.message_start", { messageId = "m2" }),
      ev("assistant.message_delta", { messageId = "m2", deltaContent = "Sec" }),
      ev("assistant.message_delta", { messageId = "m2", deltaContent = "ond." }),
      ev("assistant.message", { messageId = "m2", content = "Second." }),
      ev("some.future_event", { x = 1 }),
      vim.json.encode({ type = "result", sessionId = "s1", exitCode = 0 }),
    })
    local _, _, chunks, tools, wait = start(spawn)
    assert.is_true(wait().ok)
    assert.equals("First.\n\nSecond.", table.concat(chunks))
    assert.same({ { "view", { path = "A.fst" } } }, tools)
  end)

  it("stops with a clear error when neostar's MCP server is not connected", function()
    local spawn, rec = fake_spawn({
      ev("session.mcp_servers_loaded", { servers = { { name = "neostar", status = "disabled" } } }),
      ev("assistant.message_delta", { messageId = "m", deltaContent = "never shown" }),
    }, 0, nil, true)
    local _, _, chunks, _, wait = start(spawn)
    local r = wait()
    assert.is_false(r.ok)
    assert.equals(copilot.no_mcp_message, r.error)
    assert.matches("organization's Copilot policy", r.error, 1, true)
    assert.is_true(rec.killed)
    assert.same({}, chunks)
  end)

  it("reports stderr when Copilot fails without a result", function()
    local spawn = fake_spawn({}, 1, 'Error: Model "nope" from --model flag is not available.\n')
    local _, _, _, _, wait = start(spawn)
    local r = wait()
    assert.is_false(r.ok)
    assert.matches('Model "nope" from --model flag is not available.', r.error, 1, true)

    spawn = fake_spawn({ CONNECTED }, 2)
    _, _, _, _, wait = start(spawn)
    r = wait()
    assert.is_false(r.ok)
    assert.equals("Copilot exited with code 2", r.error)

    spawn = fake_spawn({ CONNECTED, vim.json.encode({ type = "result", sessionId = "s", exitCode = 1 }) }, 1, "auth failed\n")
    _, _, _, _, wait = start(spawn)
    r = wait()
    assert.is_false(r.ok)
    assert.equals("auth failed", r.error)
  end)

  it("stops a running agent", function()
    local spawn, rec = fake_spawn({ CONNECTED, ev("assistant.message_delta", { messageId = "m", deltaContent = "start" }) }, 0, nil, true)
    local h, _, chunks, _, wait = start(spawn)
    util.wait(function()
      return #chunks > 0
    end, 5000)
    h.stop()
    local r = wait()
    assert.is_false(r.ok)
    assert.is_true(r.stopped)
    assert.is_true(rec.killed)
  end)

  it("talks to neostar's real MCP server: handshake, then a tool call on the buffer", function()
    local mcp = require("neostar.agent.mcp")
    local tools = require("neostar.agent.tools")
    local b = util.open_fixture("TypeErr.fst")
    local s = util.attach_fake(b, "typeerr")
    util.wait(function()
      return util.idle(s) and #s:diagnostics() > 0
    end)
    local seen = {}
    local ro = tools.read_only()
    local inner = ro.fstar_diagnostics.handler
    ro.fstar_diagnostics.handler = function(args, ctx, respond)
      return inner(args, ctx, function(text, is_error)
        table.insert(seen, text)
        respond(text, is_error)
      end)
    end
    local token, server = mcp.register({ bufnr = b, tools = ro })
    local log = vim.fn.tempname()
    vim.env.NEOSTAR_FAKE_COPILOT_LOG = log
    vim.env.NEOSTAR_FAKE_COPILOT_PLAN = vim.json.encode({ { call = "fstar_diagnostics" }, { text = "It fails." } })
    local _, err, chunks, tool_calls, wait = start(nil, { cmd = FAKE, mcp_server = server })
    assert.is_nil(err)
    local r = wait()
    vim.env.NEOSTAR_FAKE_COPILOT_PLAN, vim.env.NEOSTAR_FAKE_COPILOT_LOG = nil, nil
    mcp.revoke(token)
    assert.is_true(r.ok, r.error)
    assert.same({ { "fstar_diagnostics", {} } }, tool_calls)
    assert.equals(1, #seen, "neostar served the diagnostics call")
    assert.matches(vim.split(s:diagnostics()[1].message, "\n")[1], seen[1], 1, true)
    assert.equals("It fails.", table.concat(chunks))
    local run = vim.json.decode(vim.fn.readfile(log)[1])
    assert.equals("be brief" .. copilot.separator .. "explain this", run.stdin)
    assert.is_true(vim.tbl_contains(run.argv, "--disable-builtin-mcps"))
  end)

  it("reports a missing executable without starting anything", function()
    local h, err = copilot.start({ cmd = "/nonexistent/copilot", cwd = root, prompt = "x", mcp_server = {} })
    assert.is_nil(h)
    assert.matches("`/nonexistent/copilot` was not found", err, 1, true)
    assert.matches("agent.copilot.cmd", err, 1, true)
  end)
end)
