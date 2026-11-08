local browse = require("neostar.docs_browse")
local fstardoc = require("neostar.fstardoc")

local fixture = vim.fn.getcwd() .. "/tests/fixtures/docs/mini.index.json"

describe("documentation browsing", function()
  local saved_lib_dirs, saved_select

  before_each(function()
    require("neostar").setup({ agent = { docs = { index = fixture } } })
    saved_lib_dirs, saved_select = browse.library_dirs, vim.ui.select
    browse.library_dirs = function()
      return {}
    end
  end)

  after_each(function()
    browse.library_dirs, vim.ui.select = saved_lib_dirs, saved_select
    fstardoc.clear()
    vim.cmd("silent! %bwipeout!")
    require("neostar").setup()
  end)

  it("reads the configured index even when agent retrieval is disabled", function()
    local idx = assert(browse.index())
    assert.equals(5, #browse.declarations(idx))
    assert.equals(2, #browse.declarations(idx, "Demo.List"))
    local none, err = browse.declarations(idx, "Nope")
    assert.is_nil(none)
    assert.matches("no module Nope", err)
  end)

  it("previews signature, documentation, contract and definition", function()
    local idx = assert(browse.index())
    local text = table.concat(browse.preview_lines(idx.by_name["Demo.Seq.lemma_len_slice"]), "\n")
    assert.matches("^# Demo.Seq.lemma_len_slice", text)
    assert.matches("effect `Lemma` · Demo.Seq.fsti:9", text, 1, true)
    assert.matches("Slicing gives\nthe expected length.", text, 1, true)
    assert.matches("**Ensures about:** `Demo.Seq.length`, `Demo.Seq.slice`", text, 1, true)
    local undocumented = table.concat(browse.preview_lines(idx.by_name["Demo.List.length"]), "\n")
    assert.matches("_Undocumented.", undocumented, 1, true)
    assert.matches("```fstar\nmatch l with", undocumented, 1, true)
    assert.is_nil(undocumented:find("Requires about", 1, true))
  end)

  it("finds source files through the project's include_dirs and opens the range", function()
    local root = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()))
    vim.fn.mkdir(root .. "/src", "p")
    vim.fn.mkdir(root .. "/vendor", "p")
    vim.fn.writefile({ '{"include_dirs": ["vendor"]}' }, root .. "/P.fst.config.json")
    vim.fn.writefile({ "module Demo.Seq", "", "val length : int", "", "  val slice : int" }, root .. "/vendor/Demo.Seq.fsti")
    local from = root .. "/src/Main.fst"
    local idx = assert(browse.index())
    local d = idx.by_name["Demo.Seq.slice"]
    assert.equals(root .. "/vendor/Demo.Seq.fsti", browse.locate(d, from))
    assert.is_true(browse.open(d, from))
    assert.equals(root .. "/vendor/Demo.Seq.fsti", vim.api.nvim_buf_get_name(0))
    assert.same({ 5, 0 }, vim.api.nvim_win_get_cursor(0))
    assert.is_nil(browse.locate(idx.by_name["Demo.List.incr"], from)) -- no range in the index
    vim.fn.delete(root, "rf")
  end)

  it("falls back to vim.ui.select without Telescope", function()
    local items, formatted
    vim.ui.select = function(list, opts, on_choice)
      items = list
      formatted = opts.format_item(list[1])
      on_choice(nil)
    end
    browse.select("Demo.Seq")
    assert.equals(3, #items)
    assert.equals("val   Demo.Seq.length : s: Demo.Seq.seq a -> Prims.nat", formatted)
  end)

  it("completes module names", function()
    assert.same({ "Demo.List", "Demo.Seq" }, browse.complete("Demo."))
    assert.same({ "Demo.Seq" }, browse.complete("Demo.S"))
  end)
end)
