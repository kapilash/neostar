local util = require("helpers.util")
local fake_fstar = require("helpers.fake_fstar")

local function req(bufnr, method, row, col)
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = row, character = col },
  }
  local res = vim.lsp.buf_request_sync(bufnr, method, params, 2000)
  assert(res, "no LSP response")
  local _, r = next(res)
  assert(r, "no LSP response")
  assert(not r.err, r.err and r.err.message)
  return r.result
end

local function open_clean(extra_lines, fake_opts)
  local b = util.open_fixture("Clean.fst")
  if extra_lines then
    vim.api.nvim_buf_set_lines(b, -1, -1, false, extra_lines)
  end
  local s, fake = util.attach_fake(b, "clean", fake_opts)
  util.wait(function()
    return util.idle(s) and #s.fragments == 4
  end)
  return b, s, fake
end

describe("fstar/code-intelligence and diagnostics (LSP shim)", function()
  after_each(util.cleanup)

  describe("client", function()
    it("attaches one in-process neostar client per buffer", function()
      local b = open_clean()
      local clients = vim.lsp.get_clients({ bufnr = b })
      assert.equals(1, #clients)
      local c = clients[1]
      assert.equals("neostar", c.name)
      assert.is_true(c.server_capabilities.hoverProvider)
      assert.is_true(c.server_capabilities.definitionProvider)
      assert.is_not_nil(c.server_capabilities.completionProvider)
      -- a second F* buffer gets its own client
      local b2 = util.open_fixture("TypeErr.fst")
      local s2 = util.attach_fake(b2, "typeerr")
      util.wait(function()
        return util.idle(s2) and #vim.lsp.get_clients({ bufnr = b2 }) > 0
      end)
      local c2 = vim.lsp.get_clients({ bufnr = b2 })
      assert.equals(1, #c2)
      assert.equals(1, #vim.lsp.get_clients({ bufnr = b }))
      assert.are_not.equal(c.id, c2[1].id)
    end)
  end)

  describe("diagnostics", function()
    it("publishes F* errors with range, severity and error number", function()
      local b = util.open_fixture("TypeErr.fst")
      local s = util.attach_fake(b, "typeerr")
      util.wait(function()
        return util.idle(s) and #vim.diagnostic.get(b) > 0
      end)
      local d = vim.diagnostic.get(b)
      assert.equals(1, #d)
      assert.equals(vim.diagnostic.severity.ERROR, d[1].severity)
      assert.equals(4, d[1].lnum)
      assert.equals(25, d[1].col)
      assert.equals(26, d[1].end_col)
      assert.equals(189, d[1].code)
      assert.matches("Expected expression of type bool", d[1].message)
    end)

    it("removes an error once it is fixed", function()
      local b = util.open_fixture("TypeErr.fst")
      local s, fake = util.attach_fake(b, "typeerr")
      util.wait(function()
        return util.idle(s) and #vim.diagnostic.get(b) == 1
      end)
      util.set_text_from(b, "TypeErr_fixed.fst")
      util.wait(function()
        return #fake:sent_of("full-buffer") == 2 and util.idle(s) and #vim.diagnostic.get(b) == 0
      end)
    end)

    it("attaches issues from other files to the first line, naming the location", function()
      local b = util.open_fixture("DepA.fst")
      local s = util.attach_fake(b, "deps")
      util.wait(function()
        return util.idle(s) and #vim.diagnostic.get(b) > 0
      end)
      local d = vim.diagnostic.get(b)[1]
      assert.equals(0, d.lnum)
      assert.equals(vim.diagnostic.severity.WARN, d.severity)
      assert.matches("^DepB%.fst%(0,0%)", d.message)
      assert.equals(241, d.code)
    end)

    it("reports parse errors", function()
      local b = util.open_fixture("ParseErr.fst")
      local s = util.attach_fake(b, "parseerr")
      util.wait(function()
        return util.idle(s) and #vim.diagnostic.get(b) > 0
      end)
      local d = vim.diagnostic.get(b)[1]
      assert.matches("Syntax error", d.message)
      assert.equals(168, d.code)
    end)

    it("maps non-ASCII columns to bytes", function()
      local b = util.open_fixture("Unicode.fst")
      local s = util.attach_fake(b, "unicode")
      util.wait(function()
        return util.idle(s) and #vim.diagnostic.get(b) > 0
      end)
      local d = vim.diagnostic.get(b)[1]
      local line = vim.api.nvim_buf_get_lines(b, 4, 5, false)[1]
      assert.equals(line:find("αβγ", 1, true) - 1, d.col)
    end)
  end)

  describe("hover", function()
    it("shows qualified name and type of a library symbol", function()
      local b = open_clean()
      -- line 8: "let len (#a:Type) (l:list a) : nat = List.Tot.length l"
      local r = req(b, "textDocument/hover", 7, 45)
      assert.matches("FStar.List.Tot.Base.length", r.contents.value, 1, true)
      assert.matches("list 'a -> nat", r.contents.value, 1, true)
    end)

    it("shows the type of a local definition", function()
      local b = open_clean()
      local r = req(b, "textDocument/hover", 7, 5)
      assert.matches("Clean.len : l: list a -> nat", r.contents.value, 1, true)
    end)

    it("shows nothing for unknown symbols, without errors", function()
      local b = open_clean({ "", "(* nosuchthing *)" })
      local notified = false
      local orig = vim.notify
      vim.notify = function()
        notified = true
      end
      local r = req(b, "textDocument/hover", 9, 5)
      vim.notify = orig
      assert.is_nil(r)
      assert.is_false(notified)
    end)
  end)

  describe("go to definition", function()
    it("moves the cursor to a definition in the same buffer", function()
      local b = open_clean({ "", "let use_len = len [1]" })
      vim.api.nvim_win_set_cursor(0, { 10, 15 })
      local s = require("neostar").session(b)
      util.wait(function()
        return util.idle(s)
      end)
      vim.lsp.buf.definition()
      util.wait(function()
        local c = vim.api.nvim_win_get_cursor(0)
        return c[1] == 8 and c[2] == 4
      end)
    end)

    it("opens the file that defines a library symbol", function()
      local tr = fake_fstar.transcript("clean")
      -- point the recorded library lookup at a file that exists here
      tr.steps[3].recv[1].response["defined-at"] = {
        fname = fake_fstar.file("DepB.fst"),
        beg = { 3, 4 },
        ["end"] = { 3, 5 },
      }
      local b = util.open_fixture("Clean.fst")
      local fake = fake_fstar.new(tr)
      local s = require("neostar").attach(b, { transport_factory = fake:factory(), ping_interval_ms = 20 })
      util.wait(function()
        return util.idle(s) and #s.fragments == 4
      end)
      vim.api.nvim_win_set_cursor(0, { 8, 45 })
      vim.lsp.buf.definition()
      util.wait(function()
        return vim.api.nvim_buf_get_name(0) == fake_fstar.file("DepB.fst")
      end)
      assert.same({ 3, 4 }, vim.api.nvim_win_get_cursor(0))
    end)

    it("leaves the cursor in place when no definition is known", function()
      local b = open_clean({ "", "(* nosuchthing *)" })
      vim.api.nvim_win_set_cursor(0, { 10, 5 })
      local msgs = {}
      local orig = vim.notify
      vim.notify = function(m)
        table.insert(msgs, m)
      end
      vim.lsp.buf.definition()
      util.wait(function()
        return #msgs > 0
      end)
      vim.notify = orig
      assert.same({ 10, 5 }, vim.api.nvim_win_get_cursor(0))
      assert.equals(b, vim.api.nvim_get_current_buf())
      assert.matches("[Nn]o locations found", msgs[1])
    end)
  end)

  describe("completion", function()
    it("completes names defined in the buffer", function()
      local b = open_clean({ "", "let z = dou" })
      local r = req(b, "textDocument/completion", 9, 11)
      local labels = {}
      for _, item in ipairs(r.items) do
        labels[item.label] = item
      end
      assert.is_not_nil(labels["double"])
      assert.is_nil(labels["dou"], "the <search term> echo is not a candidate")
      assert.same({ line = 9, character = 8 }, labels["double"].textEdit.range.start)
    end)

    it("completes module-qualified names from project dependencies", function()
      local tr = fake_fstar.transcript("clean")
      table.insert(tr.steps, {
        send = { ["query-id"] = "90", query = "autocomplete", args = { ["partial-symbol"] = "Lib.su", context = "code" } },
        recv = {
          {
            kind = "response",
            ["query-id"] = "90",
            status = "success",
            response = { { 6, "Lib", "Lib.succ" }, { 0, "<search term>", "Lib.su" } },
          },
        },
      })
      local b = util.open_fixture("Clean.fst")
      vim.api.nvim_buf_set_lines(b, -1, -1, false, { "", "let z = Lib.su" })
      local fake = fake_fstar.new(tr)
      local s = require("neostar").attach(b, { transport_factory = fake:factory(), ping_interval_ms = 20 })
      util.wait(function()
        return util.idle(s) and #s.fragments == 4
      end)
      local r = req(b, "textDocument/completion", 9, 14)
      assert.equals(1, #r.items)
      local item = r.items[1]
      assert.equals("Lib.succ", item.label)
      assert.equals("Lib", item.detail)
      assert.equals("Lib.su", fake:sent_of("autocomplete")[1].args["partial-symbol"])
      -- the edit replaces the whole qualified prefix
      assert.same({ line = 9, character = 8 }, item.textEdit.range.start)
      assert.same({ line = 9, character = 14 }, item.textEdit.range["end"])
    end)
  end)

  describe("busy checker", function()
    it("answers hover promptly during full verification without cancelling it", function()
      local b, s, fake = open_clean()
      fake.auto = false
      vim.cmd("NeostarVerify")
      util.wait(function()
        return s.running == "full"
      end)
      local t0 = vim.uv.hrtime()
      local r = req(b, "textDocument/hover", 7, 5)
      local ms = (vim.uv.hrtime() - t0) / 1e6
      assert.is_nil(r)
      assert.is_true(ms < 500, "hover took " .. ms .. "ms")
      assert.equals("full", s.running)
      assert.equals(0, #fake:sent_of("cancel"))
      fake:pump()
      util.wait(function()
        return util.idle(s)
      end)
    end)

    it("waits for a running lax check, then answers", function()
      local b, s, fake = open_clean()
      fake.auto = false
      vim.api.nvim_buf_set_lines(b, -1, -1, false, { "" })
      util.wait(function()
        return s.running == "lax"
      end)
      local result
      vim.lsp.buf_request(b, "textDocument/hover", {
        textDocument = { uri = vim.uri_from_bufnr(b) },
        position = { line = 7, character = 5 },
      }, function(_, r)
        result = r or false
      end)
      vim.wait(50)
      assert.is_nil(result)
      fake.auto = true
      fake:pump()
      util.wait(function()
        return result ~= nil
      end)
      assert.matches("Clean.len", result.contents.value, 1, true)
    end)
  end)
end)
