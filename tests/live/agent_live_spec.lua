--- Live end-to-end test: a real agent and real fstar.exe. Costs tokens or
--- Copilot premium requests.
--- Run with: make test-live   (sets NEOSTAR_LIVE_AGENT=1)
---   NEOSTAR_LIVE_RUNNER  "claude" (default) or "copilot"
---   NEOSTAR_LIVE_MODEL   model; default "haiku" for Claude, the agent's own
---                        default for Copilot

local util = require("helpers.util")
local neostar = require("neostar")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local project = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname())) .. "/project"
vim.fn.mkdir(project, "p")
vim.fn.system({ "cp", "-r", root .. "/fixtures/project/.", project })

local runner = os.getenv("NEOSTAR_LIVE_RUNNER") or "claude"
local model = os.getenv("NEOSTAR_LIVE_MODEL")
if model == "" then
  model = nil
end
if runner == "claude" then
  model = model or "haiku"
end
local enabled = os.getenv("NEOSTAR_LIVE_AGENT") == "1"
  and vim.fn.executable("fstar.exe") == 1
  and vim.fn.executable(runner) == 1
local it_live = enabled and it or pending
local T = 300000

local function status_of(s, row)
  return util.status_at(s, row)
end

describe("live agent bridge [" .. runner .. "]", function()
  before_each(function()
    neostar.setup({ debounce_ms = 100, agent = { runner = runner, [runner] = { model = model } } })
  end)
  after_each(function()
    require("neostar.agent").stop_all()
    vim.cmd("silent! %bwipeout!")
    util.cleanup()
  end)

  it_live("proves a lemma, applies the diff, and the buffer verifies; explains a failing lemma", function()
    local path = project .. "/src/Live.fst"
    vim.fn.writefile({
      "module Live",
      "",
      "open Lib",
      "",
      "let lem (x:nat) : Lemma (succ x == x + 1) = admit ()",
      "",
      "let bad (x:nat) : Lemma (x + 1 == x) = ()",
    }, path)
    vim.cmd.edit(path)
    local b = vim.api.nvim_get_current_buf()
    local s = assert(neostar.session(b))
    util.wait(function()
      return util.idle(s) and #s.fragments == 4
    end, T)

    -- prove `lem`
    local res
    local st = require("neostar.prove").prove(b, {
      row = 4,
      on_done = function(r)
        res = r
      end,
    })
    util.wait(function()
      return st.view ~= nil or res ~= nil
    end, T)
    assert.is_not_nil(st.view, "no proof found: " .. vim.inspect(res) .. "\n" .. st.window:text())
    vim.api.nvim_set_current_win(st.view.win)
    vim.api.nvim_feedkeys("a", "x", false)
    util.wait(function()
      return res ~= nil
    end, T)
    assert.equals("applied", res.outcome)
    local line = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    assert.is_nil(table.concat(line, "\n"):find("admit", 1, true))
    assert.matches("let lem (x:nat) : Lemma (succ x == x + 1) = ", table.concat(line, "\n"), 1, true)

    -- the applied proof verifies in the buffer's own checker
    util.wait(function()
      return util.idle(s)
    end, T)
    vim.cmd("NeostarVerify")
    local lem_row
    for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      if l:match("^let lem") then
        lem_row = i - 1
      end
    end
    local ok = vim.wait(T, function()
      return s.running == nil and util.idle(s) and status_of(s, lem_row) == "verified"
    end, 50)
    assert(
      ok,
      "lem not verified\n"
        .. table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
        .. "\nstatuses: "
        .. vim.inspect(util.statuses(s))
        .. "\nrunning: "
        .. tostring(s.running)
        .. "\ndiags: "
        .. vim.inspect(s:diagnostics())
    )

    -- explain the failing lemma
    local bad_row
    for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      if l:match("^let bad") then
        bad_row = i
      end
    end
    local ex
    ex = require("neostar.explain").explain(b, bad_row, bad_row, {
      on_done = function(r)
        ex.result = r
      end,
    })
    util.wait(function()
      return ex.result ~= nil
    end, T)
    assert.is_true(ex.result.ok, ex.result.error)
    assert.is_true(ex.failing)
    assert.is_true(#ex.window:text() > 50, ex.window:text())
  end)
end)
