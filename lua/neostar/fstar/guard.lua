--- Checks on agent-written F* (helper lemmas and proof bodies) that reject
--- anything that would weaken or skip proof checking.

local M = {}

--- Identifiers that are rejected (any module qualifier), besides `admit*`.
M.denied = {
  assume = true,
  tadmit = true,
  magic = true,
  unsafe_coerce = true,
  expect_failure = true,
  expect_lax_failure = true,
}

--- Options a candidate may set with #push-options.
M.allowed_options = {
  z3rlimit = true,
  z3rlimit_factor = true,
  fuel = true,
  ifuel = true,
  initial_fuel = true,
  initial_ifuel = true,
  max_fuel = true,
  max_ifuel = true,
  z3seed = true,
  split_queries = true,
  z3refresh = true,
  retry = true,
  quake = true,
}

--- Tokenise F* source: identifiers (with dots), strings, pragmas, other.
--- Comments are dropped. Returns a list of {kind, text}.
---@param src string
function M.tokens(src)
  local out, i, n = {}, 1, #src
  while i <= n do
    local c = src:sub(i, i)
    local two = src:sub(i, i + 1)
    if two == "(*" then
      local depth, j = 1, i + 2
      while j <= n and depth > 0 do
        local t = src:sub(j, j + 1)
        if t == "(*" then
          depth, j = depth + 1, j + 2
        elseif t == "*)" then
          depth, j = depth - 1, j + 2
        else
          j = j + 1
        end
      end
      i = j
    elseif two == "//" then
      local j = src:find("\n", i, true) or (n + 1)
      i = j
    elseif c == '"' then
      local j, buf = i + 1, {}
      while j <= n do
        local d = src:sub(j, j)
        if d == "\\" then
          table.insert(buf, src:sub(j, j + 1))
          j = j + 2
        elseif d == '"' then
          break
        else
          table.insert(buf, d)
          j = j + 1
        end
      end
      table.insert(out, { kind = "string", text = table.concat(buf) })
      i = j + 1
    elseif c == "#" and src:sub(i + 1, i + 1):match("[%a]") then
      local word = src:match("^#[%w_%-]+", i)
      table.insert(out, { kind = "pragma", text = word })
      i = i + #word
    elseif c:match("[%a_]") then
      local word = src:match("^[%w_'%.]+", i)
      table.insert(out, { kind = "ident", text = word })
      i = i + #word
    elseif c == "'" then
      -- char literal ('a', '\n') or a type variable ('a)
      local lit = src:match("^'\\?.'", i)
      if lit then
        i = i + #lit
      else
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return out
end

local function denied_ident(word)
  for part in word:gmatch("[^%.]+") do
    if part:match("^admit") or M.denied[part] then
      return part
    end
  end
  return nil
end

--- Check the options string of a #push-options pragma.
local function check_options(s)
  local words = vim.split(vim.trim(s), "%s+")
  local i = 1
  while i <= #words do
    local w = words[i]
    local name = w:match("^%-%-([%w_]+)$")
    if not name then
      return ("unexpected option text %q"):format(w)
    end
    if not M.allowed_options[name] then
      return ("option --%s is not allowed"):format(name)
    end
    -- value (if any) follows unless the next word is another option
    if words[i + 1] and not words[i + 1]:match("^%-%-") then
      i = i + 2
    else
      i = i + 1
    end
  end
  return nil
end

--- Check helper or body text. Returns nil when acceptable, else a reason.
---@param src string
---@param what string "body" or "helpers" (used in messages)
---@return string?
function M.check_text(src, what)
  local toks = M.tokens(src)
  local depth = 0
  for k, t in ipairs(toks) do
    if t.kind == "ident" then
      local bad = denied_ident(t.text)
      if bad then
        return ("`%s` is not allowed in the %s"):format(bad, what)
      end
      if what == "helpers" and (t.text == "module" or t.text == "friend") then
        return ("`%s` is not allowed in the helpers"):format(t.text)
      end
    elseif t.kind == "pragma" then
      if t.text == "#push-options" then
        local nxt = toks[k + 1]
        if not nxt or nxt.kind ~= "string" then
          return "#push-options must be followed by an options string"
        end
        local err = check_options(nxt.text)
        if err then
          return err
        end
        depth = depth + 1
      elseif t.text == "#pop-options" then
        depth = depth - 1
        if depth < 0 then
          return "#pop-options without a matching #push-options"
        end
      else
        return ("%s is not allowed; use #push-options/#pop-options with allowed options"):format(t.text)
      end
    end
  end
  if depth ~= 0 then
    return "every #push-options needs a matching #pop-options"
  end
  return nil
end

--- Top-level declaration nodes of a source string (comments excluded).
local function parse_top(src)
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, "fstar")
  if not ok or not parser then
    return nil, "the F* tree-sitter parser is not installed"
  end
  local root = parser:parse()[1]:root()
  local out = {}
  for node in root:iter_children() do
    if node:named() and not node:type():match("comment") then
      table.insert(out, node)
    end
  end
  return out, nil, root:has_error()
end

--- Check that statement .. body is still exactly one declaration, so a body
--- cannot end the target early and add declarations after it.
---@return string?
function M.check_body_shape(statement, body)
  local nodes, err, has_error = parse_top(statement .. body)
  if not nodes then
    return err
  end
  if has_error then
    return "the body does not parse; it must be a single F* expression"
  end
  if #nodes ~= 1 or nodes[1]:type() ~= "let_declaration" then
    return "the body must be a single expression; put extra declarations in `helpers`"
  end
  return nil
end

--- Check helpers parse as top-level declarations.
---@return string?
function M.check_helpers_shape(helpers)
  if not helpers or not helpers:match("%S") then
    return nil
  end
  local nodes, err, has_error = parse_top(helpers)
  if not nodes then
    return err
  end
  if has_error then
    return "the helpers do not parse as F* declarations"
  end
  for _, n in ipairs(nodes) do
    local t = n:type()
    if t == "module_declaration" then
      return "`module` is not allowed in the helpers"
    end
  end
  return nil
end

--- All candidate checks. Returns nil if acceptable, else a reason.
---@param statement string
---@param helpers string
---@param body string
---@return string?
function M.check_candidate(statement, helpers, body)
  if not body or not body:match("%S") then
    return "the body is empty"
  end
  return M.check_text(helpers or "", "helpers")
    or M.check_text(body, "body")
    or M.check_helpers_shape(helpers)
    or M.check_body_shape(statement, body)
end

return M
