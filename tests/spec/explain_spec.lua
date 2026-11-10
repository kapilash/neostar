local util = require("helpers.util")
local explain = require("neostar.explain")

local agents = require("helpers.agents")

--- The fake agent the current describe block runs with.
local A
local log
local function use_plan(plan)
  log = agents.use_plan(A, plan)
end

local function runs()
  return agents.runs(log)
end

local function wait_done(state, n)
  state.done_count = state.done_count or 0
  local prev = state.on_done
  util.wait(function()
    return state.last_result ~= nil and (state.done_count or 0) >= (n or 1)
  end, 10000)
  return prev
end

local function start(b, l1, l2)
  local st
  st = explain.explain(b, l1, l2, {
    on_done = function(res)
      st.last_result = res
      st.done_count = (st.done_count or 0) + 1
    end,
  })
  return st
end

for _, agent in ipairs(agents.list) do
describe("fstar/explain [" .. agent.name .. "]", function()
  before_each(function()
    A = agent
    require("neostar").setup({ agent = agents.options(A) })
  end)
  after_each(function()
    agents.clear()
    require("neostar.agent").stop_all()
    require("neostar.agent.mcp").stop()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    util.cleanup()
    require("neostar.agent.docs").shutdown()
    require("neostar.agent.docs")._spawn = nil
  end)

  it("retrieves documentation and keeps its configuration for follow-ups", function()
    local docs = require("neostar.agent.docs")
    local helper = require("helpers.docs")
    local spawn, cs = helper.fake()
    docs._spawn = spawn
    require("neostar").setup({ agent = agents.options(A, { docs = helper.config() }) })
    local b, s = util.open_fixture("Clean.fst")
    s = util.attach_fake(b, "clean")
    util.wait(function() return util.idle(s) end)
    use_plan({ runs = {
      { { call = "fstardoc_find_by_contract", args = { name = "slice" } }, { text = "found lemma" } },
      { { call = "fstardoc_lookup", args = { name = "slice" } }, { text = "looked up lemma" } },
    } })
    local st = start(b, 8, 8)
    wait_done(st)
    assert.is_true(st.last_result.ok)
    assert.equals("find_by_contract", cs[1].messages[4].params.name)
    assert.matches("Static library documentation", runs()[1].stdin)
    require("neostar").setup({ agent = agents.options(A) })
    st.window.opts.on_followup("which lemma?")
    wait_done(st, 2)
    assert.is_true(st.last_result.ok)
    assert.equals(2, #cs)
    assert.equals("lookup", cs[2].messages[4].params.name)
    assert.matches("looked up lemma", st.window:text())
  end)

  it("warns and continues when documentation preparation fails", function()
    require("neostar").setup({ agent = agents.options(A, {
      docs = { enabled = true, server = "/missing-fstardoc.py" },
    }) })
    local b = util.open_fixture("Clean.fst")
    local s = util.attach_fake(b, "clean")
    util.wait(function() return util.idle(s) end)
    use_plan({ { call = "fstar_lookup", args = { symbol = "len" } }, { text = "checker still works" } })
    local st = start(b, 8, 8)
    wait_done(st)
    assert.is_true(st.last_result.ok)
    assert.matches("Documentation warning", st.window:text())
    assert.matches("unavailable this turn", runs()[1].stdin)
  end)

  it("does not launch inference after stopping during documentation preparation", function()
    local docs = require("neostar.agent.docs")
    local helper = require("helpers.docs")
    local spawn, cs = helper.fake({ silent = true })
    docs._spawn = spawn
    require("neostar").setup({ agent = agents.options(A, { docs = helper.config() }) })
    local b = util.open_fixture("Clean.fst")
    local s = util.attach_fake(b, "clean")
    util.wait(function() return util.idle(s) end)
    use_plan({ { text = "must not run" } })
    local st = start(b, 8, 8)
    require("neostar.agent").stop(b, "stopped during preparation")
    wait_done(st)
    assert.is_true(st.last_result.stopped)
    assert.same({}, runs())
    assert.equals(15, cs[1].killed)
  end)

  it("explains the declaration at the cursor and streams into a window", function()
    local b = util.open_fixture("Clean.fst")
    local s = util.attach_fake(b, "clean")
    util.wait(function()
      return util.idle(s) and #s.fragments == 4
    end)
    use_plan({ { text = "`len` returns the length of a list." } })
    vim.api.nvim_win_set_cursor(0, { 8, 4 })
    local st = start(b)
    wait_done(st)
    assert.is_true(st.last_result.ok)
    assert.matches("returns the length of a list", st.window:text(), 1, true)
    local run = runs()[1]
    assert.matches("lines 8-8", run.stdin, 1, true)
    assert.matches("let len (#a:Type)", run.stdin, 1, true)
    assert.matches("lax-checked only", run.stdin, 1, true)
    assert.matches("Explain what this code states", run.stdin, 1, true)
    assert.equals(vim.fs.normalize(s.root or vim.fn.fnamemodify(s.file, ":h")), vim.fs.normalize(run.cwd))
    assert.is_false(vim.api.nvim_buf_get_lines(b, 0, -1, false)[1] ~= "module Clean")
    assert.is_false(vim.bo[b].modified)
  end)

  it("explains a failing range as a failure, with F*'s error in the prompt", function()
    local b = util.open_fixture("TypeErr.fst")
    local s = util.attach_fake(b, "typeerr")
    util.wait(function()
      return util.idle(s) and #s:diagnostics() > 0
    end)
    local d = s:diagnostics()[1]
    use_plan({ { text = "It fails because..." } })
    local st = start(b, 1, vim.api.nvim_buf_line_count(b))
    wait_done(st)
    local stdin = runs()[1].stdin
    assert.matches("Explain why F* rejects this code", stdin, 1, true)
    assert.matches(vim.split(d.message, "\n")[1], stdin, 1, true)
    assert.matches(("line %d"):format(d.lnum + 1), stdin, 1, true)
  end)

  it("lets the agent call the F* tools during the explanation", function()
    local b = util.open_fixture("Clean.fst")
    local s = util.attach_fake(b, "clean")
    util.wait(function()
      return util.idle(s) and #s.fragments == 4
    end)
    use_plan({ { call = "fstar_lookup", args = { symbol = "len" } }, { text = "done" } })
    local st = start(b, 8, 8)
    local statuses = {}
    local set_status = st.window.set_status
    st.window.set_status = function(w, text)
      table.insert(statuses, text)
      return set_status(w, text)
    end
    wait_done(st)
    assert.is_true(st.last_result.ok)
    assert.is_true(vim.tbl_contains(statuses, "using fstar_lookup…"), vim.inspect(statuses))
    -- the run's token is revoked afterwards
    assert.is_nil(require("neostar.agent").current(b))
  end)

  it("refuses when the cursor is not on a declaration and no range is given", function()
    local b = util.open_fixture("Clean.fst")
    util.attach_fake(b, "clean")
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(m)
      table.insert(msgs, m)
    end
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local st = explain.explain(b)
    vim.notify = orig
    assert.is_nil(st)
    assert.matches("move the cursor to a declaration", msgs[1], 1, true)
  end)

  it("continues the conversation with a follow-up appended below", function()
    local b = util.open_fixture("Clean.fst")
    local s = util.attach_fake(b, "clean")
    util.wait(function()
      return util.idle(s) and #s.fragments == 4
    end)
    use_plan({ runs = { { { text = "First answer." } }, { { text = "Follow-up answer." } } } })
    local st = start(b, 3, 3)
    wait_done(st, 1)
    local sid = st.session_id
    assert.is_not_nil(sid)
    local orig = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("why is it pure?")
    end
    vim.api.nvim_set_current_win(st.window.win)
    vim.api.nvim_feedkeys("f", "x", false)
    vim.ui.input = orig
    wait_done(st, 2)
    local text = st.window:text()
    local a1 = text:find("First answer.", 1, true)
    local q = text:find("**You:** why is it pure?", 1, true)
    local a2 = text:find("Follow-up answer.", 1, true)
    assert.is_true(a1 < q and q < a2)
    local r2 = runs()[2]
    assert.matches("Follow-up question: why is it pure?", r2.stdin, 1, true)
    assert.matches("Editor revision:", r2.stdin, 1, true)
    assert.equals(sid, A.resume_id(r2.argv))
    assert.is_nil(A.resume_id(runs()[1].argv), "the first question starts a new conversation")
  end)

  it("refreshes the selected unsaved text and revision on follow-up", function()
    local b = util.open_fixture("Clean.fst")
    local s = util.attach_fake(b, "clean")
    util.wait(function() return util.idle(s) end)
    use_plan({ runs = { { { text = "first" } }, { { text = "second" } } } })
    local st = start(b, 8, 8)
    wait_done(st)
    s.debounce_ms = 10000
    vim.api.nvim_buf_set_lines(b, 7, 8, false, { "let unsaved_editor_value = 42" })
    st.window.opts.on_followup("what changed?")
    wait_done(st, 2)
    local prompt = runs()[2].stdin
    assert.matches("let unsaved_editor_value = 42", prompt, 1, true)
    assert.matches("Editor revision: " .. vim.api.nvim_buf_get_changedtick(b), prompt, 1, true)
    assert.matches("not current", prompt, 1, true)
    assert.matches("Follow-up question: what changed?", prompt, 1, true)
  end)

  it("keeps the conversation's executable and model if setup changes between turns", function()
    require("neostar").setup({ agent = agents.options(A, { [A.name] = { model = "original-model" } }) })
    local b = util.open_fixture("Clean.fst")
    local s = util.attach_fake(b, "clean")
    util.wait(function() return util.idle(s) end)
    use_plan({ runs = { { { text = "first" } }, { { text = "second" } } } })
    local st = start(b, 8, 8)
    wait_done(st)
    require("neostar").setup({
      agent = { runner = "copilot", [A.name] = { cmd = "/nonexistent/changed-agent", model = "changed-model" } },
    })
    st.window.opts.on_followup("continue")
    wait_done(st, 2)
    assert.is_true(st.last_result.ok)
    local argv = runs()[2].argv
    assert.equals(A.fake, st.runner_config[A.name].cmd)
    assert.equals("original-model", argv[vim.fn.index(argv, "--model") + 2])
    assert.matches("original-model", st.window:text(), 1, true)
  end)

  it("stops the run when the window is closed", function()
    local b = util.open_fixture("Clean.fst")
    local s = util.attach_fake(b, "clean")
    util.wait(function()
      return util.idle(s) and #s.fragments == 4
    end)
    use_plan({ { text = "start" }, { sleep = 5 }, { text = "never" } })
    local st = start(b, 3, 3)
    util.wait(function()
      return st.window:text():find("start", 1, true) ~= nil
    end, 5000)
    st.window:close()
    util.wait(function()
      return st.last_result ~= nil
    end, 5000)
    assert.is_true(st.last_result.stopped)
    assert.is_nil(require("neostar.agent").current(b))
  end)

  it("closing an old window does not stop a newer explanation", function()
    local b = util.open_fixture("Clean.fst")
    local s = util.attach_fake(b, "clean")
    util.wait(function() return util.idle(s) end)
    use_plan({ { text = "old" }, { sleep = 5 } })
    local old = start(b, 3, 3)
    use_plan({ { text = "new" }, { sleep = 5 } })
    local new = start(b, 3, 3)
    local run = require("neostar.agent").current(b)
    old.window:close()
    assert.equals(run, require("neostar.agent").current(b))
    assert.is_true(new.window:is_open())
    assert.is_true(old.last_result.stopped)
  end)

  it("a follow-up does not replace a proof request", function()
    local b = util.open_fixture("Clean.fst")
    local s = util.attach_fake(b, "clean")
    util.wait(function() return util.idle(s) end)
    use_plan({ { text = "explanation" } })
    local st = start(b, 8, 8)
    wait_done(st)
    use_plan({ { text = "proving" }, { sleep = 5 } })
    require("neostar.prove").prove(b, { row = 7 })
    local run = require("neostar.agent").current(b)
    st.window.opts.on_followup("why?")
    assert.equals("prove", run.kind)
    assert.equals(run, require("neostar.agent").current(b))
  end)

  it("stops a running explanation when its source buffer is deleted", function()
    local b = util.open_fixture("Clean.fst")
    local s = util.attach_fake(b, "clean")
    util.wait(function() return util.idle(s) end)
    use_plan({ { text = "answering" }, { sleep = 5 } })
    local st = start(b, 3, 3)
    vim.api.nvim_set_current_win(vim.fn.bufwinid(b))
    vim.api.nvim_buf_delete(b, { force = true })
    assert.is_false(vim.api.nvim_buf_is_loaded(b))
    assert.is_true(st.last_result.stopped)
    assert.is_nil(require("neostar.agent").current(b))
  end)

  it("shows an error when the agent is missing", function()
    require("neostar").setup({ agent = agents.options(A, { [A.name] = { cmd = "/nonexistent/" .. A.name } }) })
    local b = util.open_fixture("Clean.fst")
    util.attach_fake(b, "clean")
    local orig = vim.notify
    vim.notify = function() end
    local st = start(b, 3, 3)
    vim.notify = orig
    util.wait(function()
      return st.last_result ~= nil
    end)
    assert.is_false(st.last_result.ok)
    assert.matches("was not found", st.window:text(), 1, true)
  end)
end)
end

describe("fstar/explain with automatic agent selection", function()
  after_each(function()
    agents.clear()
    require("neostar.agent").stop_all()
    require("neostar.agent.mcp").stop()
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative ~= "" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
    util.cleanup()
    require("neostar").setup({})
  end)

  it("uses Copilot when Claude is missing, and keeps the follow-up with Copilot", function()
    local copilot = agents.get("copilot")
    require("neostar").setup({ agent = { runner = "auto", claude = { cmd = "/nonexistent/claude" }, copilot = { cmd = copilot.fake, transport = "cli" } } })
    local b = util.open_fixture("Clean.fst")
    local s = util.attach_fake(b, "clean")
    util.wait(function()
      return util.idle(s) and #s.fragments == 4
    end)
    A = copilot
    use_plan({ runs = { { { text = "Copilot answer." } }, { { text = "Copilot follow-up." } } } })
    local claude_log = agents.use_plan(agents.get("claude"), { { text = "never" } })
    local st = start(b, 3, 3)
    wait_done(st, 1)
    assert.equals("copilot", st.runner)
    assert.is_not_nil(st.session_id)
    -- Claude becomes available before the follow-up: the conversation still stays with Copilot.
    require("neostar").options.agent.claude.cmd = agents.get("claude").fake
    local orig = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("and the type?")
    end
    vim.api.nvim_set_current_win(st.window.win)
    vim.api.nvim_feedkeys("f", "x", false)
    vim.ui.input = orig
    wait_done(st, 2)
    assert.is_true(st.last_result.ok, st.last_result.error)
    local r = runs()
    assert.equals(2, #r)
    assert.equals("--resume=" .. st.session_id, r[2].argv[#r[2].argv])
    assert.matches("Follow-up question: and the type?", r[2].stdin, 1, true)
    assert.matches("Copilot follow-up.", st.window:text(), 1, true)
    assert.same({}, agents.runs(claude_log), "Claude was never started")
  end)
end)
