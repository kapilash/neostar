local aw = require("neostar.ui.agent_window")

describe("agent window", function()
  it("opens without ftplugin errors when the Markdown parser is missing", function()
    local add = vim.treesitter.language.add
    vim.treesitter.language.add = function(lang, ...)
      if lang == "markdown" then
        return false
      end
      return add(lang, ...)
    end
    vim.v.errmsg = ""
    local w = aw.open({ title = "Explain" })
    vim.treesitter.language.add = add
    assert.equals("", vim.v.errmsg)
    assert.equals("markdown", vim.bo[w.buf].filetype)
    w:append("plain Markdown still works")
    assert.equals("plain Markdown still works", w:text())
    w:close()
  end)

  it("streams text in chunks into a focused Markdown float", function()
    local w = aw.open({ title = "Explain" })
    assert.equals(w.win, vim.api.nvim_get_current_win())
    assert.equals("markdown", vim.bo[w.buf].filetype)
    w:append("Hello ")
    w:append("world.\n\nSecond")
    w:append(" paragraph.")
    assert.equals("Hello world.\n\nSecond paragraph.", w:text())
    assert.is_false(vim.bo[w.buf].modifiable)
    w:close()
  end)

  it("closes with q and calls on_close (which stops a run)", function()
    local closed = 0
    local w = aw.open({
      title = "Explain",
      on_close = function()
        closed = closed + 1
      end,
    })
    vim.api.nvim_feedkeys("q", "x", false)
    assert.is_false(w:is_open())
    assert.equals(1, closed)
    w:close()
    assert.equals(1, closed)
  end)

  it("asks a follow-up question with f", function()
    local asked
    local orig = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("why?")
    end
    local w = aw.open({
      title = "Explain",
      on_followup = function(q)
        asked = q
      end,
    })
    vim.api.nvim_feedkeys("f", "x", false)
    vim.ui.input = orig
    assert.equals("why?", asked)
    w:close()
  end)

  it("shows a status in the border", function()
    local w = aw.open({ title = "Prove" })
    w:set_status("attempt 3/10")
    local footer = vim.api.nvim_win_get_config(w.win).footer
    local text = type(footer) == "table" and footer[1][1] or footer
    assert.matches("attempt 3/10", text, 1, true)
    w:close()
  end)
end)
