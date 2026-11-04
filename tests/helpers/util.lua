--- Shared test helpers.

local fake_fstar = require("helpers.fake_fstar")

local M = {}

--- Wait until fn() is truthy (fails the test after timeout_ms).
function M.wait(fn, timeout_ms, msg)
  local ok = vim.wait(timeout_ms or 2000, fn, 5)
  assert(ok, msg or "condition not met in time")
end

--- Open a fixture file in a fresh buffer without triggering FileType.
---@param name string fixture file name (tests/fixtures/files/<name>)
---@param content_from? string other fixture whose text to load instead
function M.open_fixture(name, content_from)
  local path = fake_fstar.file(name)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, path)
  local text = fake_fstar.read(fake_fstar.file(content_from or name))
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr, path
end

--- Replace the whole buffer with another fixture's text (an "edit").
function M.set_text_from(bufnr, name)
  local text = fake_fstar.read(fake_fstar.file(name))
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

--- Attach neostar to a buffer with a fake F*.
---@return neostar.Session, FakeFStar
function M.attach_fake(bufnr, transcript_name, fake_opts, overrides)
  local fake = fake_fstar.new(fake_fstar.transcript(transcript_name), fake_opts)
  local session = require("neostar").attach(
    bufnr,
    vim.tbl_extend("force", {
      transport_factory = fake:factory(),
      debounce_ms = 30,
      lax_request_timeout_ms = 300,
      cancel_timeout_ms = 300,
      ping_interval_ms = 20,
    }, overrides or {})
  )
  return session, fake
end

--- Status of the fragment starting at a 0-based row.
function M.status_at(session, row)
  for _, item in ipairs(session:sorted_fragments()) do
    if item.srow == row then
      return item.fragment.status
    end
  end
  return nil
end

--- Statuses of all fragments, ordered by row: { "lax", "lax", ... }.
function M.statuses(session)
  local out = {}
  for _, item in ipairs(session:sorted_fragments()) do
    table.insert(out, item.fragment.status)
  end
  return out
end

function M.idle(session)
  return session.running == nil and session.pending == nil and not session.debounce_timer:is_active()
end

function M.cleanup()
  require("neostar").stop_all()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) ~= "" then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

return M
