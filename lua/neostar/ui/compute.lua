--- Show `compute` results in a floating window.

local M = {}

--- Split "value <: type" at the first top-level " <: ".
---@param s string
---@return string value, string? typ
function M.split_ascription(s)
  local depth = 0
  local i = 1
  local n = #s
  local open = { ["("] = true, ["["] = true, ["{"] = true }
  local close = { [")"] = true, ["]"] = true, ["}"] = true }
  while i <= n do
    local c = s:sub(i, i)
    if open[c] then
      depth = depth + 1
    elseif close[c] then
      depth = depth - 1
    elseif c == '"' then
      -- skip string literal
      i = i + 1
      while i <= n and s:sub(i, i) ~= '"' do
        if s:sub(i, i) == "\\" then
          i = i + 1
        end
        i = i + 1
      end
    elseif depth == 0 and s:sub(i, i + 3) == " <: " then
      return vim.trim(s:sub(1, i - 1)), vim.trim(s:sub(i + 4))
    end
    i = i + 1
  end
  return vim.trim(s), nil
end

--- Lines to display for a compute response.
---@param ok boolean
---@param response string
---@return string[] lines
function M.format(ok, response)
  response = tostring(response or ""):gsub("%s+$", "")
  if not ok then
    return vim.split(response, "\n", { plain = true })
  end
  local value, typ = M.split_ascription(response)
  local lines = vim.split(value, "\n", { plain = true })
  if typ then
    table.insert(lines, "")
    table.insert(lines, ": " .. typ:gsub("\n", " "))
  end
  return lines
end

---@param ok boolean
---@param response string
---@param term string
---@return integer win, integer buf
function M.show(ok, response, term)
  local lines = M.format(ok, response)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  if ok then
    -- Highlight without setting the filetype (which would start a checker).
    pcall(vim.treesitter.start, buf, "fstar")
  end
  local width = 20
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, math.max(math.floor(vim.o.columns * 0.8), 20))
  local height = math.min(#lines, math.max(math.floor(vim.o.lines * 0.5), 3))
  local title = ok and (" F* compute: " .. term:gsub("%s+", " "):sub(1, 40) .. " ") or " F* error "
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
  })
  vim.b[buf].neostar_compute = { ok = ok }
  if not ok then
    vim.wo[win].winhighlight = "Normal:DiagnosticError,FloatBorder:DiagnosticError,FloatTitle:DiagnosticError"
  end
  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true, desc = "Close F* result" })
  end
  return win, buf
end

return M
