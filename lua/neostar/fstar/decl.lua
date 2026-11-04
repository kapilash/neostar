--- Top-level declarations of an F* buffer, from the tree-sitter parse tree:
--- the declaration at a row, and a `let` target split into statement and body.

local M = {}

---@class neostar.DeclRange
---@field type string node type
---@field srow integer 0-based
---@field scol integer
---@field erow integer
---@field ecol integer

---@class neostar.ProveTarget
---@field name string
---@field decl neostar.DeclRange the whole let declaration
---@field body_srow integer start of the body (value node), 0-based
---@field body_scol integer
---@field statement string declaration text before the body (ends with "=" and spacing)
---@field body string current body text
---@field val? {text: string, srow: integer, erow: integer} matching val declaration
---@field module_row integer last row of the module declaration (-1 if none)

local IGNORED = { comment = true, block_comment = true, line_comment = true }

--- Parse a buffer; returns the root node, or nil and an error message.
---@param bufnr integer
function M.root(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "fstar", { error = false })
  if not ok or not parser then
    return nil, "the F* tree-sitter parser is not installed (see :help neostar-treesitter)"
  end
  local tree = parser:parse()[1]
  if not tree then
    return nil, "could not parse the buffer"
  end
  return tree:root()
end

local function range_of(node)
  local sr, sc, er, ec = node:range()
  return { type = node:type(), srow = sr, scol = sc, erow = er, ecol = ec }
end

--- Text of a node range in the buffer.
local function text_of(bufnr, sr, sc, er, ec)
  return table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec, {}), "\n")
end

local function field(node, name)
  local list = node:field(name)
  return list, list[1]
end

--- Top-level declaration nodes (comments excluded), in order.
local function top_level(root)
  local out = {}
  for node in root:iter_children() do
    if node:named() and not IGNORED[node:type()] then
      table.insert(out, node)
    end
  end
  return out
end

--- Node row range, treating a declaration that ends at column 0 as ending on the row before.
local function rows(node)
  local sr, _, er, ec = node:range()
  if ec == 0 and er > sr then
    er = er - 1
  end
  return sr, er
end

--- The top-level declaration containing a 0-based row, or nil.
---@param bufnr integer
---@param row integer
---@return neostar.DeclRange?, string?
function M.decl_at(bufnr, row)
  local root, err = M.root(bufnr)
  if not root then
    return nil, err
  end
  for _, node in ipairs(top_level(root)) do
    local sr, er = rows(node)
    if row >= sr and row <= er and node:type() ~= "module_declaration" then
      return range_of(node)
    end
  end
  return nil, "no declaration at the cursor"
end

--- Find the top-level `let` named `name` and return it as a target (or nil).
---@param bufnr integer
---@param name string
---@return neostar.ProveTarget?, string?
function M.find_target(bufnr, name)
  local root, err = M.root(bufnr)
  if not root then
    return nil, err
  end
  for _, node in ipairs(top_level(root)) do
    if node:type() == "let_declaration" then
      local _, n = field(node, "name")
      if n and vim.treesitter.get_node_text(n, bufnr) == name then
        local sr = node:range()
        return M.target_at(bufnr, sr)
      end
    end
  end
  return nil, ("`%s` is no longer in the buffer"):format(name)
end

--- The `let` declaration at a 0-based row, split into statement and body.
---@param bufnr integer
---@param row integer
---@return neostar.ProveTarget?, string? error
function M.target_at(bufnr, row)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name:match("%.fst$") then
    return nil, ":NeostarProve needs the cursor on a `let` in an .fst file"
  end
  local root, err = M.root(bufnr)
  if not root then
    return nil, err
  end
  local decls = top_level(root)
  local module_row = -1
  local found
  for _, node in ipairs(decls) do
    if node:type() == "module_declaration" then
      local _, _, er = node:range()
      module_row = er
    end
    local sr, er = rows(node)
    if row >= sr and row <= er then
      found = node
      break
    end
  end
  if not found or found:type() ~= "let_declaration" then
    return nil, ":NeostarProve needs the cursor on a `let` in an .fst file"
  end
  local values, value = field(found, "value")
  if not value then
    return nil, "this `let` has no body to prove"
  end
  if #values > 1 then
    return nil, ":NeostarProve does not support mutually recursive `let rec ... and ...` definitions yet"
  end
  if found:has_error() then
    return nil, "the declaration has syntax errors; fix them first"
  end
  local _, name_node = field(found, "name")
  local target_name = name_node and vim.treesitter.get_node_text(name_node, bufnr) or "?"
  local d = range_of(found)
  local vr, vc = value:range()
  local target = {
    name = target_name,
    decl = d,
    body_srow = vr,
    body_scol = vc,
    statement = text_of(bufnr, d.srow, d.scol, vr, vc),
    body = text_of(bufnr, vr, vc, d.erow, d.ecol),
    module_row = module_row,
  }
  -- A matching `val` earlier in the file is part of the statement.
  for _, node in ipairs(decls) do
    if node == found then
      break
    end
    if node:type() == "val_declaration" then
      local _, vn = field(node, "name")
      if vn and vim.treesitter.get_node_text(vn, bufnr) == target_name then
        local r = range_of(node)
        target.val = {
          text = text_of(bufnr, r.srow, r.scol, r.erow, r.ecol),
          srow = r.srow,
          erow = r.erow,
        }
      end
    end
  end
  return target
end

return M
