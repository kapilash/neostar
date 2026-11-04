--- Verification frontier in the sign column: one sign per line of each
--- top-level declaration, by status.

local M = {}

M.ns = vim.api.nvim_create_namespace("neostar.signs")

--- Highlight groups and their default links.
M.groups = {
  verified = { group = "NeostarVerified", link = "DiagnosticOk" },
  lax = { group = "NeostarLax", link = "Comment" },
  failed = { group = "NeostarFailed", link = "DiagnosticError" },
  inflight = { group = "NeostarInflight", link = "DiagnosticWarn" },
  unreached = { group = "NeostarUnreached", link = "NonText" },
}

--- Default glyphs. Verified and lax-only must stay visually distinct.
M.default_signs = {
  verified = { text = "┃", hl = "NeostarVerified" },
  lax = { text = "┆", hl = "NeostarLax" },
  failed = { text = "┃", hl = "NeostarFailed" },
  inflight = { text = "│", hl = "NeostarInflight" },
  unreached = { text = "·", hl = "NeostarUnreached" },
}

function M.define_highlights()
  for _, g in pairs(M.groups) do
    vim.api.nvim_set_hl(0, g.group, { link = g.link, default = true })
  end
end

---@param bufnr integer
---@param session neostar.Session
---@param signs table<string, {text: string, hl: string}>
function M.render(bufnr, session, signs)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local nlines = vim.api.nvim_buf_line_count(bufnr)
  for _, item in ipairs(session:sorted_fragments()) do
    local sign = signs[item.fragment.status]
    if sign and sign.text and sign.text ~= "" then
      local last = math.min(item.erow, nlines - 1)
      for row = item.srow, last do
        vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
          sign_text = sign.text,
          sign_hl_group = sign.hl,
          priority = 5,
        })
      end
    end
  end
end

--- Signs currently placed, as { [row] = {text=, hl=} } (for tests and tooling).
function M.placed(bufnr)
  local out = {}
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, M.ns, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    local d = m[4]
    out[m[2]] = { text = vim.trim(d.sign_text or ""), hl = d.sign_hl_group }
  end
  return out
end

--- Attach rendering to a session, coalescing bursts of updates.
---@param bufnr integer
---@param session neostar.Session
---@param get_signs fun(): table
function M.attach(bufnr, session, get_signs)
  local scheduled = false
  local function schedule()
    if scheduled then
      return
    end
    scheduled = true
    vim.defer_fn(function()
      scheduled = false
      M.render(bufnr, session, get_signs())
    end, 20)
  end
  session:subscribe(function(event)
    if event == "fragments" then
      schedule()
    end
  end)
  session.render_signs_now = function()
    M.render(bufnr, session, get_signs())
  end
end

return M
