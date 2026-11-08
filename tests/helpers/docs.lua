local M = {}
M.names = { "find_by_contract", "find_by_type", "lookup", "used_by", "list_module", "modules" }

function M.config()
  return {
    enabled = true,
    python = vim.v.progpath,
    server = vim.fn.getcwd() .. "/tests/helpers/docs.lua",
    index = vim.fn.getcwd() .. "/tests/helpers/docs.lua",
  }
end

function M.fake(options)
  options = options or {}
  local connections = {}
  local function spawn(argv, opts, on_exit)
    local c = { argv = argv, messages = {} }
    connections[#connections + 1] = c
    function c.emit(msg)
      local line = vim.json.encode(msg) .. "\n"
      opts.stdout(nil, line:sub(1, 7))
      opts.stdout(nil, line:sub(8))
    end
    function c.reply(msg, result)
      c.emit({ jsonrpc = "2.0", id = msg.id, result = result })
    end
    function c.exit()
      if not c.exited then
        c.exited = true
        on_exit({ code = 0 })
      end
    end
    function c.raw(text)
      opts.stdout(nil, text)
    end
    local process = {
      write = function(_, text)
        if not text then
          c.exit()
          return
        end
        local msg = vim.json.decode(text)
        c.messages[#c.messages + 1] = msg
        if options.silent then return end
        if msg.method == "initialize" then
          c.reply(msg, { capabilities = { tools = {} }, protocolVersion = "2025-06-18" })
        elseif msg.method == "tools/list" then
          local tools = {}
          for _, name in ipairs(M.names) do
            tools[#tools + 1] = {
              name = name, description = name, inputSchema = { type = "object", properties = {} },
            }
          end
          tools[#tools + 1] = { name = "shell", description = "not approved", inputSchema = { type = "object" } }
          c.reply(msg, { tools = options.tools or tools })
        elseif msg.method == "tools/call" and not options.hold_calls then
          c.reply(msg, { content = { { type = "text", text = "indexed " .. msg.params.name } }, isError = false })
        end
      end,
      kill = function(_, signal)
        c.killed = signal
        c.exit()
      end,
    }
    return process
  end
  return spawn, connections
end

return M
