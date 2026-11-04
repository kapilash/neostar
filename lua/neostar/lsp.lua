--- In-process LSP shim: Neovim's LSP client talks to a Lua "server" that
--- translates hover / definition / completion into F* `--ide` queries and
--- pushes F* issues as diagnostics. No external language server is spawned.

local M = {}

local SEVERITY = {
  [vim.diagnostic.severity.ERROR] = 1,
  [vim.diagnostic.severity.WARN] = 2,
  [vim.diagnostic.severity.INFO] = 3,
  [vim.diagnostic.severity.HINT] = 4,
}

-- symbols ----------------------------------------------------------------------

local function is_ident_byte(b)
  return b >= 0x80 -- any non-ASCII byte (UTF-8 identifiers like αβγ)
    or (b >= 48 and b <= 57) -- 0-9
    or (b >= 65 and b <= 90) -- A-Z
    or (b >= 97 and b <= 122) -- a-z
    or b == 95 -- _
    or b == 39 -- '
    or b == 46 -- .
end

--- Identifier (possibly module-qualified) around a byte column.
---@param line string
---@param col integer 0-based byte column
---@return string? symbol, integer start_col (0-based)
function M.symbol_at(line, col)
  local i = col + 1
  if i > #line or not is_ident_byte(line:byte(i)) then
    -- cursor just after an identifier
    if i > 1 and is_ident_byte(line:byte(i - 1)) then
      i = i - 1
    else
      return nil, col
    end
  end
  local s, e = i, i
  while s > 1 and is_ident_byte(line:byte(s - 1)) do
    s = s - 1
  end
  while e < #line and is_ident_byte(line:byte(e + 1)) do
    e = e + 1
  end
  local sym = line:sub(s, e)
  local lead = sym:match("^%.*")
  sym = sym:gsub("^%.+", ""):gsub("%.+$", "")
  if sym == "" then
    return nil, col
  end
  return sym, s - 1 + #lead
end

--- Partial identifier ending at a byte column (for completion).
---@return string partial, integer start_col (0-based)
function M.partial_before(line, col)
  local e = math.min(col, #line)
  local s = e
  while s > 0 and is_ident_byte(line:byte(s)) do
    s = s - 1
  end
  return line:sub(s + 1, e), s
end

-- helpers ----------------------------------------------------------------------

local function line_at(bufnr, row)
  return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
end

--- Resolve a file name reported by F* to an absolute path.
---@param session neostar.Session
function M.resolve_fname(session, fname)
  if type(fname) ~= "string" or fname == "" or fname:match("^<") then
    return nil
  end
  if session:is_own_file(fname) then
    return session.file
  end
  if fname:sub(1, 1) == "/" then
    return fname
  end
  return vim.fs.normalize(vim.fs.joinpath(session.cwd or session.root, fname))
end

--- Text of a 0-based line of a file (from its buffer if loaded).
local function file_line(path, row)
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
    return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  end
  local i = 0
  local ok, iter = pcall(io.lines, path)
  if not ok then
    return nil
  end
  for l in iter do
    if i == row then
      return l
    end
    i = i + 1
  end
  return nil
end

--- LSP range (utf-8 columns) in `path` for an F* range (character columns).
local function lsp_range(path, b, e)
  local tr = require("neostar.fstar.transport")
  local r1 = tr.to_buf_pos(b)
  local r2 = tr.to_buf_pos(e or b)
  local _, c1 = tr.to_buf_pos(b, file_line(path, r1))
  local _, c2 = tr.to_buf_pos(e or b, file_line(path, r2))
  return { start = { line = r1, character = c1 }, ["end"] = { line = r2, character = c2 } }
end

--- Markdown for a lookup response.
function M.hover_markdown(resp)
  local parts = {}
  local head = resp.name or "?"
  if resp.type and resp.type ~= "" then
    head = head .. " : " .. resp.type
  end
  table.insert(parts, "```fstar\n" .. head .. "\n```")
  if type(resp.documentation) == "string" and resp.documentation:match("%S") then
    table.insert(parts, vim.trim(resp.documentation))
  end
  return table.concat(parts, "\n\n")
end

-- request handlers ---------------------------------------------------------------

local handlers = {}

function handlers.initialize(_, _, cb)
  cb(nil, {
    capabilities = {
      positionEncoding = "utf-8",
      hoverProvider = true,
      definitionProvider = true,
      completionProvider = { triggerCharacters = { "." }, resolveProvider = false },
      textDocumentSync = { openClose = false, change = 0, save = false },
    },
    serverInfo = { name = "neostar" },
  })
end

function handlers.shutdown(_, _, cb)
  cb(nil, nil)
end

function handlers.lookup_at(session, params, cb)
  local row, col = params.position.line, params.position.character
  local text = line_at(session.bufnr, row)
  local sym = M.symbol_at(text, col)
  if not sym then
    cb(nil)
    return
  end
  local line, column = require("neostar.fstar.transport").to_fstar_pos(row, col, text)
  session:query("lookup", {
    context = "code",
    symbol = sym,
    ["requested-info"] = { "type", "documentation", "defined-at" },
    location = { filename = session.file, line = line, column = column },
  }, function(status, resp)
    if status ~= "success" or type(resp) ~= "table" then
      cb(nil)
    else
      cb(resp)
    end
  end)
end

handlers["textDocument/hover"] = function(session, params, cb)
  handlers.lookup_at(session, params, function(resp)
    if not resp then
      cb(nil, nil)
      return
    end
    cb(nil, { contents = { kind = "markdown", value = M.hover_markdown(resp) } })
  end)
end

handlers["textDocument/definition"] = function(session, params, cb)
  handlers.lookup_at(session, params, function(resp)
    local def = resp and resp["defined-at"]
    local path = def and M.resolve_fname(session, def.fname)
    if not path or not def.beg then
      cb(nil, nil)
      return
    end
    cb(nil, { { uri = vim.uri_from_fname(path), range = lsp_range(path, def.beg, def["end"]) } })
  end)
end

handlers["textDocument/completion"] = function(session, params, cb)
  local row, col = params.position.line, params.position.character
  local partial, start = M.partial_before(line_at(session.bufnr, row), col)
  if partial == "" then
    cb(nil, { isIncomplete = true, items = {} })
    return
  end
  session:query("autocomplete", { ["partial-symbol"] = partial, context = "code" }, function(status, resp)
    local items = {}
    if status == "success" and type(resp) == "table" then
      for _, c in ipairs(resp) do
        local annot, cand = c[2], c[3]
        if type(cand) == "string" and annot ~= "<search term>" then
          table.insert(items, {
            label = cand,
            detail = (annot ~= "" and annot) or nil,
            filterText = cand,
            textEdit = {
              newText = cand,
              range = {
                start = { line = row, character = start },
                ["end"] = { line = row, character = col },
              },
            },
          })
        end
      end
    end
    cb(nil, { isIncomplete = true, items = items })
  end)
end

-- the fake server --------------------------------------------------------------

--- Diagnostics in LSP form for a session.
---@param session neostar.Session
function M.lsp_diagnostics(session)
  local out = {}
  for _, d in ipairs(session:diagnostics()) do
    table.insert(out, {
      range = {
        start = { line = d.lnum, character = d.col },
        ["end"] = { line = d.end_lnum, character = d.end_col },
      },
      severity = SEVERITY[d.severity] or 3,
      message = d.message,
      code = d.code,
      source = "F*",
    })
  end
  return out
end

---@param session neostar.Session
local function make_cmd(session)
  return function(dispatchers)
    local closing = false
    local next_id = 0
    local publish_scheduled = false

    local function publish()
      if closing or not vim.api.nvim_buf_is_loaded(session.bufnr) then
        return
      end
      dispatchers.notification("textDocument/publishDiagnostics", {
        uri = vim.uri_from_bufnr(session.bufnr),
        diagnostics = M.lsp_diagnostics(session),
      })
    end

    session:subscribe(function(event)
      if event ~= "diagnostics" or publish_scheduled then
        return
      end
      publish_scheduled = true
      vim.defer_fn(function()
        publish_scheduled = false
        publish()
      end, 20)
    end)

    local rpc = {}
    function rpc.request(method, params, callback)
      next_id = next_id + 1
      local id = next_id
      local h = handlers[method]
      if not h then
        vim.schedule(function()
          callback({ code = -32601, message = "method not supported: " .. method }, nil)
        end)
        return true, id
      end
      vim.schedule(function()
        local ok, err = pcall(h, session, params, function(e, result)
          callback(e, result)
        end)
        if not ok then
          callback({ code = -32603, message = tostring(err) }, nil)
        end
      end)
      return true, id
    end
    function rpc.notify(method)
      if method == "exit" then
        closing = true
      elseif method == "initialized" then
        vim.schedule(publish)
      end
      return true
    end
    function rpc.is_closing()
      return closing
    end
    function rpc.terminate()
      closing = true
    end
    return rpc
  end
end

--- Start (or reuse) the shim client for a session's buffer.
---@param session neostar.Session
---@return integer? client_id
function M.attach(session)
  return vim.lsp.start({
    name = "neostar",
    cmd = make_cmd(session),
    root_dir = session.root,
  }, {
    bufnr = session.bufnr,
    -- One client per buffer: F* runs one process per file, so never share a
    -- client between buffers (attach is called once per session).
    reuse_client = function()
      return false
    end,
  })
end

M._handlers = handlers
return M
