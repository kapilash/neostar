--- End-to-end tests against a real fstar.exe (skipped when none is on PATH).
--- Run with: make test-integration

local util = require("helpers.util")
local neostar = require("neostar")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
-- Work on a copy so tests that edit and write files never touch the fixtures.
local project = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname())) .. "/project"
vim.fn.mkdir(project, "p")
vim.fn.system({ "cp", "-r", root .. "/fixtures/project/.", project })

local have_fstar = vim.fn.executable("fstar.exe") == 1
local it_fstar = have_fstar and it or pending

local T = 120000 -- generous: F* checks are slow on cold caches

local function edit(rel)
  vim.cmd.edit(project .. "/" .. rel)
  local b = vim.api.nvim_get_current_buf()
  local s = neostar.session(b)
  assert(s, "no session for " .. rel)
  return b, s
end

local function wait_idle(s, pred)
  util.wait(function()
    return util.idle(s) and (pred == nil or pred())
  end, T)
end

local function req(bufnr, method, row, col)
  local res = vim.lsp.buf_request_sync(bufnr, method, {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = row, character = col },
  }, T)
  local _, r = next(res or {})
  return r and r.result
end

describe("integration with fstar.exe", function()
  before_each(function()
    neostar.setup({ debounce_ms = 100 })
  end)
  after_each(function()
    vim.cmd("silent! %bwipeout!")
    util.cleanup()
  end)

  it_fstar("checks, verifies, keeps verified prefix, and answers queries", function()
    local b, s = edit("src/Main.fst")
    assert.equals(project, s.root)
    assert.same({ "fstar.exe", "--ide", project .. "/src/Main.fst", "--warn_error", "-241", "--include", project .. "/lib" }, s.cmd)

    -- open: lax
    wait_idle(s, function()
      return #s.fragments == 5
    end)
    assert.same({ "lax", "lax", "lax", "lax", "lax" }, util.statuses(s))
    assert.equals(0, #vim.diagnostic.get(b))

    -- verify
    vim.cmd("NeostarVerify")
    wait_idle(s, function()
      return util.statuses(s)[5] == "verified"
    end)
    assert.same({ "verified", "verified", "verified", "verified", "verified" }, util.statuses(s))

    -- edit the last declaration: the prefix stays verified
    vim.api.nvim_buf_set_lines(b, 8, 9, false, { "let three : nat = succ (succ 1)" })
    util.wait(function()
      return s.running ~= nil or util.statuses(s)[5] == "lax"
    end, T)
    wait_idle(s, function()
      return util.statuses(s)[5] == "lax"
    end)
    assert.same({ "verified", "verified", "verified", "verified", "lax" }, util.statuses(s))

    -- hover on a dependency symbol, with documentation
    local h = req(b, "textDocument/hover", 4, 17) -- "succ" in "let two : nat = succ 1"
    assert.is_not_nil(h)
    assert.matches("Lib.succ", h.contents.value, 1, true)
    assert.matches("x: nat -> nat", h.contents.value, 1, true)

    -- go to definition in the dependency
    vim.api.nvim_win_set_cursor(0, { 5, 17 })
    vim.lsp.buf.definition()
    util.wait(function()
      return vim.api.nvim_buf_get_name(0) == project .. "/lib/Lib.fst"
    end, T)
    assert.equals(4, vim.api.nvim_win_get_cursor(0)[1])
    vim.cmd("buffer " .. b)

    -- completion of a name defined in the buffer
    vim.api.nvim_buf_set_lines(b, -1, -1, false, { "", "let four = thr" })
    util.wait(function()
      return s.running ~= nil
    end, T)
    wait_idle(s)
    local c = req(b, "textDocument/completion", 10, 14)
    local labels = {}
    for _, item in ipairs(c.items) do
      labels[item.label] = true
    end
    assert.is_true(labels["three"])
    -- module-qualified name from a project dependency
    vim.api.nvim_buf_set_lines(b, 10, 11, false, { "let four = Lib.su" })
    util.wait(function()
      return s.running ~= nil
    end, T)
    wait_idle(s)
    c = req(b, "textDocument/completion", 10, 17)
    labels = {}
    for _, item in ipairs(c.items) do
      labels[item.label] = true
    end
    assert.is_true(labels["Lib.succ"])
    vim.api.nvim_buf_set_lines(b, 9, -1, false, {})
    util.wait(function()
      return s.running ~= nil
    end, T)
    wait_idle(s)

    -- compute
    local result
    neostar.compute("succ two", function(status, resp)
      result = { status, resp }
    end)
    util.wait(function()
      return result ~= nil
    end, T)
    assert.equals("success", result[1])
    assert.matches("^3", result[2])
    vim.cmd("close")

    -- a type error becomes a diagnostic and the declaration fails
    vim.api.nvim_buf_set_lines(b, 8, 9, false, { "let three : bool = succ two" })
    util.wait(function()
      return s.running ~= nil
    end, T)
    wait_idle(s, function()
      return util.statuses(s)[5] == "failed" and #vim.diagnostic.get(b) > 0
    end)
    assert.equals("failed", util.statuses(s)[5])
    assert.equals(vim.diagnostic.severity.ERROR, vim.diagnostic.get(b)[1].severity)
    assert.equals(8, vim.diagnostic.get(b)[1].lnum)
  end)

  it_fstar("reloads dependencies after a dependency is written", function()
    local ok, err = pcall(function()
      local b, s = edit("src/Main.fst")
      wait_idle(s, function()
        return #s.fragments == 5
      end)
      local lb = edit("lib/Lib.fst")
      local ls = neostar.session(lb)
      wait_idle(ls)
      local spawned_before = s.transport
      -- change succ's type in a way lax checking sees (nat -> bool);
      -- Main must notice once Lib is written
      vim.api.nvim_buf_set_lines(lb, 3, 4, false, { "let succ (x:nat) : bool = x > 0" })
      vim.cmd("silent write")
      util.wait(function()
        return s.transport ~= spawned_before
      end, T, "Main's checker should restart")
      wait_idle(s, function()
        return #vim.diagnostic.get(b) > 0
      end)
      assert.matches("bool", vim.diagnostic.get(b)[1].message)
      assert.equals("failed", util.statuses(s)[3])
    end)
    assert(ok, err)
  end)

  it_fstar("lax-checks Pulse files", function()
    local _, s = edit("src/Hello.fst")
    wait_idle(s, function()
      return #s.fragments >= 2
    end)
    for _, st in ipairs(util.statuses(s)) do
      assert.equals("lax", st)
    end
  end)

  it_fstar("cancels a long verification", function()
    local _, s = edit("src/Many.fst")
    wait_idle(s, function()
      return #s.fragments > 100
    end)
    vim.cmd("NeostarVerify")
    util.wait(function()
      local sum = s:summary()
      return sum.verified > 20
    end, T)
    vim.cmd("NeostarCancel")
    wait_idle(s)
    local sum = s:summary()
    assert.is_true(sum.verified > 20)
    assert.is_true(sum.unchecked > 0, "cancel should leave declarations unchecked")
    assert.is_true(s.alive)
  end)
end)
