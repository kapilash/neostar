local util = require("helpers.util")
local compute_ui = require("neostar.ui.compute")

local function float_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      return w
    end
  end
end

local function float_lines()
  local w = float_win()
  assert(w, "no floating window")
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false), w
end

local function close_floats()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      vim.api.nvim_win_close(w, true)
    end
  end
end

local function open(extra)
  local b = util.open_fixture("Clean.fst")
  if extra then
    vim.api.nvim_buf_set_lines(b, -1, -1, false, extra)
  end
  local s, fake = util.attach_fake(b, "compute")
  util.wait(function()
    return util.idle(s) and #s.fragments == 4
  end)
  return b, s, fake
end

describe("fstar/evaluation", function()
  after_each(function()
    close_floats()
    util.cleanup()
  end)

  it("evaluates a visual selection without modifying the buffer", function()
    local b, _, fake = open({ "", "(* List.Tot.length [1;2;3] *)" })
    local tick = vim.api.nvim_buf_get_changedtick(b)
    local lines_before = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    vim.api.nvim_win_set_cursor(0, { 10, 3 })
    vim.cmd("normal! v22l\27")
    vim.cmd("'<,'>NeostarCompute")
    util.wait(function()
      return float_win() ~= nil
    end)
    local lines = float_lines()
    assert.equals("3", lines[1])
    assert.equals("List.Tot.length [1;2;3]", fake:sent_of("compute")[1].args.term)
    assert.equals(tick, vim.api.nvim_buf_get_changedtick(b))
    assert.same(lines_before, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end)

  it("evaluates an expression given as an argument", function()
    open()
    vim.cmd("NeostarCompute 2 + 3")
    util.wait(function()
      return float_win() ~= nil
    end)
    assert.equals("5", float_lines()[1])
  end)

  it("evaluates in the context of checked definitions and shows the type", function()
    open()
    vim.cmd("NeostarCompute double 21")
    util.wait(function()
      return float_win() ~= nil
    end)
    local lines = float_lines()
    assert.equals("42", lines[1])
    assert.equals(": int", lines[3])
  end)

  it("shows F* errors marked as errors (unchecked definition)", function()
    open()
    vim.cmd("NeostarCompute triple 1")
    util.wait(function()
      return float_win() ~= nil
    end)
    local lines, w = float_lines()
    assert.matches("Identifier not found: triple", table.concat(lines, "\n"), 1, true)
    assert.is_false(vim.b[vim.api.nvim_win_get_buf(w)].neostar_compute.ok)
    assert.matches("DiagnosticError", vim.wo[w].winhighlight)
  end)

  it("shows ill-typed expressions as errors", function()
    open()
    vim.cmd('NeostarCompute 1 + "a"')
    util.wait(function()
      return float_win() ~= nil
    end)
    local lines, w = float_lines()
    assert.matches("Expected expression of type int", table.concat(lines, "\n"), 1, true)
    assert.is_false(vim.b[vim.api.nvim_win_get_buf(w)].neostar_compute.ok)
  end)

  it("opens a focusable float that can be copied from and closed with q", function()
    open()
    vim.cmd("NeostarCompute 2 + 3")
    util.wait(function()
      return float_win() ~= nil
    end)
    local w = float_win()
    assert.equals(w, vim.api.nvim_get_current_win())
    vim.cmd("normal! yy")
    assert.equals("5\n", vim.fn.getreg('"'))
    vim.api.nvim_feedkeys("q", "x", false)
    assert.is_nil(float_win())
  end)

  it("refuses to evaluate while a check is running, without cancelling it", function()
    local _, s, fake = open()
    fake.auto = false
    vim.cmd("NeostarVerify")
    util.wait(function()
      return s.running == "full"
    end)
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(m)
      table.insert(msgs, m)
    end
    vim.cmd("NeostarCompute 2 + 3")
    vim.notify = orig
    assert.matches("unavailable until the check finishes", msgs[1])
    assert.equals(0, #fake:sent_of("compute"))
    assert.equals(0, #fake:sent_of("cancel"))
    assert.equals("full", s.running)
    assert.is_nil(float_win())
  end)

  describe("result formatting", function()
    it("splits a top-level ascription only", function()
      assert.same({ "3", "i: int{i >= 0 == true <: prop}" }, { compute_ui.split_ascription("3 <: i: int{i >= 0 == true <: prop}") })
      assert.same({ "Some (1 <: int)", "option int" }, { compute_ui.split_ascription("Some (1 <: int) <: option int") })
      assert.same({ "5" }, { compute_ui.split_ascription("5") })
    end)
  end)
end)
