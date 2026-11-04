--- A minimal MCP server (Streamable HTTP transport, JSON responses only) that
--- runs inside Neovim on 127.0.0.1. Each agent run gets its own bearer token,
--- which selects the context (buffer, request kind, tool set) of its calls.

local uv = vim.uv or vim.loop

local M = {}

M.protocol_version = "2025-06-18"

---@class neostar.McpTool
---@field name string
---@field description string
---@field inputSchema table
---@field handler fun(args: table, ctx: table, respond: fun(text: string, is_error?: boolean))

---@class neostar.McpContext
---@field tools table<string, neostar.McpTool>

local server = nil ---@type { tcp: uv.uv_tcp_t, port: integer }?
local contexts = {} ---@type table<string, neostar.McpContext>

local function random_hex(nbytes)
  local f = io.open("/dev/urandom", "rb")
  local bytes
  if f then
    bytes = f:read(nbytes)
    f:close()
  end
  if not bytes or #bytes < nbytes then
    local t = {}
    for i = 1, nbytes do
      t[i] = string.char(math.random(0, 255))
    end
    bytes = table.concat(t)
  end
  return (bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end
M._random_hex = random_hex

--- Constant-time string comparison.
local function equal_ct(a, b)
  if #a ~= #b then
    return false
  end
  local diff = 0
  for i = 1, #a do
    diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i)))
  end
  return diff == 0
end

--- Look up a context by token, comparing against every token in constant time.
local function find_context(token)
  if not token then
    return nil
  end
  local found = nil
  for t, ctx in pairs(contexts) do
    if equal_ct(t, token) then
      found = ctx
    end
  end
  return found
end

local STATUS_TEXT = {
  [200] = "OK",
  [202] = "Accepted",
  [400] = "Bad Request",
  [401] = "Unauthorized",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [413] = "Payload Too Large",
}

local function http_response(status, body, extra_headers)
  body = body or ""
  local lines = {
    string.format("HTTP/1.1 %d %s", status, STATUS_TEXT[status] or ""),
    "Content-Length: " .. #body,
    "Connection: keep-alive",
  }
  if #body > 0 then
    table.insert(lines, "Content-Type: application/json")
  end
  for k, v in pairs(extra_headers or {}) do
    table.insert(lines, k .. ": " .. v)
  end
  return table.concat(lines, "\r\n") .. "\r\n\r\n" .. body
end

local function rpc_result(id, result)
  return vim.json.encode({ jsonrpc = "2.0", id = id, result = result })
end

local function rpc_error(id, code, message)
  return vim.json.encode({ jsonrpc = "2.0", id = id or vim.NIL, error = { code = code, message = message } })
end

local function tool_list(ctx)
  local list = {}
  for name, tool in pairs(ctx.tools) do
    table.insert(list, { name = name, description = tool.description, inputSchema = tool.inputSchema })
  end
  table.sort(list, function(a, b)
    return a.name < b.name
  end)
  return list
end

--- Handle one JSON-RPC message. Calls reply(body_or_nil) exactly once:
--- nil means "no response body" (a notification).
---@param ctx neostar.McpContext
---@param msg table
---@param reply fun(body: string?)
function M._handle_rpc(ctx, msg, reply)
  local id, method = msg.id, msg.method
  if type(method) ~= "string" then
    reply(rpc_error(id, -32600, "Invalid request"))
    return
  end
  if id == nil then
    -- Notification (e.g. notifications/initialized): no response.
    reply(nil)
    return
  end
  if method == "initialize" then
    local params = msg.params or {}
    reply(rpc_result(id, {
      protocolVersion = type(params.protocolVersion) == "string" and params.protocolVersion or M.protocol_version,
      capabilities = { tools = { listChanged = false } },
      serverInfo = { name = "neostar", version = "0.2.0" },
    }))
  elseif method == "ping" then
    reply(rpc_result(id, vim.empty_dict()))
  elseif method == "tools/list" then
    reply(rpc_result(id, { tools = tool_list(ctx) }))
  elseif method == "tools/call" then
    local params = msg.params or {}
    local tool = ctx.tools[params.name]
    if not tool then
      reply(rpc_error(id, -32602, "Unknown tool: " .. tostring(params.name)))
      return
    end
    local done = false
    local function respond(text, is_error)
      if done then
        return
      end
      done = true
      reply(rpc_result(id, { content = { { type = "text", text = text } }, isError = is_error and true or false }))
    end
    local ok, err = pcall(tool.handler, type(params.arguments) == "table" and params.arguments or {}, ctx, respond)
    if not ok then
      respond("internal error: " .. tostring(err), true)
    end
  else
    reply(rpc_error(id, -32601, "Method not found: " .. method))
  end
end

--- Parse one HTTP request from the front of buf.
--- Returns req, rest  |  nil (need more data)  |  false, status (bad request).
local function parse_request(buf)
  local head_end = buf:find("\r\n\r\n", 1, true)
  if not head_end then
    if #buf > 65536 then
      return false, 413
    end
    return nil
  end
  local head = buf:sub(1, head_end - 1)
  local lines = vim.split(head, "\r\n", { plain = true })
  local method, path = lines[1]:match("^(%u+)%s+(%S+)%s+HTTP/1%.%d$")
  if not method then
    return false, 400
  end
  local headers = {}
  for i = 2, #lines do
    local k, v = lines[i]:match("^([^:]+):%s*(.-)%s*$")
    if k then
      headers[k:lower()] = v
    end
  end
  local len = tonumber(headers["content-length"] or "0")
  if not len or len < 0 then
    return false, 400
  end
  if len > 4 * 1024 * 1024 then
    return false, 413
  end
  local body_start = head_end + 4
  if #buf < body_start + len - 1 then
    return nil
  end
  local body = buf:sub(body_start, body_start + len - 1)
  return { method = method, path = path, headers = headers, body = body }, buf:sub(body_start + len)
end

---@param req table
---@param send fun(status: integer, body?: string)
local function handle_http(req, send)
  local auth = req.headers["authorization"]
  local token = auth and auth:match("^[Bb]earer%s+(%S+)$")
  local ctx = find_context(token)
  if not ctx then
    send(401, rpc_error(nil, -32001, "Unauthorized"))
    return
  end
  if req.path ~= "/mcp" then
    send(404)
    return
  end
  if req.method ~= "POST" then
    send(405)
    return
  end
  local ok, msg = pcall(vim.json.decode, req.body, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= "table" then
    send(400, rpc_error(nil, -32700, "Parse error"))
    return
  end
  if vim.islist(msg) then
    send(400, rpc_error(nil, -32600, "Batch requests are not supported"))
    return
  end
  M._handle_rpc(ctx, msg, function(body)
    if body then
      send(200, body)
    else
      send(202)
    end
  end)
end

local function on_connection(client)
  local buf = ""
  local busy = false
  local closed = false

  local function close()
    if not closed then
      closed = true
      if not client:is_closing() then
        client:close()
      end
    end
  end

  local process
  process = function()
    if busy or closed then
      return
    end
    local req, rest = parse_request(buf)
    if req == nil then
      return
    end
    if req == false then
      client:write(http_response(rest, ""), close)
      closed = true
      return
    end
    buf = rest
    busy = true
    handle_http(req, function(status, body)
      vim.schedule(function()
        if closed then
          return
        end
        client:write(http_response(status, body))
        busy = false
        process()
      end)
    end)
  end

  client:read_start(function(err, data)
    if err or not data then
      vim.schedule(close)
      return
    end
    vim.schedule(function()
      buf = buf .. data
      process()
    end)
  end)
end

--- Start the server if needed. Returns the port.
---@return integer
function M.ensure_started()
  if server then
    return server.port
  end
  local tcp = assert(uv.new_tcp())
  assert(tcp:bind("127.0.0.1", 0))
  assert(tcp:listen(64, function(err)
    if err then
      return
    end
    local client = uv.new_tcp()
    if client and tcp:accept(client) == 0 then
      on_connection(client)
    elseif client then
      client:close()
    end
  end))
  local addr = tcp:getsockname()
  server = { tcp = tcp, port = addr.port }
  return server.port
end

--- Register a context; returns its token and the MCP config entry for it.
---@param ctx neostar.McpContext
---@return string token, table server_config
function M.register(ctx)
  local port = M.ensure_started()
  local token = random_hex(16)
  contexts[token] = ctx
  return token,
    {
      type = "http",
      url = string.format("http://127.0.0.1:%d/mcp", port),
      headers = { Authorization = "Bearer " .. token },
    }
end

--- Revoke a token: later requests with it are rejected.
function M.revoke(token)
  contexts[token] = nil
end

function M.port()
  return server and server.port
end

function M.stop()
  contexts = {}
  if server then
    if not server.tcp:is_closing() then
      server.tcp:close()
    end
    server = nil
  end
end

return M
