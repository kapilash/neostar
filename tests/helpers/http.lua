--- Tiny blocking HTTP/1.1 client for tests (one request per connection).

local uv = vim.uv or vim.loop

local M = {}

--- Send a raw request string; returns status, headers, body.
---@param port integer
---@param raw string
---@param timeout_ms? integer
function M.raw(port, raw, timeout_ms)
  local tcp = uv.new_tcp()
  local data, done, err = "", false, nil
  tcp:connect("127.0.0.1", port, function(e)
    if e then
      err, done = e, true
      return
    end
    tcp:read_start(function(e2, chunk)
      if e2 or not chunk then
        done = true
        return
      end
      data = data .. chunk
      local head_end = data:find("\r\n\r\n", 1, true)
      if head_end then
        local len = tonumber(data:sub(1, head_end):lower():match("content%-length:%s*(%d+)") or "0")
        if #data >= head_end + 3 + len then
          done = true
        end
      end
    end)
    tcp:write(raw)
  end)
  vim.wait(timeout_ms or 3000, function()
    return done
  end, 5)
  if not tcp:is_closing() then
    tcp:close()
  end
  assert(not err, err)
  assert(done, "HTTP request timed out")
  local head_end = data:find("\r\n\r\n", 1, true)
  local head, body = data:sub(1, head_end - 1), data:sub(head_end + 4)
  local status = tonumber(head:match("^HTTP/1%.1 (%d+)"))
  return status, head, body
end

--- POST a JSON value to /mcp; returns status and decoded body (or raw body).
---@param port integer
---@param token string?
---@param value any table (encoded) or string (sent as is)
function M.post(port, token, value)
  local body = type(value) == "string" and value or vim.json.encode(value)
  local lines = {
    "POST /mcp HTTP/1.1",
    "Host: 127.0.0.1",
    "Content-Type: application/json",
    "Accept: application/json, text/event-stream",
    "Content-Length: " .. #body,
  }
  if token then
    table.insert(lines, "Authorization: Bearer " .. token)
  end
  local status, _, resp = M.raw(port, table.concat(lines, "\r\n") .. "\r\n\r\n" .. body)
  local ok, decoded = pcall(vim.json.decode, resp)
  return status, ok and decoded or resp
end

--- Call an MCP tool; returns the result table (content, isError) or the error.
function M.call_tool(port, token, name, args, id)
  local status, resp = M.post(port, token, {
    jsonrpc = "2.0",
    id = id or 1,
    method = "tools/call",
    params = { name = name, arguments = args or {} },
  })
  assert(status == 200, "tools/call HTTP " .. tostring(status))
  return resp.result, resp.error
end

--- Text of a tool result.
function M.text(result)
  return result and result.content and result.content[1] and result.content[1].text
end

return M
