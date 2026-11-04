local util = require("helpers.util")
local signs = require("neostar.ui.signs")
local neostar = require("neostar")

local function render_now(s)
  s.render_signs_now()
  return signs.placed(s.bufnr)
end

describe("fstar/verification-status", function()
  after_each(util.cleanup)

  describe("sign column", function()
    it("marks every line of each declaration by status", function()
      local b = util.open_fixture("SmtFail.fst")
      local s = util.attach_fake(b, "smtfail")
      util.wait(function()
        return util.idle(s) and #s.fragments == 3
      end)
      vim.cmd("NeostarVerify")
      util.wait(function()
        return util.idle(s) and util.statuses(s)[3] == "failed"
      end)
      -- verify a declaration spanning lines: make decl 2 longer is not needed;
      -- module (row 0), ok (row 2), bad (row 4)
      local placed = render_now(s)
      assert.same({ text = "┃", hl = "NeostarVerified" }, placed[0])
      assert.same({ text = "┃", hl = "NeostarVerified" }, placed[2])
      assert.same({ text = "┃", hl = "NeostarFailed" }, placed[4])
      assert.is_nil(placed[1])
    end)

    it("shows mixed verified, lax-only and failed results", function()
      local b = util.open_fixture("Ten.fst")
      local s = util.attach_fake(b, "vtp")
      util.wait(function()
        return util.idle(s) and #s.fragments == 10
      end)
      vim.api.nvim_win_set_cursor(0, { 9, 5 })
      vim.cmd("NeostarVerifyToCursor")
      util.wait(function()
        return util.idle(s) and util.statuses(s)[6] == "lax" and util.statuses(s)[1] == "verified"
      end)
      local placed = render_now(s)
      assert.equals("NeostarVerified", placed[8].hl) -- d4
      assert.equals("NeostarLax", placed[10].hl) -- d5
      assert.are_not.equal(placed[8].text, placed[10].text)
    end)

    it("shows in-flight and not-reached declarations during a check", function()
      local b = util.open_fixture("Many.fst")
      local s, fake = util.attach_fake(b, "cancel", { auto = false, any_kind = true })
      util.wait(function()
        return #fake.queue > 40
      end)
      fake:pump(10)
      -- deliver one message at a time until a declaration is in flight
      util.wait(function()
        if s.current_fragment and s.current_fragment.status == "inflight" then
          return true
        end
        fake:pump(1)
        return false
      end)
      local placed = render_now(s)
      local inflight_row
      for row, p in pairs(placed) do
        if p.hl == "NeostarInflight" then
          inflight_row = row
        end
      end
      assert.is_not_nil(inflight_row)
      -- cancel: the in-flight declaration becomes not reached
      vim.cmd("NeostarCancel")
      fake:pump()
      util.wait(function()
        return util.idle(s)
      end)
      placed = render_now(s)
      assert.equals("NeostarUnreached", placed[inflight_row].hl)
    end)

    it("uses distinct default glyphs and groups for verified and lax", function()
      local d = signs.default_signs
      assert.are_not.equal(d.verified.text, d.lax.text)
      assert.are_not.equal(d.verified.hl, d.lax.hl)
    end)

    it("honours user glyph and highlight overrides", function()
      neostar.setup({ signs = { lax = { text = "L", hl = "MyLax" } } })
      local b = util.open_fixture("Clean.fst")
      local s = util.attach_fake(b, "clean")
      util.wait(function()
        return util.idle(s) and #s.fragments == 4
      end)
      local placed = render_now(s)
      assert.same({ text = "L", hl = "MyLax" }, placed[0])
      neostar.setup({})
    end)

    it("moves markers with inserted lines", function()
      local b = util.open_fixture("Clean.fst")
      local s = util.attach_fake(b, "clean")
      util.wait(function()
        return util.idle(s) and #s.fragments == 4
      end)
      assert.equals("NeostarLax", render_now(s)[2].hl)
      vim.api.nvim_buf_set_lines(b, 1, 1, false, { "", "", "" })
      local placed = render_now(s)
      assert.equals("NeostarLax", placed[5].hl) -- "let double" moved from row 2 to 5
      assert.is_nil(placed[2])
    end)

    it("drops the verified marker of an edited declaration", function()
      local b = util.open_fixture("Clean.fst")
      local s = util.attach_fake(b, "clean")
      util.wait(function()
        return util.idle(s) and #s.fragments == 4
      end)
      vim.cmd("NeostarVerify")
      util.wait(function()
        return util.idle(s) and util.statuses(s)[2] == "verified"
      end)
      vim.api.nvim_buf_set_text(b, 2, 4, 2, 10, { "twice" })
      util.wait(function()
        return util.status_at(s, 2) == "unreached"
      end)
      assert.are_not.equal("NeostarVerified", render_now(s)[2].hl)
    end)
  end)

  describe("statusline summary", function()
    it("counts lax-only separately from verified", function()
      local b = util.open_fixture("Clean.fst")
      local s = util.attach_fake(b, "clean")
      util.wait(function()
        return util.idle(s) and #s.fragments == 4
      end)
      local sum = neostar.status(b)
      assert.equals(4, sum.lax)
      assert.equals(0, sum.verified)
      assert.equals(0, sum.failed)
      assert.equals(0, sum.unchecked)
      assert.is_nil(sum.running)
      assert.equals("F* ✓0 ~4 ✗0 ?0", neostar.statusline(b))
    end)

    it("shows that a full check is in progress", function()
      local b = util.open_fixture("Clean.fst")
      local s, fake = util.attach_fake(b, "clean")
      util.wait(function()
        return util.idle(s) and #s.fragments == 4
      end)
      fake.auto = false
      vim.cmd("NeostarVerify")
      util.wait(function()
        return s.running ~= nil
      end)
      assert.equals("full", neostar.status(b).running)
      assert.matches("%[full…%]", neostar.statusline(b))
      fake:pump()
      util.wait(function()
        return util.idle(s)
      end)
    end)

    it("is empty for non-F* buffers", function()
      vim.cmd("enew")
      assert.is_nil(neostar.status(0))
      assert.equals("", neostar.statusline(0))
    end)
  end)
end)
