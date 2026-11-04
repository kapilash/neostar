--- Agent tools and the scratch checker against a real fstar.exe.
--- Run with: make test-integration

local util = require("helpers.util")
local http = require("helpers.http")
local neostar = require("neostar")
local mcp = require("neostar.agent.mcp")
local tools = require("neostar.agent.tools")
local scratch = require("neostar.fstar.scratch")
local decl = require("neostar.fstar.decl")
local agents = require("helpers.agents")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local project = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname())) .. "/project"
vim.fn.mkdir(project, "p")
vim.fn.system({ "cp", "-r", root .. "/fixtures/project/.", project })

local have_fstar = vim.fn.executable("fstar.exe") == 1
local it_fstar = have_fstar and it or pending
local T = 120000

local function write_and_edit(rel, lines)
  local path = project .. "/" .. rel
  vim.fn.writefile(lines, path)
  vim.cmd.edit(path)
  local b = vim.api.nvim_get_current_buf()
  local s = assert(neostar.session(b))
  return b, s
end

local function wait_idle(s, pred)
  util.wait(function()
    return util.idle(s) and (pred == nil or pred())
  end, T)
end

local function check(sc, helpers, body)
  local result
  sc:check(helpers, body, function(r)
    result = r
  end)
  util.wait(function()
    return result ~= nil
  end, T)
  return result
end

describe("agent tools with fstar.exe", function()
  before_each(function()
    neostar.setup({ debounce_ms = 100 })
  end)
  after_each(function()
    mcp.stop()
    vim.cmd("silent! %bwipeout!")
    util.cleanup()
  end)

  it_fstar("checks candidates without disturbing the buffer's verified marks", function()
    local b, s = write_and_edit("src/Mid.fst", {
      "module Mid",
      "",
      "open Lib",
      "",
      "let before (x:nat) : Lemma (succ x > x) = ()",
      "",
      "let mid (x:nat) : Lemma (succ (succ x) == x + 2) =",
      "  admit ()",
      "",
      "let after (x:nat) : Lemma (succ x >= 1) = ()",
    })
    wait_idle(s, function()
      return #s.fragments == 5
    end)
    vim.cmd("NeostarVerify")
    wait_idle(s, function()
      return util.statuses(s)[5] == "verified"
    end)
    local before = util.statuses(s)
    assert.same({ "verified", "verified", "verified", "verified", "verified" }, before)

    local target = assert(decl.target_at(b, 6))
    local sc = scratch.new({ session = s, target = target, lines = vim.api.nvim_buf_get_lines(b, 0, -1, false) })
    local r = check(sc, "", "assert (x + 2 == x)")
    assert.is_false(r.ok)
    assert.equals("body", r.errors[1].where)
    r = check(sc, "", "()")
    assert.is_true(r.ok, r.text)
    r = check(sc, "let aux (y:nat) : Lemma (succ y == y + 1) = ()", "aux x; aux (succ x)")
    assert.is_true(r.ok, r.text)
    sc:close()

    assert.same(before, util.statuses(s))
    assert.equals(0, #vim.diagnostic.get(b))
    assert.is_nil(s.running)
  end)

  it_fstar("is not blocked by a failing proof above the target", function()
    local b, s = write_and_edit("src/Bad.fst", {
      "module Bad",
      "",
      "let bad_above (x:nat) : Lemma (x + 1 == x) = ()",
      "",
      "let target (x:nat) : Lemma (x * 1 == x) = admit ()",
    })
    wait_idle(s, function()
      return #s.fragments == 3
    end)
    local target = assert(decl.target_at(b, 4))
    local sc = scratch.new({ session = s, target = target, lines = vim.api.nvim_buf_get_lines(b, 0, -1, false) })
    local r = check(sc, "", "()")
    assert.is_true(r.ok, r.text)
    sc:close()
  end)

  it_fstar("looks up an unsaved definition through the buffer's checker", function()
    local b, s = write_and_edit("src/Unsaved.fst", { "module Unsaved", "", "let one : int = 1" })
    wait_idle(s, function()
      return #s.fragments == 2
    end)
    vim.api.nvim_buf_set_lines(b, -1, -1, false, { "", "let three : int = 3" })
    util.wait(function()
      return s.running ~= nil or #s.fragments == 3
    end, T)
    wait_idle(s, function()
      return #s.fragments == 3
    end)
    assert.is_true(vim.bo[b].modified)
    local token = mcp.register({ bufnr = b, tools = tools.read_only() })
    local text = http.text(http.call_tool(mcp.port(), token, "fstar_lookup", { symbol = "three" }))
    assert.matches("Unsaved.three : int", text, 1, true)
  end)

  for _, agent in ipairs(agents.list) do
  it_fstar("applies a scripted agent's proof and the buffer then verifies [" .. agent.name .. "]", function()
    neostar.setup({ debounce_ms = 100, agent = agents.options(agent) })
    agents.use_plan(agent, {
      { call = "check_proof", args = { helpers = "", body = "()" } },
      { call = "propose_proof", args = { helpers = "", body = "()" } },
    })
    local module = "Applied" .. agent.name:sub(1, 1):upper() .. agent.name:sub(2)
    local b, s = write_and_edit("src/" .. module .. ".fst", {
      "module " .. module,
      "",
      "open Lib",
      "",
      "let lem (x:nat) : Lemma (succ x == x + 1) = admit ()",
      "",
      "let bad (x:nat) : Lemma (x + 1 == x) = ()",
    })
    wait_idle(s, function()
      return #s.fragments == 4
    end)
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
    assert.is_not_nil(st.view, vim.inspect(res))
    vim.api.nvim_set_current_win(st.view.win)
    vim.api.nvim_feedkeys("a", "x", false)
    util.wait(function()
      return res ~= nil
    end, T)
    agents.clear()
    assert.equals("applied", res.outcome)
    assert.equals(b, vim.api.nvim_get_current_buf())
    assert.equals("let lem (x:nat) : Lemma (succ x == x + 1) = ()", vim.api.nvim_buf_get_lines(b, 4, 5, false)[1])
    wait_idle(s, function()
      return util.status_at(s, 4) == "lax"
    end)
    vim.cmd("NeostarVerify")
    local ok = vim.wait(T, function()
      return util.idle(s) and util.status_at(s, 4) == "verified"
    end, 50)
    assert(ok, "statuses: " .. vim.inspect(util.statuses(s)) .. " alive=" .. tostring(s.alive) .. " running=" .. tostring(s.running))
    assert.equals("failed", util.status_at(s, 6))
  end)
  end
end)
