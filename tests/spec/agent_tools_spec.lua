local util = require("helpers.util")
local http = require("helpers.http")
local mcp = require("neostar.agent.mcp")
local tools = require("neostar.agent.tools")

local function open_clean(fixture, transcript, n)
  local b = util.open_fixture(fixture or "Clean.fst")
  local s, fake = util.attach_fake(b, transcript or "clean")
  util.wait(function()
    return util.idle(s) and #s.fragments == (n or 4)
  end)
  return b, s, fake
end

local function register(b)
  local token = mcp.register({ bufnr = b, tools = tools.read_only() })
  return mcp.port(), token
end

describe("fstar/agent-tools (read-only)", function()
  after_each(function()
    mcp.stop()
    util.cleanup()
  end)

  it("reads versioned unsaved source and tracks the selected code after an insertion", function()
    local b, s = open_clean()
    local context = require("neostar.agent.context")
    local revision = vim.api.nvim_buf_get_changedtick(b)
    local token = mcp.register({
      bufnr = b,
      selection = context.track(b, 7, 7),
      target = "len",
      request_revision = revision,
      tools = tools.read_only(),
    })
    s.debounce_ms = 10000
    vim.api.nvim_buf_set_lines(b, 0, 0, false, { "// unsaved editor context" })
    local response = http.call_tool(mcp.port(), token, "neostar_context", {})
    assert.is_false(response.isError)
    local snapshot = vim.json.decode(http.text(response))
    assert.equals(vim.api.nvim_buf_get_changedtick(b), snapshot.revision)
    assert.equals(revision, snapshot.request_revision)
    assert.is_true(snapshot.modified)
    assert.is_false(snapshot.checker.current)
    assert.matches("// unsaved editor context", snapshot.source, 1, true)
    assert.equals(9, snapshot.selection.start_line)
    assert.matches("let len", snapshot.selection.text, 1, true)
    assert.equals("len", snapshot.target.name)
    assert.equals(9, snapshot.target.start_line)
  end)

  it("waits for current unsaved text instead of querying the old checker during debounce", function()
    local b, s, fake = open_clean()
    s.debounce_ms = 10000
    fake.auto = false
    vim.api.nvim_buf_set_lines(b, -1, -1, false, { "// pending edit" })
    local status
    s:query("lookup", { symbol = "len" }, function(st) status = st end)
    assert.equals("lax", s.running)
    assert.is_nil(status)
    assert.equals(0, #fake:sent_of("lookup"))
    fake.auto = true
    fake:pump()
    util.wait(function() return status ~= nil end)
    assert.equals("success", status)
    assert.matches("// pending edit", fake:sent_of("full-buffer")[2].args.code, 1, true)
  end)

  it("does not return a lookup result after the buffer changed during the query", function()
    local b, s, fake = open_clean()
    fake.auto = false
    local status, response
    s:query("lookup", { symbol = "len" }, function(st, r) status, response = st, r end)
    vim.api.nvim_buf_set_lines(b, -1, -1, false, { "// newer revision" })
    fake.auto = true
    fake:pump()
    util.wait(function() return status ~= nil end)
    assert.equals("unavailable", status)
    assert.matches("buffer changed", response, 1, true)
  end)

  it("reports an unavailable checker as an error rather than a missing symbol", function()
    local b, s = open_clean()
    s.query = function(_, _, _, respond)
      respond("unavailable", "buffer changed while querying F*; retry")
    end
    local port, token = register(b)
    local result = http.call_tool(port, token, "fstar_lookup", { symbol = "len" })
    assert.is_true(result.isError)
    assert.matches("buffer changed", http.text(result), 1, true)
  end)

  it("does not silently select the next declaration after the selected code is deleted", function()
    local b = open_clean()
    local context = require("neostar.agent.context")
    local mark = context.track(b, 7, 7)
    vim.api.nvim_buf_set_lines(b, 7, 8, false, {})
    assert.is_nil(context.range(b, mark))
  end)

  it("looks up a symbol defined in the buffer through the buffer's checker", function()
    local b, _, fake = open_clean()
    local port, token = register(b)
    local result = http.call_tool(port, token, "fstar_lookup", { symbol = "len" })
    assert.is_false(result.isError)
    assert.matches("Clean.len : l: list a -> nat", http.text(result), 1, true)
    assert.matches("defined at Clean.fst:8", http.text(result), 1, true)
    assert.equals(1, #fake:sent_of("lookup"))
  end)

  it("looks up a library symbol with its definition file", function()
    local b = open_clean()
    local port, token = register(b)
    local text = http.text(http.call_tool(port, token, "fstar_lookup", { symbol = "List.Tot.length" }))
    assert.matches("FStar.List.Tot.Base.length", text, 1, true)
    assert.matches("defined at .*FStar%.List%.Tot%.Base%.fst", text)
  end)

  it("says not found for an unknown symbol without failing the call", function()
    local b = open_clean()
    local port, token = register(b)
    local result = http.call_tool(port, token, "fstar_lookup", { symbol = "nosuchthing" })
    assert.is_false(result.isError)
    assert.equals("not found: nosuchthing", http.text(result))
  end)

  it("evaluates a term", function()
    local b = open_clean()
    local port, token = register(b)
    local result = http.call_tool(port, token, "fstar_compute", { term = "double 21" })
    assert.is_false(result.isError)
    assert.matches("42", http.text(result), 1, true)
  end)

  it("reports diagnostics with ranges and declaration statuses", function()
    local b = util.open_fixture("TypeErr.fst")
    local s = util.attach_fake(b, "typeerr")
    util.wait(function()
      return util.idle(s) and #s:diagnostics() > 0
    end)
    local port, token = register(b)
    local text = http.text(http.call_tool(port, token, "fstar_diagnostics", {}))
    local d = s:diagnostics()[1]
    assert.matches(("error #%d at %d:%d"):format(d.code, d.lnum + 1, d.col + 1), text, 1, true)
    assert.matches(vim.split(d.message, "\n")[1], text, 1, true)
    assert.matches("failed", text, 1, true)
    assert.matches("lax", text, 1, true)
  end)

  it("answers 'checker busy' during a full verification without cancelling it", function()
    local b, s, fake = open_clean()
    fake.auto = false
    vim.cmd("NeostarVerify")
    util.wait(function()
      return s.running == "full"
    end)
    local port, token = register(b)
    local t0 = vim.uv.hrtime()
    local result = http.call_tool(port, token, "fstar_lookup", { symbol = "len" })
    assert.is_true((vim.uv.hrtime() - t0) / 1e6 < 1000)
    assert.is_true(result.isError)
    assert.matches("checker busy", http.text(result), 1, true)
    assert.equals("full", s.running)
    assert.equals(0, #fake:sent_of("cancel"))
    fake:pump()
    util.wait(function()
      return util.idle(s)
    end)
  end)
end)
