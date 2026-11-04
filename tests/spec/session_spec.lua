local util = require("helpers.util")
local fake_fstar = require("helpers.fake_fstar")
local neostar = require("neostar")

local function kinds(fake)
  local out = {}
  for _, q in ipairs(fake:sent_of("full-buffer")) do
    table.insert(out, q.args.kind)
  end
  return out
end

local function capture_notify()
  local msgs = {}
  return msgs, function(msg, level)
    table.insert(msgs, { msg = msg, level = level })
  end
end

describe("fstar/checking-session", function()
  after_each(function()
    neostar._default_overrides = nil
    util.cleanup()
  end)

  describe("checker failure", function()
    it("names the executable that could not be started", function()
      local msgs, notify = capture_notify()
      local b = util.open_fixture("Clean.fst")
      local s = neostar.attach(b, { cmd = { "/nonexistent/fstar.exe", "--ide", "x" }, notify = notify })
      assert.is_false(s.alive)
      assert.equals(1, #msgs)
      assert.matches("/nonexistent/fstar.exe", msgs[1].msg, 1, true)
    end)

    it("reports an exit mid-check with stderr and recovers with :NeostarRestart", function()
      local msgs, notify = capture_notify()
      local b = util.open_fixture("Clean.fst")
      local s, fake = util.attach_fake(b, "clean", { auto = false }, { notify = notify })
      util.wait(function()
        return #fake.queue > 0
      end)
      fake:pump(4)
      fake:exit(2, "Fatal error: out of memory\n")
      util.wait(function()
        return not s.alive
      end)
      assert.matches("out of memory", msgs[#msgs].msg, 1, true)
      assert.matches("NeostarRestart", msgs[#msgs].msg, 1, true)
      assert.is_nil(s.running)

      fake.auto = true
      vim.cmd("NeostarRestart")
      util.wait(function()
        return s.alive and util.idle(s) and #s.fragments == 4 and util.statuses(s)[4] == "lax"
      end)
      assert.equals(2, fake.spawned)
      assert.same({ "lax", "lax" }, kinds(fake))
    end)
  end)

  describe("lax checking", function()
    it("lax-checks a buffer when it is opened", function()
      local b = util.open_fixture("Clean.fst")
      local s, fake = util.attach_fake(b, "clean")
      util.wait(function()
        return util.idle(s) and #s.fragments == 4
      end)
      assert.same({ "lax" }, kinds(fake))
      assert.same({ "lax", "lax", "lax", "lax" }, util.statuses(s))
      assert.matches("module Clean", fake:sent_of("full-buffer")[1].args.code, 1, true)
    end)

    it("lax-checks after edits pause", function()
      local b = util.open_fixture("TypeErr.fst")
      local s, fake = util.attach_fake(b, "typeerr")
      util.wait(function()
        return util.idle(s) and #s.fragments == 3
      end)
      util.set_text_from(b, "TypeErr_fixed.fst")
      util.wait(function()
        return #fake:sent_of("full-buffer") == 2 and util.idle(s)
      end)
      assert.same({ "lax", "lax" }, kinds(fake))
      assert.matches("x > 0", fake:sent_of("full-buffer")[2].args.code, 1, true)
      assert.same({ "lax", "lax", "lax", "lax" }, util.statuses(s))
    end)

    it("cancels a running check on edit and lax-checks after the pause", function()
      local b = util.open_fixture("TypeErr.fst")
      local s, fake = util.attach_fake(b, "typeerr", { auto = false })
      util.wait(function()
        return #fake.queue > 0
      end)
      fake:pump(4)
      fake.auto = true
      util.set_text_from(b, "TypeErr_fixed.fst")
      util.wait(function()
        return #fake:sent_of("cancel") == 1
      end)
      util.wait(function()
        return #fake:sent_of("full-buffer") == 2 and util.idle(s)
      end)
      assert.same({ "lax", "lax" }, kinds(fake))
    end)

    it("does not check again on repeated saves", function()
      local b = util.open_fixture("Clean.fst")
      local s, fake = util.attach_fake(b, "clean")
      util.wait(function()
        return util.idle(s) and #s.fragments == 4
      end)
      for _ = 1, 3 do
        vim.api.nvim_exec_autocmds("BufWritePost", { buffer = b })
      end
      vim.wait(100)
      assert.same({ "lax" }, kinds(fake))
    end)
  end)

  describe("explicit verification", function()
    it(":NeostarVerify fully verifies every declaration", function()
      local b = util.open_fixture("Clean.fst")
      local s, fake = util.attach_fake(b, "clean")
      util.wait(function()
        return util.idle(s) and #s.fragments == 4
      end)
      vim.cmd("NeostarVerify")
      util.wait(function()
        return util.idle(s) and util.statuses(s)[4] == "verified"
      end)
      assert.same({ "lax", "full" }, kinds(fake))
      assert.same({ "verified", "verified", "verified", "verified" }, util.statuses(s))
    end)

    it(":NeostarVerify reports SMT failures as failed", function()
      local b = util.open_fixture("SmtFail.fst")
      local s = util.attach_fake(b, "smtfail")
      util.wait(function()
        return util.idle(s) and #s.fragments == 3
      end)
      vim.cmd("NeostarVerify")
      util.wait(function()
        return util.idle(s) and util.statuses(s)[3] == "failed"
      end)
      assert.same({ "verified", "verified", "failed" }, util.statuses(s))
    end)

    it(":NeostarVerifyToCursor verifies up to the cursor only", function()
      local b = util.open_fixture("Ten.fst")
      local s, fake = util.attach_fake(b, "vtp")
      util.wait(function()
        return util.idle(s) and #s.fragments == 10
      end)
      vim.api.nvim_win_set_cursor(0, { 9, 5 }) -- inside the fifth declaration (d4)
      vim.cmd("NeostarVerifyToCursor")
      util.wait(function()
        return #fake:sent_of("full-buffer") >= 3 and util.idle(s)
      end)
      local vtp = fake:sent_of("full-buffer")[2]
      assert.equals("verify-to-position", vtp.args.kind)
      assert.same({ line = 9, column = 5 }, vtp.args["to-position"])
      local st = util.statuses(s)
      for i = 1, 5 do
        assert.equals("verified", st[i], "declaration " .. i)
      end
      for i = 6, #st do
        assert.equals("lax", st[i], "declaration " .. i)
      end
      assert.same({ "lax", "verify-to-position", "lax" }, kinds(fake))
    end)
  end)

  describe("verification retained across lax checks", function()
    it("keeps declarations above an edit verified", function()
      local b = util.open_fixture("Ten.fst")
      local s, fake = util.attach_fake(b, "ten")
      util.wait(function()
        return util.idle(s) and #s.fragments == 10
      end)
      vim.cmd("NeostarVerify")
      util.wait(function()
        return util.idle(s) and util.statuses(s)[10] == "verified"
      end)
      s.debounce_ms = 1000
      -- edit the 8th declaration (d7, line 15)
      vim.api.nvim_buf_set_lines(b, 14, 15, false, { "let d7 (x:int) : int = x + 7 + 0" })
      util.wait(function()
        return util.status_at(s, 14) == "unreached"
      end, 1000, "edited declaration should lose its status immediately")
      assert.equals("unreached", util.status_at(s, 16))
      assert.equals("unreached", util.status_at(s, 18))
      util.wait(function()
        return #fake:sent_of("full-buffer") == 3 and util.idle(s)
      end)
      local st = util.statuses(s)
      for i = 1, 7 do
        assert.equals("verified", st[i], "declaration " .. i)
      end
      for i = 8, 10 do
        assert.equals("lax", st[i], "declaration " .. i)
      end
    end)

    it("invalidates the suffix when inserting between declarations", function()
      local b = util.open_fixture("Ten.fst")
      local s = util.attach_fake(b, "ten")
      util.wait(function() return util.idle(s) end)
      s:check("full")
      util.wait(function() return util.idle(s) and util.statuses(s)[10] == "verified" end)
      s.debounce_ms = 10000
      vim.api.nvim_buf_set_lines(b, 13, 13, false, { "let inserted = 0" })
      util.wait(function() return util.status_at(s, 15) == "unreached" end)
      assert.equals("verified", util.status_at(s, 12))
      assert.equals("unreached", util.status_at(s, 17))
      assert.equals("unreached", util.status_at(s, 19))
    end)
  end)

  describe("cancelling", function()
    it(":NeostarCancel stops the check; unchecked declarations are not reached", function()
      local b = util.open_fixture("Many.fst")
      local s, fake = util.attach_fake(b, "cancel", { auto = false, any_kind = true })
      util.wait(function()
        return #fake.queue > 40
      end)
      fake:pump(40)
      util.wait(function()
        return #s.fragments > 5 and s.current_fragment ~= nil
      end)
      vim.cmd("NeostarCancel")
      fake:pump()
      util.wait(function()
        return util.idle(s)
      end)
      assert.equals(1, #fake:sent_of("cancel"))
      local st = util.statuses(s)
      assert.is_true(#st > 5)
      for _, x in ipairs(st) do
        assert.are_not.equal("inflight", x)
      end
      vim.wait(100)
      assert.equals(1, #fake:sent_of("full-buffer"), "no new check after a user cancel")
    end)

    it("offers to kill and restart when F* does not stop", function()
      local b = util.open_fixture("Many.fst")
      local offered = 0
      local s, fake = util.attach_fake(b, "cancel", { auto = false, on_cancel = "hang", any_kind = true }, {
        confirm_kill = function(kill)
          offered = offered + 1
          kill()
        end,
      })
      util.wait(function()
        return #fake.queue > 40
      end)
      fake:pump(40)
      vim.cmd("NeostarCancel")
      util.wait(function()
        return offered == 1
      end, 3000)
      util.wait(function()
        return fake.spawned == 2
      end)
      assert.is_true(s.alive)
    end)
  end)

  describe("edit immediately followed by a check", function()
    it("does not cancel a check that already contains the edit", function()
      local b = util.open_fixture("Clean.fst")
      local s, fake = util.attach_fake(b, "clean")
      util.wait(function()
        return util.idle(s) and #s.fragments == 4
      end)
      -- edit and verify in the same event-loop turn (e.g. a mapping, or
      -- applying an agent's proof and verifying right away)
      vim.api.nvim_buf_set_lines(b, 1, 2, false, { "" })
      vim.cmd("NeostarVerify")
      util.wait(function()
        return util.idle(s) and util.statuses(s)[4] == "verified"
      end)
      assert.equals(0, #fake:sent_of("cancel"))
      assert.same({ "verified", "verified", "verified", "verified" }, util.statuses(s))
    end)
  end)

  describe("on-disk changes", function()
    it("lax-checks a buffer reloaded after an external write", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/Clean.fst"
      vim.fn.writefile(vim.fn.readfile(fake_fstar.file("Clean.fst")), path)
      local fake = fake_fstar.new(fake_fstar.transcript("clean"))
      neostar._default_overrides = { transport_factory = fake:factory(), debounce_ms = 30, ping_interval_ms = 20 }
      vim.o.autoread = true
      vim.cmd.edit(path)
      local s = neostar.session(0)
      util.wait(function()
        return s and util.idle(s) and #s.fragments == 4
      end)
      -- an "agent" rewrites the file
      local lines = vim.fn.readfile(path)
      table.insert(lines, "")
      table.insert(lines, "let extra = 1")
      vim.uv.sleep(1100) -- make sure the mtime changes
      vim.fn.writefile(lines, path)
      vim.cmd("checktime")
      util.wait(function()
        return #fake:sent_of("full-buffer") == 2 and util.idle(s)
      end)
      assert.same({ "lax", "lax" }, kinds(fake))
      assert.matches("let extra = 1", fake:sent_of("full-buffer")[2].args.code, 1, true)
    end)
  end)

  describe("dependencies", function()
    it("writing a dependency reloads dependents in the same project", function()
      local a = util.open_fixture("DepA.fst")
      local sa, fa = util.attach_fake(a, "deps")
      local bb = util.open_fixture("DepB.fst")
      local sb = util.attach_fake(bb, "deps")
      util.wait(function()
        return util.idle(sa) and util.idle(sb) and #sa.fragments == 3
      end)
      vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bb })
      util.wait(function()
        return fa.spawned == 2 and #fa:sent_of("full-buffer") == 2 and util.idle(sa)
      end)
      -- a fresh checker re-reads the dependency and lax-checks the dependent
      assert.same({ "lax", "lax" }, kinds(fa))
      assert.is_true(sa.alive)
    end)

    it(":NeostarReloadDeps re-checks the current buffer", function()
      local a = util.open_fixture("DepA.fst")
      local sa, fa = util.attach_fake(a, "deps")
      util.wait(function()
        return util.idle(sa) and #sa.fragments == 3
      end)
      vim.cmd("NeostarReloadDeps")
      util.wait(function()
        return fa.spawned == 2 and #fa:sent_of("full-buffer") == 2 and util.idle(sa)
      end)
      assert.same({ "lax", "lax" }, kinds(fa))
    end)
  end)

  describe("lifecycle", function()
    it("stops the checker when the buffer is deleted", function()
      local b = util.open_fixture("Clean.fst")
      local s, fake = util.attach_fake(b, "clean")
      util.wait(function()
        return util.idle(s)
      end)
      vim.cmd("bdelete! " .. b)
      assert.is_true(fake.exited)
      assert.is_nil(neostar.session(b))
    end)

    it("serves split windows with one checker", function()
      local b = util.open_fixture("Clean.fst")
      local s, fake = util.attach_fake(b, "clean")
      vim.cmd("split")
      vim.api.nvim_exec_autocmds("FileType", { buffer = b, modeline = false, data = {} })
      neostar.attach(b)
      util.wait(function()
        return util.idle(s)
      end)
      assert.equals(1, fake.spawned)
      assert.equals(s, neostar.session(b))
      vim.cmd("only")
    end)
  end)
end)
