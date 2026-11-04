--- Review a verified proof proposal as a diff, and apply it as one edit.

local M = {}

--- Start of the edited region: the matching val, else the let.
---@param target neostar.ProveTarget
---@return integer row, integer col
local function region_start(target)
  if target.val then
    return target.val.srow, 0
  end
  return target.decl.srow, target.decl.scol
end

--- Text of the current region and the proposed replacement.
---@param bufnr integer
---@param target neostar.ProveTarget
---@param helpers string
---@param body string
---@return string old, string new
function M.region_texts(bufnr, target, helpers, body)
  local sr, sc = region_start(target)
  local d = target.decl
  local old = table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, d.erow, d.ecol, {}), "\n")
  -- unchanged part: from the region start (val, if any) to the start of the body
  local head = table.concat(vim.api.nvim_buf_get_text(bufnr, sr, sc, target.body_srow, target.body_scol, {}), "\n")
  local new = head .. body
  if helpers and helpers:match("%S") then
    new = vim.trim(helpers) .. "\n\n" .. new
  end
  return old, new
end

local function unified_diff(old, new)
  local diff = (vim.text and vim.text.diff) or vim.diff
  return diff(old .. "\n", new .. "\n", { result_type = "unified", ctxlen = 3 })
end

--- Apply the proposal as a single edit (one undo step). The statement text is
--- never rewritten: only helpers are inserted and the body replaced.
---@param bufnr integer
---@param target neostar.ProveTarget
---@param helpers string
---@param body string
function M.apply(bufnr, target, helpers, body)
  local sr, sc = region_start(target)
  local _, new = M.region_texts(bufnr, target, helpers, body)
  local d = target.decl
  -- One set_text call, so a single undo restores everything. The text between
  -- the region start and the body (val + statement) is copied from the buffer.
  vim.api.nvim_buf_set_text(bufnr, sr, sc, d.erow, d.ecol, vim.split(new, "\n", { plain = true }))
end

---@param opts {bufnr: integer, target: neostar.ProveTarget, helpers: string, body: string, on_accept: fun(), on_reject?: fun()}
---@return {buf: integer, win: integer, close: fun()}
function M.show(opts)
  local old, new = M.region_texts(opts.bufnr, opts.target, opts.helpers, opts.body)
  local text = unified_diff(old, new)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.b[buf].neostar_source = opts.bufnr
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  pcall(function()
    vim.bo[buf].filetype = "diff"
  end)
  local width = math.min(110, math.max(50, math.floor(vim.o.columns * 0.75)))
  local height = math.min(#lines + 1, math.max(6, math.floor(vim.o.lines * 0.6)))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Verified proof for " .. opts.target.name .. " ",
    title_pos = "center",
    footer = " a accept  r reject  <CR> go to target ",
    footer_pos = "right",
  })
  local decided = false
  local view = { buf = buf, win = win }
  function view.close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  local function decide(accept)
    if decided then
      return
    end
    decided = true
    view.close()
    if accept then
      opts.on_accept()
    elseif opts.on_reject then
      opts.on_reject()
    end
  end
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("a", function()
    decide(true)
  end)
  map("r", function()
    decide(false)
  end)
  map("q", function()
    decide(false)
  end)
  map("<Esc>", function()
    decide(false)
  end)
  map("<CR>", function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(w) == opts.bufnr then
        vim.api.nvim_win_set_cursor(w, { opts.target.decl.srow + 1, 0 })
        break
      end
    end
  end)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        decide(false)
      end)
    end,
  })
  view.text = text
  view.decide = decide
  return view
end

return M
