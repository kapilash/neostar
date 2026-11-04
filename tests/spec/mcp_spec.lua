local mcp = require("neostar.agent.mcp")
local http = require("helpers.http")

local function echo_tool(delay)
  return {
    description = "echo",
    inputSchema = { type = "object", properties = { text = { type = "string" } } },
    handler = function(args, _, respond)
      if delay then
        vim.defer_fn(function()
          respond("ECHO:" .. tostring(args.text))
        end, delay)
      else
        respond("ECHO:" .. tostring(args.text))
      end
    end,
  }
end

describe("MCP server", function()
  local token, cfg, port

  before_each(function()
    token, cfg = mcp.register({ tools = { echo = echo_tool(), slow = echo_tool(50) } })
    port = mcp.port()
  end)

  after_each(function()
    mcp.stop()
  end)

  it("binds to localhost and describes itself in the MCP config entry", function()
    assert.equals("http", cfg.type)
    assert.equals(string.format("http://127.0.0.1:%d/mcp", port), cfg.url)
    assert.equals("Bearer " .. token, cfg.headers.Authorization)
    assert.equals(32, #token)
  end)

  it("answers initialize, tools/list and tools/call with a valid token", function()
    local status, resp = http.post(port, token, {
      jsonrpc = "2.0",
      id = 1,
      method = "initialize",
      params = { protocolVersion = "2025-06-18", capabilities = {}, clientInfo = { name = "t", version = "1" } },
    })
    assert.equals(200, status)
    assert.equals("2025-06-18", resp.result.protocolVersion)
    assert.equals("neostar", resp.result.serverInfo.name)

    status = http.post(port, token, { jsonrpc = "2.0", method = "notifications/initialized" })
    assert.equals(202, status)

    local _, list = http.post(port, token, { jsonrpc = "2.0", id = 2, method = "tools/list" })
    local names = vim.tbl_map(function(t)
      return t.name
    end, list.result.tools)
    assert.same({ "echo", "slow" }, names)

    local result = http.call_tool(port, token, "echo", { text = "hi" })
    assert.equals("ECHO:hi", http.text(result))
    assert.is_false(result.isError)
  end)

  it("waits for asynchronous tool handlers", function()
    local result = http.call_tool(port, token, "slow", { text = "later" })
    assert.equals("ECHO:later", http.text(result))
  end)

  it("rejects missing and wrong tokens", function()
    local status = http.post(port, nil, { jsonrpc = "2.0", id = 1, method = "tools/list" })
    assert.equals(401, status)
    status = http.post(port, string.rep("0", 32), { jsonrpc = "2.0", id = 1, method = "tools/list" })
    assert.equals(401, status)
  end)

  it("reports unknown tools and methods as JSON-RPC errors", function()
    local _, err = http.call_tool(port, token, "nope", {})
    assert.equals(-32602, err.code)
    local _, resp = http.post(port, token, { jsonrpc = "2.0", id = 3, method = "resources/list" })
    assert.equals(-32601, resp.error.code)
  end)

  it("rejects malformed JSON and batches", function()
    local status, resp = http.post(port, token, "{not json")
    assert.equals(400, status)
    assert.equals(-32700, resp.error.code)
    status = http.post(port, token, { { jsonrpc = "2.0", id = 1, method = "ping" } })
    assert.equals(400, status)
  end)

  it("refuses GET with 405", function()
    local status = http.raw(port, "GET /mcp HTTP/1.1\r\nAuthorization: Bearer " .. token .. "\r\n\r\n")
    assert.equals(405, status)
  end)

  it("turns a handler error into an error result", function()
    local t2 = mcp.register({
      tools = {
        boom = {
          description = "x",
          inputSchema = { type = "object" },
          handler = function()
            error("kaboom")
          end,
        },
      },
    })
    local result = http.call_tool(port, t2, "boom", {})
    assert.is_true(result.isError)
    assert.matches("kaboom", http.text(result))
  end)
end)

describe("MCP token contexts", function()
  after_each(function()
    mcp.stop()
  end)

  it("gives each token only its own tools", function()
    local explain_token = mcp.register({ tools = { fstar_lookup = echo_tool() } })
    local prove_token = mcp.register({ tools = { fstar_lookup = echo_tool(), check_proof = echo_tool() } })
    local port = mcp.port()
    local _, err = http.call_tool(port, explain_token, "check_proof", { text = "x" })
    assert.equals(-32602, err.code)
    local result = http.call_tool(port, prove_token, "check_proof", { text = "x" })
    assert.equals("ECHO:x", http.text(result))
  end)

  it("rejects a revoked token", function()
    local t = mcp.register({ tools = { echo = echo_tool() } })
    local port = mcp.port()
    assert.equals("ECHO:a", http.text(http.call_tool(port, t, "echo", { text = "a" })))
    mcp.revoke(t)
    local status = http.post(port, t, { jsonrpc = "2.0", id = 1, method = "tools/list" })
    assert.equals(401, status)
  end)
end)
