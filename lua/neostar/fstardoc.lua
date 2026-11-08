--- In-process reader for an fstardoc retrieval index (the JSON written by
--- `fstardoc_mcp.py index`). It answers the same six queries as that
--- script's `serve` command, so agents can search library documentation with
--- no Python process, and the Telescope picker browses the same data.
---
--- Query behaviour mirrors fstardoc_mcp.py (index schema
--- "fstardoc-retrieval-index", version 1); keep the two in step.

local M = {}

M.SCHEMA, M.VERSION = "fstardoc-retrieval-index", 1
--- A definition can be a whole proof term, so lookup truncates it unless asked.
M.DEFINITION_PREVIEW = 600

-- Byte-wise ordering. Lua's `<` on strings follows the C locale's collation,
-- which may not be byte order; UTF-8 byte order is code point order, as in Python.
local function before(a, b)
  local n = math.min(#a, #b)
  for i = 1, n do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then
      return x < y
    end
  end
  return #a < #b
end
M._before = before

local function sort_strings(list)
  table.sort(list, before)
  return list
end

--- Python's `list[:n]`, including its meaning for a negative n.
local function take(list, n)
  local len = #list
  local stop = n < 0 and math.max(0, len + n) or math.min(len, n)
  local out = {}
  for i = 1, stop do
    out[i] = list[i]
  end
  return out
end

local function py_min(len, n)
  return math.min(len, n)
end

--- Python's repr of a str, enough for the messages below.
local function repr(s)
  return "'" .. tostring(s):gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

--- `int(args.get(key, default))`.
local function int_arg(args, key, default)
  local v = args[key]
  if v == nil then
    return default
  end
  local n = tonumber(v)
  if not n then
    error(("%s must be an integer, not %s"):format(key, vim.inspect(v)), 0)
  end
  return n < 0 and math.ceil(n) or math.floor(n)
end

local function truthy(v)
  return v ~= nil and v ~= false and v ~= 0 and v ~= "" and v ~= vim.NIL
end

local function str_arg(v)
  if not truthy(v) then
    return ""
  end
  return tostring(v)
end

function M.short(fqn)
  local parts = vim.split(fqn, ".", { plain = true })
  if #parts >= 2 and parts[#parts] == "t" then
    return parts[#parts - 1] .. ".t"
  end
  return parts[#parts]
end
local short = M.short

-- ------------------------------------------------------------- the index --

local Index = {}
Index.__index = Index

--- Build an Index from decoded JSON (nulls decoded as nil).
---@return table? index, string? err
function M.new(data)
  if type(data) ~= "table" or data.schema ~= M.SCHEMA or data.version ~= M.VERSION then
    local t = type(data) == "table" and data or {}
    return nil, ("unexpected index %s version %s (neostar reads %s version %d)"):format(
      vim.inspect(t.schema), vim.inspect(t.version), M.SCHEMA, M.VERSION)
  end
  if type(data.declarations) ~= "table" then
    return nil, "documentation index has no declarations"
  end
  local self = setmetatable({ decls = data.declarations, by_name = {}, mentioned_by = {} }, Index)
  for _, d in ipairs(self.decls) do
    d.pre, d.post, d.refs, d.args, d.res = d.pre or {}, d.post or {}, d.refs or {}, d.args or {}, d.res or {}
    self.by_name[d.name] = d
  end
  for _, d in ipairs(self.decls) do
    for _, r in ipairs(d.refs) do
      local users = self.mentioned_by[r]
      if not users then
        users = {}
        self.mentioned_by[r] = users
      end
      users[#users + 1] = d.name
    end
  end
  return self
end

--- Read and decode an index file.
---@return table? index, string? err
function M.read(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil, "documentation index is not readable: " .. path
  end
  local text = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok then
    return nil, "documentation index is not valid JSON: " .. path
  end
  return M.new(data)
end

local cache = {} ---@type table<string, {index: table, mtime: integer, size: integer}>

--- The index at `path`, read once and re-read when the file changes.
---@return table? index, string? err
function M.load(path)
  local st = vim.uv.fs_stat(path)
  if not st then
    cache[path] = nil
    return nil, "documentation index is not readable: " .. path
  end
  local mtime = st.mtime.sec * 1000000000 + st.mtime.nsec
  local hit = cache[path]
  if hit and hit.mtime == mtime and hit.size == st.size then
    return hit.index
  end
  local index, err = M.read(path)
  if not index then
    cache[path] = nil
    return nil, err
  end
  cache[path] = { index = index, mtime = mtime, size = st.size }
  return index
end

--- Forget loaded indexes; the next load reads the file again.
function M.clear()
  cache = {}
end

--- Accept a fully qualified name, or a short one if it is unambiguous.
---@return string? name, string? err
function Index:resolve(name)
  if self.by_name[name] then
    return name
  end
  local hits = {}
  for n in pairs(self.by_name) do
    if short(n) == name then
      hits[#hits + 1] = n
    end
  end
  if #hits == 1 then
    return hits[1]
  elseif #hits == 0 then
    return nil, ("No declaration is named %s."):format(repr(name))
  end
  return nil, ("%s is ambiguous; it could be %s."):format(repr(name), table.concat(take(sort_strings(hits), 8), ", "))
end

--- Module names, sorted.
function Index:module_names()
  local seen, out = {}, {}
  for _, d in ipairs(self.decls) do
    if not seen[d.module] then
      seen[d.module] = true
      out[#out + 1] = d.module
    end
  end
  return sort_strings(out)
end

-- ------------------------------------------------------------ type shapes --

local ALIAS = { nat = "int", pos = "int" }

function M.words(s)
  local out = {}
  s = s:gsub("[(){}%[%],]", " ")
  for w in s:gmatch("%S+") do
    w = w:gsub("^'", "")
    if w:match("^[a-z]$") then
      out[#out + 1] = "*"
    elseif w ~= "" then
      local parts = vim.split(w, ".", { plain = true })
      if #parts > 1 and parts[#parts] ~= "t" then
        w = parts[#parts]
      end
      out[#out + 1] = w
    end
  end
  return out
end

local function tok_eq(a, b, loose)
  if a == "*" or b == "*" or a == b then
    return true
  end
  return loose and (ALIAS[a] or a) == (ALIAS[b] or b)
end

local function part_match(qt, dt, loose)
  if #qt == 0 then
    return true
  end
  if #qt ~= #dt then
    return false
  end
  for i = 1, #qt do
    if not tok_eq(qt[i], dt[i], loose) then
      return false
    end
  end
  return true
end

--- (score, was_loose), or (-1, false) for no match.
function M.shape_score(parts, d)
  local res = parts[#parts]
  for _, loose in ipairs({ false, true }) do
    if part_match(res, d.res, loose) then
      local used, ok = {}, true
      for qi = 1, #parts - 1 do
        local found
        for k, da in ipairs(d.args) do
          if not used[k] and part_match(parts[qi], da, loose) then
            found = k
            break
          end
        end
        if not found then
          ok = false
          break
        end
        used[found] = true
      end
      if ok then
        return 100 - 10 * (#d.args - (#parts - 1)) - (loose and 5 or 0), loose
      end
    end
  end
  return -1, false
end

-- ---------------------------------------------------------------- answers --

--- What an agent (or a reader) needs to decide whether to read further.
function M.brief(d)
  local out = {
    name = d.name,
    kind = d.kind,
    effect = d.eff == nil and vim.NIL or d.eff,
    signature = d.signature,
    documented = d.doc ~= nil,
  }
  if d.doc and #d.doc > 0 then
    out.doc = table.concat(d.doc, "\n")
  end
  if d.where then
    out.at = ("%s:%d"):format(d.where.file, d.where.start_line)
  end
  return out
end
local brief = M.brief

function M.full(d, include_definition)
  local out = brief(d)
  out.module = d.module
  out.requires_about = d.pre
  out.ensures_about = d.post
  out.mentions = d.refs
  local defn = d.definition
  if defn and defn ~= "" then
    local len = vim.fn.strchars(defn)
    if include_definition or len <= M.DEFINITION_PREVIEW then
      out.definition = defn
    else
      out.definition_preview = vim.fn.strcharpart(defn, 0, M.DEFINITION_PREVIEW)
      out.definition_truncated = true
      out.definition_length = len
    end
  end
  if d.doc == nil then
    out.note = "This declaration has no documentation. Its type is checked by F*, so the signature and "
      .. "contract above are authoritative; do not present a description of it as the author's."
  end
  return out
end

local function brief_list(ds)
  local out = {}
  for i, d in ipairs(ds) do
    out[i] = brief(d)
  end
  return out
end

local tools = {}

function tools.find_by_contract(idx, args)
  local name = str_arg(args.name)
  local side = args.side == nil and "ensures" or args.side
  local limit = int_arg(args, "limit", 20)
  if side ~= "ensures" and side ~= "requires" and side ~= "either" then
    return { error = "side must be ensures, requires or either" }
  end
  local function hits(field)
    local groups, keys = {}, {}
    for _, d in ipairs(idx.decls) do
      for _, n in ipairs(d[field]) do
        if n == name or short(n) == name then
          if not groups[n] then
            groups[n] = {}
            keys[#keys + 1] = n
          end
          table.insert(groups[n], d)
        end
      end
    end
    return groups, sort_strings(keys)
  end
  local result = { query = name, side = side, groups = {} }
  for _, fl in ipairs({ { "post", "ensures" }, { "pre", "requires" } }) do
    local field, label = fl[1], fl[2]
    if side == label or side == "either" then
      local groups, keys = hits(field)
      for _, n in ipairs(keys) do
        local ds = groups[n]
        table.insert(result.groups, {
          about = n,
          side = label,
          total = #ds,
          shown = py_min(#ds, limit),
          declarations = brief_list(take(ds, limit)),
        })
      end
    end
  end
  if #result.groups == 0 then
    result.note = ("No declaration's contract mentions %s. Contract matching is exact on the last name "
      .. "component, so try the whole name, or list_module to see what a module offers."):format(repr(name))
  end
  return result
end

function tools.find_by_type(idx, args)
  local shape = str_arg(args.shape)
  local limit = int_arg(args, "limit", 20)
  if not shape:find("->", 1, true) then
    return { error = "shape must contain '->', e.g. 'seq a -> nat -> a'" }
  end
  local parts = {}
  for _, p in ipairs(vim.split(shape, "->", { plain = true })) do
    parts[#parts + 1] = M.words(p)
  end
  local exact, close = {}, {}
  for _, d in ipairs(idx.decls) do
    local s, loose = M.shape_score(parts, d)
    if s >= 0 then
      table.insert(loose and close or exact, { s, d })
    end
  end
  local function order(x, y)
    if x[1] ~= y[1] then
      return x[1] > y[1]
    end
    return before(x[2].name, y[2].name)
  end
  table.sort(exact, order)
  table.sort(close, order)
  local declarations = {}
  local function tag(items, kind)
    for _, item in ipairs(items) do
      local r = brief(item[2])
      r.match = kind
      declarations[#declarations + 1] = r
    end
  end
  tag(take(exact, limit), "exact")
  tag(take(close, math.max(0, limit - #exact)), "approximate")
  local result = {
    query = shape,
    exact = #exact,
    approximate = #close,
    note = "Explicit arguments match in any order. An approximate match is one found only by treating nat "
      .. "and pos as int.",
    declarations = declarations,
  }
  if #exact == 0 and #close > 0 then
    result.warning = "Nothing has exactly that shape. Every declaration below matched only after nat and pos "
      .. "were treated as int, so none of them is what was asked for."
  elseif #exact == 0 then
    result.note = "No declaration has a type of that shape, even treating nat and pos as int. Try fewer "
      .. "arguments, or a lower-case letter for any type."
  end
  return result
end

function tools.lookup(idx, args)
  local resolved, err = idx:resolve(str_arg(args.name))
  if err then
    return { error = err }
  end
  return M.full(idx.by_name[resolved], truthy(args.include_definition))
end

function tools.used_by(idx, args)
  local limit = int_arg(args, "limit", 20)
  local resolved, err = idx:resolve(str_arg(args.name))
  if err then
    return { error = err }
  end
  local users = sort_strings(vim.list_extend({}, idx.mentioned_by[resolved] or {}))
  local ds = {}
  for _, u in ipairs(take(users, limit)) do
    if idx.by_name[u] then
      ds[#ds + 1] = brief(idx.by_name[u])
    end
  end
  return { name = resolved, total = #users, shown = py_min(#users, limit), declarations = ds }
end

function tools.list_module(idx, args)
  local module = str_arg(args.module)
  local limit = int_arg(args, "limit", 200)
  local ds, documented = {}, 0
  for _, d in ipairs(idx.decls) do
    if d.module == module then
      ds[#ds + 1] = d
      if d.doc ~= nil then
        documented = documented + 1
      end
    end
  end
  if #ds == 0 then
    return { error = ("No module %s in the index. It holds: %s"):format(repr(module),
      table.concat(idx:module_names(), ", ")) }
  end
  return {
    module = module,
    total = #ds,
    documented = documented,
    shown = py_min(#ds, limit),
    declarations = brief_list(take(ds, limit)),
  }
end

function tools.modules(idx)
  local mods = {}
  for _, d in ipairs(idx.decls) do
    local m = mods[d.module]
    if not m then
      m = { module = d.module, declarations = 0, documented = 0 }
      mods[d.module] = m
    end
    m.declarations = m.declarations + 1
    if d.doc ~= nil then
      m.documented = m.documented + 1
    end
  end
  local out = {}
  for _, name in ipairs(idx:module_names()) do
    out[#out + 1] = mods[name]
  end
  return { modules = out }
end

M.tools = tools

--- Tool contracts, as fstardoc_mcp.py lists them.
M.contracts = {
  {
    name = "find_by_contract",
    description = "Find declarations whose contract mentions a name: what a lemma guarantees (its ensures) "
      .. "or assumes (its requires). This is the tool for 'which lemma gives me something about X', which "
      .. "cannot be expressed as a text search. Names are resolved, so two modules' `sorted` are reported "
      .. "separately.",
    inputSchema = {
      type = "object",
      properties = {
        name = { type = "string", description = "A declaration name, short or fully qualified." },
        side = { type = "string", enum = { "ensures", "requires", "either" }, description = "Default ensures." },
        limit = { type = "integer", description = "Default 20." },
      },
      required = { "name" },
    },
  },
  {
    name = "find_by_type",
    description = "Find declarations by the shape of their type, written with arrows, e.g. 'seq a -> nat -> "
      .. "a'. Explicit arguments match in any order; a lower-case single letter means any type; nat and pos "
      .. "also match int.",
    inputSchema = {
      type = "object",
      properties = {
        shape = { type = "string" },
        limit = { type = "integer", description = "Default 20." },
      },
      required = { "shape" },
    },
  },
  {
    name = "lookup",
    description = "The full record of one declaration: signature, effect, what its contract assumes and "
      .. "guarantees, the names it mentions, its documentation if it has any, and its definition. A short "
      .. "name is accepted when it is unambiguous.",
    inputSchema = {
      type = "object",
      properties = {
        name = { type = "string" },
        include_definition = {
          type = "boolean",
          description = "Send the whole definition. It is truncated by default, because a proof term can be "
            .. "very long.",
        },
      },
      required = { "name" },
    },
  },
  {
    name = "used_by",
    description = "Which declarations mention this one in their type or definition. Useful for finding worked "
      .. "uses of a lemma.",
    inputSchema = {
      type = "object",
      properties = { name = { type = "string" }, limit = { type = "integer" } },
      required = { "name" },
    },
  },
  {
    name = "list_module",
    description = "Every public declaration of one module, briefly.",
    inputSchema = {
      type = "object",
      properties = { module = { type = "string" }, limit = { type = "integer" } },
      required = { "module" },
    },
  },
  {
    name = "modules",
    description = "The modules in the index, with how many declarations each has and how many are documented.",
    inputSchema = { type = "object", properties = vim.empty_dict() },
  },
}

--- Run one tool. Returns the MCP result text and whether it is an error,
--- matching what fstardoc_mcp.py would send back.
---@return string text, boolean is_error
function M.call(idx, name, args)
  local tool = tools[name]
  if not tool then
    return ("No such tool: %s"):format(repr(name)), true
  end
  local ok, payload = pcall(tool, idx, type(args) == "table" and args or {})
  if not ok then
    return "error: " .. tostring(payload), true
  end
  return vim.json.encode(payload), payload.error ~= nil and payload.error ~= ""
end

return M
