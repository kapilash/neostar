local util = require("helpers.util")
local fake_fstar = require("helpers.fake_fstar")

local function captures(bufnr, row, col)
  local out = {}
  for _, c in ipairs(vim.treesitter.get_captures_at_pos(bufnr, row, col)) do
    out[c.capture .. "@" .. c.lang] = true
  end
  return out
end

describe("fstar/syntax", function()
  after_each(util.cleanup)

  describe("filetype detection", function()
    it("detects .fst as fstar", function()
      assert.equals("fstar", vim.filetype.match({ filename = fake_fstar.file("Clean.fst") }))
    end)

    it("detects .fsti as fstar", function()
      assert.equals("fstar", vim.filetype.match({ filename = "/tmp/Foo.fsti" }))
    end)
  end)

  describe("highlighting", function()
    local bufnr
    before_each(function()
      bufnr = util.open_fixture("PulseMix.fst")
      assert.is_true(require("neostar.treesitter").start(bufnr))
      vim.treesitter.get_parser(bufnr):parse(true)
    end)

    it("highlights F* keywords and treats fn as an identifier in F*", function()
      -- line 3: "let fn = 1"
      assert.is_true(captures(bufnr, 2, 0)["keyword@fstar"])
      assert.is_nil(captures(bufnr, 2, 4)["keyword@fstar"])
      assert.is_nil(captures(bufnr, 2, 4)["keyword@pulse"])
    end)

    it("highlights a #lang-pulse tail with Pulse rules", function()
      -- line 8: "fn incr (r:ref int)"
      assert.is_true(captures(bufnr, 7, 0)["keyword@pulse"])
      -- line 9: "  requires ..."
      assert.is_true(captures(bufnr, 8, 2)["keyword@pulse"])
    end)

    it("switches back to F* after #lang-fstar", function()
      -- line 17: "let after (x:int) : int = x"
      local c = captures(bufnr, 16, 0)
      assert.is_true(c["keyword@fstar"])
    end)

    it("works without an F* process", function()
      -- no session attached in this block; highlighting came from tree-sitter alone
      assert.is_nil(require("neostar").session(bufnr))
      assert.is_true(vim.treesitter.highlighter.active[bufnr] ~= nil)
    end)
  end)

  describe("missing grammar", function()
    it("notifies once and keeps other features working", function()
      local ts = require("neostar.treesitter")
      ts._reset_warning()
      local orig_add = vim.treesitter.language.add
      local orig_notify = vim.notify
      local warnings = 0
      vim.treesitter.language.add = function()
        return nil, 'No parser for language "fstar"'
      end
      vim.notify = function(msg, level)
        if level == vim.log.levels.WARN and msg:match("tree%-sitter parser for F%*") then
          warnings = warnings + 1
        end
      end
      local ok, err = pcall(function()
        local b1 = util.open_fixture("Clean.fst")
        local s1 = util.attach_fake(b1, "clean")
        local b2 = util.open_fixture("TypeErr.fst")
        local s2 = util.attach_fake(b2, "typeerr")
        assert.is_not_nil(s1)
        assert.is_not_nil(s2)
        util.wait(function()
          return util.idle(s1) and #s1.fragments > 0
        end)
      end)
      vim.treesitter.language.add = orig_add
      vim.notify = orig_notify
      assert(ok, err)
      assert.equals(1, warnings)
    end)
  end)
end)
