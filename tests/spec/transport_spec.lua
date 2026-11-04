local transport = require("neostar.fstar.transport")
local util = require("helpers.util")
local fake_fstar = require("helpers.fake_fstar")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local echo = root .. "/helpers/echo_ide.py"

describe("fstar transport", function()
  after_each(util.cleanup)

  it("converts positions in one place", function()
    assert.same({ 4, 7 }, { transport.to_buf_pos({ 5, 7 }) })
    assert.same({ 5, 7 }, { transport.to_fstar_pos(4, 7) })
    assert.equals("12", transport.root_qid("12.3"))
  end)

  it("talks to a real child process, reassembling split lines", function()
    local t = transport.new({ cmd = { "python3", "-u", echo } })
    assert.is_true(t:start())
    local msgs, resp = {}, nil
    t:request("lookup", { symbol = "αβγ" }, {
      on_message = function(m)
        table.insert(msgs, m)
      end,
      on_response = function(status, r)
        resp = { status, r }
      end,
    })
    util.wait(function()
      return resp ~= nil
    end, 5000)
    assert.equals("success", resp[1])
    assert.equals("αβγ", resp[2].echo.symbol)
    assert.equals(2, #msgs) -- sub-id progress message + response
    assert.equals(3, t.greeting.version)
    t:stop()
  end)

  it("reports an unexpected exit with stderr", function()
    local exit_info
    local t = transport.new({
      cmd = { "python3", "-u", echo },
      on_exit = function(code, stderr)
        exit_info = { code, stderr }
      end,
    })
    assert.is_true(t:start())
    t:request("crash", {})
    util.wait(function()
      return exit_info ~= nil
    end, 5000)
    assert.equals(3, exit_info[1])
    assert.matches("simulated crash", exit_info[2])
    assert.is_false(t:is_running())
  end)

  it("fails to start a missing executable and names it", function()
    local t = transport.new({ cmd = { "/nonexistent/fstar.exe", "--ide", "A.fst" } })
    local ok, err = t:start()
    assert.is_false(ok)
    assert.is_string(err)
  end)

  it("keeps routing a persistent query after its own response", function()
    local t = transport.new({ cmd = { "x" } })
    local seen = {}
    t.handlers["7"] = {
      persistent = true,
      on_message = function(m)
        table.insert(seen, m["query-id"])
      end,
    }
    t:dispatch({ kind = "response", ["query-id"] = "7", status = "failure", response = {} })
    t:dispatch({ kind = "message", ["query-id"] = "7.1", level = "progress", contents = {} })
    assert.same({ "7", "7.1" }, seen)
  end)

  it("converts F* character columns to byte columns (non-ASCII transcript)", function()
    local tr = fake_fstar.transcript("unicode")
    local issue = tr.steps[1].recv[11].response[1]
    -- "let δ : bool = αβγ 1": F* reports αβγ at character 15; δ is 2 bytes,
    -- so the byte column is 16.
    local line = "let δ : bool = αβγ 1"
    assert.equals(15, issue.ranges[1].beg[2])
    local row, col = transport.to_buf_pos(issue.ranges[1].beg, line)
    assert.equals(4, row)
    assert.equals(line:find("αβγ", 1, true) - 1, col)
    assert.same({ 5, 15 }, { transport.to_fstar_pos(4, col, line) })
  end)
end)
