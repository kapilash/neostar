--- Statusline summary of a buffer's checking state.

local M = {}

---@param session? neostar.Session
---@return neostar.Summary?
function M.summary(session)
  if not session then
    return nil
  end
  return session:summary()
end

--- Short statusline text, e.g. "F* ✓3 ~40 ✗0 ?1 [full…]".
--- ✓ verified, ~ lax-only (type-checked, not verified), ✗ failed, ? unchecked.
---@param session? neostar.Session
---@return string
function M.text(session)
  local s = M.summary(session)
  if not s then
    return ""
  end
  local parts = { ("F* ✓%d ~%d ✗%d ?%d"):format(s.verified, s.lax, s.failed, s.unchecked) }
  if not s.alive then
    table.insert(parts, "[stopped]")
  elseif s.running then
    local cls = (s.running == "full" or s.running == "verify-to-position") and "full" or "lax"
    table.insert(parts, ("[%s…]"):format(cls))
  end
  return table.concat(parts, " ")
end

return M
