local util = require("helpers.util")
local decl = require("neostar.fstar.decl")
local proposal = require("neostar.ui.proposal")

local HELPER = "let aux (y:nat) : Lemma (y * 1 == y) = ()"

local function setup()
  local b = util.open_fixture("Prove.fst")
  local t = assert(decl.target_at(b, 8))
  return b, t, vim.api.nvim_buf_get_lines(b, 0, -1, false)
end

describe("proof review", function()
  after_each(function()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    util.cleanup()
  end)

  it("shows a unified diff of the helpers and the new body", function()
    local b, t = setup()
    local view = proposal.show({ bufnr = b, target = t, helpers = HELPER, body = "aux x", on_accept = function() end })
    assert.equals("diff", vim.bo[view.buf].filetype)
    assert.matches("+" .. HELPER, view.text, 1, true)
    assert.matches("-  admit ()", view.text, 1, true)
    assert.matches("+  aux x", view.text, 1, true)
    assert.is_nil(view.text:find("-val target", 1, true))
    view.close()
  end)

  it("applies helpers above the val and the body as one undoable edit", function()
    local b, t, orig = setup()
    local accepted = false
    local view = proposal.show({
      bufnr = b,
      target = t,
      helpers = HELPER,
      body = "aux x",
      on_accept = function()
        accepted = true
        proposal.apply(b, t, HELPER, "aux x")
      end,
    })
    vim.api.nvim_set_current_win(view.win)
    vim.api.nvim_feedkeys("a", "x", false)
    assert.is_true(accepted)
    local now = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    assert.same({
      HELPER,
      "",
      "val target : x:nat -> Lemma (x * 1 + 0 == x)",
      "let target x =",
      "  aux x",
      "",
      "let after (x:nat) : Lemma (x >= 0) = ()",
    }, vim.list_slice(now, 7))
    -- the statement text is byte-for-byte the same
    local t2 = assert(decl.find_target(b, "target"))
    assert.equals(t.statement, t2.statement)
    assert.equals(t.val.text, t2.val.text)
    -- one undo restores the original
    vim.api.nvim_buf_call(b, function()
      vim.cmd("silent undo")
    end)
    assert.same(orig, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end)

  it("leaves the buffer unchanged on reject", function()
    local b, t, orig = setup()
    local rejected = false
    local view = proposal.show({
      bufnr = b,
      target = t,
      helpers = "",
      body = "()",
      on_accept = function()
        error("must not accept")
      end,
      on_reject = function()
        rejected = true
      end,
    })
    vim.api.nvim_set_current_win(view.win)
    vim.api.nvim_feedkeys("r", "x", false)
    assert.is_true(rejected)
    assert.same(orig, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end)

  it("replaces only the body of a target without val or helpers", function()
    local b = util.open_fixture("Clean.fst")
    local t = assert(decl.target_at(b, 4))
    proposal.apply(b, t, "", "assert (double x == 2 * x)")
    assert.equals(
      "let lemma_double (x:int) : Lemma (double x == 2 * x) = assert (double x == 2 * x)",
      vim.api.nvim_buf_get_lines(b, 4, 5, false)[1]
    )
  end)
end)
