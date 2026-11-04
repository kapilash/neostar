local M = {}

M.ns = vim.api.nvim_create_namespace("neostar.agent.context")

function M.track(bufnr, first, last)
  local line = vim.api.nvim_buf_get_lines(bufnr, last, last + 1, false)[1] or ""
  return vim.api.nvim_buf_set_extmark(bufnr, M.ns, first, 0, {
    end_row = last,
    end_col = #line,
    right_gravity = false,
    end_right_gravity = true,
  })
end

function M.range(bufnr, mark)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, mark, { details = true })
  if #pos == 0 or (pos[1] == pos[3].end_row and pos[2] == pos[3].end_col) then
    return nil
  end
  return pos[1], pos[3].end_row
end

function M.checker(s)
  return {
    alive = s.alive,
    revision = s.sent_tick,
    current = s.alive and s.sent_tick == vim.api.nvim_buf_get_changedtick(s.bufnr)
      and not s.running and not s.pending and not s.debounce_timer:is_active(),
    running = s.running,
  }
end

function M.header(s)
  local checker = M.checker(s)
  return ("Editor revision: %d (%s). Checker revision: %s (%s).\n"
    .. "Use neostar_context for the authoritative unsaved source; file-reading tools see disk contents."):format(
    vim.api.nvim_buf_get_changedtick(s.bufnr),
    vim.bo[s.bufnr].modified and "unsaved changes" or "saved",
    tostring(checker.revision or "none"),
    checker.current and "current" or "not current; diagnostics may be incomplete"
  )
end

function M.snapshot(s, ctx)
  local lines = vim.api.nvim_buf_get_lines(s.bufnr, 0, -1, false)
  local result = {
    file = s.file,
    revision = vim.api.nvim_buf_get_changedtick(s.bufnr),
    modified = vim.bo[s.bufnr].modified,
    source = table.concat(lines, "\n"),
    checker = M.checker(s),
    diagnostics = s:diagnostics(),
    declarations = {},
    request_revision = ctx.request_revision,
  }
  for _, item in ipairs(s:sorted_fragments()) do
    table.insert(result.declarations, {
      start_line = item.srow + 1,
      end_line = item.erow + 1,
      status = item.fragment.status,
    })
  end
  if ctx.selection then
    local first, last = M.range(s.bufnr, ctx.selection)
    if first then
      result.selection = {
        start_line = first + 1,
        end_line = last + 1,
        text = table.concat(vim.list_slice(lines, first + 1, last + 1), "\n"),
      }
    else
      result.selection_missing = true
    end
  end
  if ctx.target then
    local target, err = require("neostar.fstar.decl").find_target(s.bufnr, ctx.target)
    if target then
      result.target = {
        name = target.name,
        start_line = target.decl.srow + 1,
        statement = target.statement,
        body = target.body,
        val = target.val and target.val.text,
      }
    else
      result.target_error = err
    end
  end
  return result
end

return M
