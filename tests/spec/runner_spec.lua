local util = require("helpers.util")
local claude = require("neostar.agent.claude")
local runner = require("neostar.agent.runner")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local FAKE = root .. "/helpers/fake_claude.py"
local FIX = root .. "/fixtures/agent/"

local log
local function use_plan(plan)
  log = vim.fn.tempname()
  vim.env.NEOSTAR_FAKE_CLAUDE_LOG = log
  vim.env.NEOSTAR_FAKE_CLAUDE_PLAN = vim.json.encode(plan)
end

local function runs()
  local out = {}
  for _, l in ipairs(vim.fn.readfile(log)) do
    table.insert(out, vim.json.decode(l))
  end
  return out
end

local function start(extra)
  local chunks, tools, done = {}, {}, nil
  local opts = vim.tbl_extend("force", {
    cmd = FAKE,
    cwd = root,
    prompt = "explain this",
    system_prompt = "be brief",
    mcp_server = { type = "http", url = "http://127.0.0.1:1/mcp", headers = { Authorization = "Bearer x" } },
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
  local h, err = claude.start(opts)
  return h, err, chunks, tools, function()
    util.wait(function()
      return done ~= nil
    end, 10000)
    return done
  end
end

describe("Claude runner", function()
  after_each(function()
    vim.env.NEOSTAR_FAKE_CLAUDE_PLAN = nil
    vim.env.NEOSTAR_FAKE_CLAUDE_LOG = nil
    require("neostar").setup({})
  end)

  it("builds a read-only command line", function()
    local args = claude.build_args({ cmd = "claude", model = "opus", resume = "abc", system_prompt = "sys" }, "/tmp/m.json")
    assert.same({
      "claude", "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
      "--mcp-config", "/tmp/m.json", "--strict-mcp-config",
      "--tools", "Read,Grep,Glob", "--allowedTools", "Read,Grep,Glob,mcp__neostar__*",
      "--append-system-prompt", "sys", "--model", "opus", "--resume", "abc",
    }, args)
    for _, a in ipairs(args) do
      assert.is_nil(a:match("Write") or a:match("Edit") or a:match("Bash"), a)
    end
  end)

  it("streams recorded text in chunks and captures the session id", function()
    use_plan({ { replay = FIX .. "explain.jsonl" } })
    local h, err, chunks, _, wait = start()
    assert.is_nil(err)
    local r = wait()
    assert.is_true(r.ok, r.error)
    assert.equals("43e6862d-ef5d-4522-a8c4-235376be6595", r.session_id)
    assert.equals("43e6862d-ef5d-4522-a8c4-235376be6595", h.session_id())
    assert.is_true(#chunks > 3)
    assert.matches("immutable binding named `x`", table.concat(chunks), 1, true)
  end)

  it("passes the prompt on stdin, the cwd, and a private MCP config file", function()
    use_plan({ { text = "hi" } })
    local _, _, _, _, wait = start({ cwd = root .. "/fixtures" })
    wait()
    local run = runs()[1]
    assert.equals("explain this", run.stdin)
    assert.equals(vim.fs.normalize(root .. "/fixtures"), vim.fs.normalize(run.cwd))
    local i = vim.fn.index(run.argv, "--mcp-config")
    local path = run.argv[i + 2]
    assert.is_false(vim.tbl_contains(run.argv, "explain this"))
    assert.equals(0, vim.fn.filereadable(path), "config file is removed after the run")
  end)

  it("reports tool calls and separates text blocks", function()
    use_plan({ { replay = FIX .. "tool_run.jsonl" } })
    local _, _, chunks, tools, wait = start()
    assert.is_true(wait().ok)
    assert.same({ { "echo", { text = "hi" } } }, tools, "plain tool names, without mcp__neostar__")
    local text = table.concat(chunks)
    assert.matches("\n\n", text, 1, true)
  end)

  it("continues a conversation with --resume", function()
    use_plan({ { replay = FIX .. "followup.jsonl" } })
    local _, _, chunks, _, wait = start({ resume = "43e6862d-ef5d-4522-a8c4-235376be6595" })
    assert.is_true(wait().ok)
    local argv = runs()[1].argv
    assert.equals("43e6862d-ef5d-4522-a8c4-235376be6595", argv[vim.fn.index(argv, "--resume") + 2])
    assert.matches("as I said before", table.concat(chunks), 1, true)
  end)

  it("stops a running agent", function()
    use_plan({ { text = "start" }, { sleep = 5 }, { text = "never" } })
    local h, _, chunks, _, wait = start()
    util.wait(function()
      return #chunks > 0
    end, 5000)
    h.stop()
    local r = wait()
    assert.is_false(r.ok)
    assert.is_true(r.stopped)
    assert.is_nil(table.concat(chunks):find("never", 1, true))
  end)

  it("reports a missing executable without starting anything", function()
    local h, err = claude.start({ cmd = "/nonexistent/claude", cwd = root, prompt = "x", mcp_server = {} })
    assert.is_nil(h)
    assert.matches("`/nonexistent/claude` was not found", err, 1, true)
    assert.matches("agent.claude.cmd", err, 1, true)
  end)

  it("reports the agent's error on failure", function()
    use_plan({ { stderr = "Invalid API key. Please run /login", exit = 1 } })
    local _, _, _, _, wait = start()
    local r = wait()
    assert.is_false(r.ok)
    assert.matches("Invalid API key", r.error, 1, true)

    use_plan({ { result = { is_error = true, subtype = "error_during_execution", result = "Network error" } } })
    _, _, _, _, wait = start()
    r = wait()
    assert.is_false(r.ok)
    assert.equals("Network error", r.error)
  end)

  it("uses the configured executable and model", function()
    use_plan({ { text = "x" } })
    require("neostar").setup({ agent = { claude = { cmd = FAKE, model = "opus" } } })
    local done
    local h = runner.start({
      cwd = root,
      prompt = "p",
      mcp_server = {},
      on_done = function(r)
        done = r
      end,
    })
    assert.is_not_nil(h)
    util.wait(function()
      return done ~= nil
    end, 10000)
    local argv = runs()[1].argv
    assert.equals("opus", argv[vim.fn.index(argv, "--model") + 2])
  end)

  it("rejects invalid agent options and keeps the defaults", function()
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(m)
      table.insert(msgs, m)
    end
    require("neostar").setup({ agent = { max_checks = 0 } })
    vim.notify = orig
    assert.matches("agent.max_checks", msgs[1], 1, true)
    assert.equals(10, require("neostar").options.agent.max_checks)
  end)
end)

describe("Agent options", function()
  local function setup_msgs(opts)
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(m)
      table.insert(msgs, m)
    end
    require("neostar").setup(opts)
    vim.notify = orig
    return msgs
  end

  after_each(function()
    require("neostar").setup({})
  end)

  it("defaults to automatic selection with per-agent executables and no models", function()
    local a = require("neostar").options.agent
    assert.equals("auto", a.runner)
    assert.same({ cmd = "claude" }, a.claude)
    assert.same({ cmd = "copilot", transport = "auto", helper = "neostar-copilot" }, a.copilot)
  end)

  it("accepts nested per-agent options and keeps the other defaults", function()
    local msgs = setup_msgs({ agent = { runner = "copilot", copilot = { model = "mai-code-2-flash" } } })
    assert.same({}, msgs)
    local a = require("neostar").options.agent
    assert.equals("copilot", a.runner)
    assert.same({
      cmd = "copilot", model = "mai-code-2-flash", transport = "auto", helper = "neostar-copilot",
    }, a.copilot)
    assert.same({ cmd = "claude" }, a.claude)
  end)

  it("rejects an unknown runner", function()
    local msgs = setup_msgs({ agent = { runner = "gemini" } })
    assert.matches("unknown runner `gemini`", msgs[1], 1, true)
    assert.equals("auto", require("neostar").options.agent.runner)
  end)

  it("names the replacement for the removed agent.cmd and agent.model", function()
    local msgs = setup_msgs({ agent = { cmd = "/opt/bin/claude" } })
    assert.matches("agent.cmd was replaced by agent.claude.cmd / agent.copilot.cmd", msgs[1], 1, true)
    assert.is_nil(require("neostar").options.agent.cmd)
    assert.equals("claude", require("neostar").options.agent.claude.cmd)

    msgs = setup_msgs({ agent = { model = "opus" } })
    assert.matches("agent.model was replaced by agent.claude.model / agent.copilot.model", msgs[1], 1, true)
    assert.is_nil(require("neostar").options.agent.model)
  end)

  it("rejects a non-string executable", function()
    local msgs = setup_msgs({ agent = { copilot = { cmd = 42 } } })
    assert.matches("agent.copilot.cmd", msgs[1], 1, true)
    assert.equals("copilot", require("neostar").options.agent.copilot.cmd)
  end)

  it("rejects invalid Copilot transport and helper options", function()
    local msgs = setup_msgs({ agent = { copilot = { transport = "http" } } })
    assert.matches("agent.copilot.transport", msgs[1], 1, true)
    msgs = setup_msgs({ agent = { copilot = { helper = false } } })
    assert.matches("agent.copilot.helper", msgs[1], 1, true)
  end)
end)

describe("Agent selection", function()
  local orig_exec
  local installed

  before_each(function()
    installed = {}
    orig_exec = vim.fn.executable
    vim.fn.executable = function(cmd)
      return installed[cmd] and 1 or 0
    end
  end)

  after_each(function()
    vim.fn.executable = orig_exec
  end)

  local function config(runner)
    return { runner = runner or "auto", claude = { cmd = "claude" }, copilot = { cmd = "copilot" } }
  end

  it("picks Claude Code when only claude is installed", function()
    installed = { claude = true }
    assert.equals("claude", runner.resolve(config()))
  end)

  it("picks Copilot CLI when only copilot is installed", function()
    installed = { copilot = true }
    assert.equals("copilot", runner.resolve(config()))
  end)

  it("prefers Claude Code when both are installed", function()
    installed = { claude = true, copilot = true }
    assert.equals("claude", runner.resolve(config()))
  end)

  it("uses a forced runner even when the other is installed", function()
    installed = { claude = true, copilot = true }
    assert.equals("copilot", runner.resolve(config("copilot")))
    assert.equals("claude", runner.resolve(config("auto"), "claude"), "a follow-up's runner wins")
  end)

  it("checks the configured executables, not the default names", function()
    installed = { ["/opt/copilot"] = true, claude = true }
    local c = config()
    c.claude.cmd = "/opt/claude"
    c.copilot.cmd = "/opt/copilot"
    assert.equals("copilot", runner.resolve(c))
  end)

  it("names both executables and options when neither is installed", function()
    local name, err = runner.resolve(config())
    assert.is_nil(name)
    assert.matches("neither `claude` nor `copilot` is on PATH", err, 1, true)
    assert.matches("agent.claude.cmd", err, 1, true)
    assert.matches("agent.copilot.cmd", err, 1, true)
    local h, err2 = runner.start({ cwd = root, prompt = "p", mcp_server = {} }, config())
    assert.is_nil(h)
    assert.equals(err, err2)
  end)

  it("reports the runner it started, with that runner's executable and model", function()
    vim.fn.executable = orig_exec
    local spawned
    local c = config("copilot")
    c.copilot = { cmd = "/opt/copilot", model = "m1", transport = "cli" }
    local h, err, name = runner.start({
      cwd = root,
      prompt = "p",
      mcp_server = {},
      spawn = function(argv, _, on_exit)
        spawned = argv
        vim.schedule(function()
          on_exit({ code = 0 })
        end)
        return { kill = function() end }
      end,
    }, c)
    assert.is_nil(err)
    assert.equals("copilot", name)
    assert.equals("copilot", h.runner)
    assert.equals("/opt/copilot", spawned[1])
    assert.equals("m1", spawned[vim.fn.index(spawned, "--model") + 2])
  end)
end)
