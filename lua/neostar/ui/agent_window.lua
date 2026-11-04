--- Floating Markdown window that fills in as an agent streams text.
--- q closes it (stopping a run in progress); f asks a follow-up question.

local M = {}

---@class neostar.AgentWindow
---@field buf integer
---@field win integer?
local W = {}
W.__index = W

---@param opts {title: string, source?: integer, on_close?: fun(), on_followup?: fun(question: string), footer?: string}
---@return neostar.AgentWindow
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local ok, parser = pcall(vim.treesitter.language.add, "markdown")
  if not ok or not parser then
    -- Neovim's Markdown ftplugin starts tree-sitter unconditionally.
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("noautocmd setlocal filetype=markdown syntax=markdown")
    end)
  else
    pcall(function()
      vim.bo[buf].filetype = "markdown"
    end)
  end
  if opts.source then
    -- lets :NeostarAgentStop work from inside the window
    vim.b[buf].neostar_source = opts.source
  end
  local cols, rows = vim.o.columns, vim.o.lines
  local width = math.min(100, math.max(40, math.floor(cols * 0.7)))
  local height = math.max(8, math.floor(rows * 0.6))
  local self = setmetatable({ buf = buf, opts = opts, footer = opts.footer or "" }, W)
  self.win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((rows - height) / 2) - 1,
    col = math.floor((cols - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
    footer = self:_footer_text(),
    footer_pos = "right",
  })
  vim.wo[self.win].wrap = true
  vim.wo[self.win].linebreak = true
  vim.wo[self.win].conceallevel = 2
  vim.bo[buf].modifiable = false
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map("q", function()
    self:close()
  end)
  map("<Esc>", function()
    self:close()
  end)
  if opts.on_followup then
    map("f", function()
      vim.ui.input({ prompt = "Follow-up question: " }, function(q)
        if q and q:match("%S") then
          opts.on_followup(q)
        end
      end)
    end)
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(self.win),
    once = true,
    callback = function()
      self:_closed()
    end,
  })
  return self
end

function W:_footer_text()
  local keys = self.opts.on_followup and "q close  f follow-up" or "q close"
  if self.footer ~= "" then
    return " " .. self.footer .. "  |  " .. keys .. " "
  end
  return " " .. keys .. " "
end

function W:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

--- Append streamed text (may contain newlines).
---@param text string
function W:append(text)
  if not vim.api.nvim_buf_is_valid(self.buf) or text == "" then
    return
  end
  local follow = false
  if self:is_open() then
    local cur = vim.api.nvim_win_get_cursor(self.win)[1]
    follow = cur >= vim.api.nvim_buf_line_count(self.buf) - 1
  end
  local parts = vim.split(text, "\n", { plain = true })
  local n = vim.api.nvim_buf_line_count(self.buf)
  local last = vim.api.nvim_buf_get_lines(self.buf, n - 1, n, false)[1] or ""
  parts[1] = last .. parts[1]
  vim.bo[self.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.buf, n - 1, n, false, parts)
  vim.bo[self.buf].modifiable = false
  if follow and self:is_open() then
    local count = vim.api.nvim_buf_line_count(self.buf)
    pcall(vim.api.nvim_win_set_cursor, self.win, { count, 0 })
  end
end

--- Full text of the window.
function W:text()
  if not vim.api.nvim_buf_is_valid(self.buf) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
end

--- Short status shown in the window border (e.g. "running…", "attempt 3/10").
function W:set_status(status)
  self.footer = status or ""
  if self:is_open() then
    vim.api.nvim_win_set_config(self.win, { footer = self:_footer_text(), footer_pos = "right" })
  end
end

function W:_closed()
  if self.closed then
    return
  end
  self.closed = true
  self.win = nil
  if self.opts.on_close then
    self.opts.on_close()
  end
end

function W:close()
  if self:is_open() then
    vim.api.nvim_win_close(self.win, true)
  end
  self:_closed()
end

M.Window = W
return M
