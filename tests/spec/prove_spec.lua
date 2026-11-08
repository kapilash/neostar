local util = require("helpers.util")
local fake_fstar = require("helpers.fake_fstar")
local scratch = require("neostar.fstar.scratch")
local prove = require("neostar.prove")

local agents = require("helpers.agents")

--- The fake agent the current describe block runs with.
local A
local log
local function use_plan(plan)
  log = agents.use_plan(A, plan)
end

local FAIL = { call = "check_proof", args = { helpers = "", body = "assert (x + 1 == x)" } }
local OK = { call = "check_proof", args = { helpers = "", body = "()" } }
local PROPOSE_OK = { call = "propose_proof", args = { helpers = "", body = "()" } }
local HELPER = "let aux (y:nat) : Lemma (y * 1 == y) = ()"
local OK3 = { call = "check_proof", args = { helpers = HELPER, body = "aux x" } }
local PROPOSE3 = { call = "propose_proof", args = { helpers = HELPER, body = "aux x" } }

local function setup()
  local b = util.open_fixture("Prove.fst")
  local s, session_fake = util.attach_fake(b, "prove")
  util.wait(function()
    return util.idle(s) and #s.fragments == 6
  end)
  local fake = fake_fstar.new(fake_fstar.transcript("scratch"))
  scratch._factory_override = fake:factory()
  return b, s, fake, session_fake
end

local function start(b, row)
  local res
  local st = prove.prove(b, {
    row = row or 8,
    on_done = function(r)
      res = r
    end,
  })
  return st, function(timeout)
    util.wait(function()
      return res ~= nil
    end, timeout or 15000)
    return res
  end
end

local function wait_view(st)
  util.wait(function()
    return st.view ~= nil
  end, 15000)
  return st.view
end

local function start_recheck()
  local b, _, fake = setup()
  use_plan({ FAIL, OK, PROPOSE_OK })
  local st, wait = start(b)
  local view = wait_view(st)
  fake.auto = false
  vim.api.nvim_buf_set_lines(b, 4, 5, false, { "let ok_prefix (x:nat) : Lemma (x + 0 == x + 0) = ()" })
  view.decide(true)
  assert.is_not_nil(st.scratch.run)
  return b, st, wait, fake
end

for _, agent in ipairs(agents.list) do
describe("fstar/proof-assist [" .. agent.name .. "]", function()
  before_each(function()
    A = agent
    require("neostar").setup({ agent = agents.options(A) })
  end)
  after_each(function()
    agents.clear()
    scratch._factory_override = nil
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

  it("uses indexed lemmas without touching the buffer checker and releases docs before review", function()
    local docs = require("neostar.agent.docs")
    local helper = require("helpers.docs")
    local spawn, cs = helper.fake()
    docs._spawn = spawn
    require("neostar").setup({ agent = agents.options(A, { docs = helper.config() }) })
    local b, s, _, checker = setup()
    checker.auto = false
    s:check("full")
    local checks = #checker:sent_of("full-buffer")
    use_plan({ { call = "fstardoc_find_by_type", args = { shape = "nat -> nat" } }, FAIL, OK, PROPOSE_OK })
    local st, wait = start(b)
    local view = wait_view(st)
    assert.equals("find_by_type", cs[1].messages[4].params.name)
    assert.equals(checks, #checker:sent_of("full-buffer"))
    assert.equals(0, #checker:sent_of("lookup"))
    assert.equals(0, #checker:sent_of("cancel"))
    assert.equals("full", s.running)
    assert.is_true(cs[1].exited)
    assert.equals(2, st.checks)
    view.decide(false)
    assert.equals("rejected", wait().outcome)
  end)

  it("finds a proof, shows the diff, and applies it on accept", function()
    local b, _, fake, session_fake = setup()
    use_plan({ FAIL, OK, PROPOSE_OK, { text = "Done." } })
    local st, wait = start(b)
    local view = wait_view(st)
    assert.matches("+  ()", view.text, 1, true)
    assert.equals(2, st.checks)
    assert.equals(2, #fake:sent_of("full-buffer"))
    -- prompt: fixed statement and current body
    local run = vim.json.decode(vim.fn.readfile(log)[1])
    assert.matches("val target : x:nat -> Lemma (x * 1 + 0 == x)", run.stdin, 1, true)
    assert.matches("let target x =\n  <body>", run.stdin, 1, true)
    assert.matches("admit ()", run.stdin, 1, true)
    vim.api.nvim_set_current_win(view.win)
    vim.api.nvim_feedkeys("a", "x", false)
    local res = wait()
    assert.equals("applied", res.outcome)
    assert.same({ "let target x =", "  ()" }, vim.api.nvim_buf_get_lines(b, 7, 9, false))
    -- a lax check of the edited buffer follows
    util.wait(function()
      return #session_fake:sent_of("full-buffer") == 2
    end, 2000)
    local lax = session_fake:sent_of("full-buffer")[2]
    assert.equals("lax", lax.args.kind)
    assert.matches("let target x =\n  ()", lax.args.code, 1, true)
    -- the scratch checker is gone
    assert.is_true(fake.exited)
  end)

  it("leaves the buffer unchanged when the diff is rejected", function()
    local b = setup()
    local orig = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    use_plan({ FAIL, OK, PROPOSE_OK })
    local st, wait = start(b)
    local view = wait_view(st)
    vim.api.nvim_set_current_win(view.win)
    vim.api.nvim_feedkeys("r", "x", false)
    assert.equals("rejected", wait().outcome)
    assert.same(orig, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end)

  it("reports no proof with the last F* error when the agent gives up", function()
    local b = setup()
    local orig = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    use_plan({ FAIL, { text = "I could not prove it." } })
    local st, wait = start(b)
    local res = wait()
    assert.equals("no_proof", res.outcome)
    assert.matches("could not prove", res.last_error)
    assert.is_nil(st.view)
    assert.matches("No proof found", st.window:text(), 1, true)
    assert.same(orig, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end)

  it("does not accept a proposal that was never checked", function()
    local b = setup()
    use_plan({ PROPOSE_OK, { text = "proposed" } })
    local st, wait = start(b)
    assert.equals("no_proof", wait().outcome)
    assert.is_nil(st.proposal)
  end)

  it("stops after the configured number of checks", function()
    require("neostar").setup({ agent = agents.options(A, { max_checks = 1 }) })
    local b = setup()
    use_plan({ FAIL, OK, PROPOSE_OK })
    local st, wait = start(b)
    local res = wait()
    assert.equals("no_proof", res.outcome)
    assert.equals(1, st.checks)
    assert.matches("limit reached", vim.api.nvim_win_get_config(st.window.win).footer[1][1], 1, true)
  end)

  it("re-checks a proposal when the text above the target changed, and refuses it if it fails", function()
    local b, _, fake = setup()
    use_plan({ FAIL, OK, OK3, PROPOSE3 })
    local st, wait = start(b)
    local view = wait_view(st)
    -- the user edits a lemma above the target while the diff is open
    vim.api.nvim_buf_set_lines(b, 4, 5, false, { "let ok_prefix (x:nat) : Lemma (x + 0 == x + 0) = ()" })
    local edited = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    vim.api.nvim_set_current_win(view.win)
    local orig_notify = vim.notify
    vim.notify = function() end
    vim.api.nvim_feedkeys("a", "x", false)
    local res = wait()
    vim.notify = orig_notify
    assert.equals("refused", res.outcome)
    assert.matches("no longer verifies", res.message, 1, true)
    assert.equals(4, #fake:sent_of("full-buffer"))
    assert.matches("x + 0 == x + 0", fake:sent_of("full-buffer")[4].args.code, 1, true)
    assert.same(edited, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end)

  it("resolves the target's current position before displaying a diff", function()
    local b = setup()
    use_plan({ FAIL, OK, PROPOSE_OK, { sleep = 0.2 } })
    local st, wait = start(b)
    util.wait(function() return st.proposal ~= nil end, 10000)
    vim.api.nvim_buf_set_lines(b, 0, 0, false, { "// inserted while the agent was working" })
    local view = wait_view(st)
    assert.matches("-  admit ()", view.text, 1, true)
    assert.matches("+  ()", view.text, 1, true)
    view.decide(false)
    assert.equals("rejected", wait().outcome)
  end)

  it("refuses a removed target before constructing its diff", function()
    local b, _, fake = setup()
    use_plan({ FAIL, OK, PROPOSE_OK, { sleep = 0.2 } })
    local st, wait = start(b)
    util.wait(function() return st.proposal ~= nil end, 10000)
    vim.api.nvim_buf_set_lines(b, 1, -1, false, {})
    assert.equals("refused", wait().outcome)
    assert.is_nil(st.view)
    assert.is_true(fake.exited)
    assert.is_nil(require("neostar.agent").current(b))
  end)

  it("does not overwrite a body edited while its diff was open", function()
    local b = setup()
    use_plan({ FAIL, OK, PROPOSE_OK })
    local st, wait = start(b)
    local view = wait_view(st)
    vim.api.nvim_buf_set_lines(b, 8, 9, false, { "  assert (true); admit ()" })
    local edited = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    view.decide(true)
    assert.equals("refused", wait().outcome)
    assert.same(edited, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end)

  it("refuses edits made during an asynchronous accept-time re-check", function()
    local b, _, wait, fake = start_recheck()
    vim.api.nvim_buf_set_lines(b, 0, 0, false, { "// edit during re-check" })
    local edited = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    fake:pump()
    local res = wait()
    assert.equals("refused", res.outcome)
    assert.matches("buffer changed during re-check", res.message, 1, true)
    assert.same(edited, vim.api.nvim_buf_get_lines(b, 0, -1, false))
    assert.is_true(fake.exited)
  end)

  it("can stop a proof from its review window", function()
    local b, _, fake = setup()
    use_plan({ FAIL, OK, PROPOSE_OK })
    local st, wait = start(b)
    local view = wait_view(st)
    vim.api.nvim_set_current_win(view.win)
    vim.cmd("NeostarAgentStop")
    assert.equals("stopped", wait().outcome)
    assert.is_false(vim.api.nvim_win_is_valid(view.win))
    assert.is_true(fake.exited)
    assert.is_nil(require("neostar.agent").current(b))
  end)

  it("cancels the scratch checker during accept-time re-check", function()
    local b, st, wait, fake = start_recheck()
    local edited = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    assert.is_true(require("neostar.agent").stop(b, "cancel re-check"))
    assert.equals("stopped", wait().outcome)
    assert.is_true(fake.exited)
    assert.is_nil(st.scratch.run)
    assert.same(edited, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end)

  it("keeps the request's time limit during accept-time re-check", function()
    require("neostar").setup({ agent = agents.options(A, { timeout_ms = 2000 }) })
    local b, _, wait, fake = start_recheck()
    local edited = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    local res = wait(5000)
    assert.equals("stopped", res.outcome)
    assert.matches("time limit", res.message, 1, true)
    assert.is_true(fake.exited)
    assert.same(edited, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end)

  it("stops a pending proof when its source buffer is deleted", function()
    local b, _, fake = setup()
    use_plan({ FAIL, OK, PROPOSE_OK })
    local st, wait = start(b)
    local view = wait_view(st)
    vim.api.nvim_set_current_win(vim.fn.bufwinid(b))
    vim.api.nvim_buf_delete(b, { force = true })
    assert.is_false(vim.api.nvim_buf_is_loaded(b))
    assert.equals("stopped", wait().outcome)
    assert.is_true(fake.exited)
    assert.is_false(vim.api.nvim_win_is_valid(view.win))
    assert.is_nil(require("neostar.agent").current(b))
  end)

  it("refuses when the cursor is not on a let", function()
    local b = setup()
    local msgs = {}
    local orig = vim.notify
    vim.notify = function(m)
      table.insert(msgs, m)
    end
    local st = prove.prove(b, { row = 1 })
    vim.notify = orig
    assert.is_nil(st)
    assert.matches("needs the cursor on a `let`", msgs[1], 1, true)
  end)

  it(":NeostarAgentStop stops the agent and the scratch checker and leaves the buffer alone", function()
    local b, _, fake = setup()
    local orig = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    use_plan({ FAIL, { text = "thinking" }, { sleep = 10 }, OK })
    local st, wait = start(b)
    util.wait(function()
      return st.checks == 1 and st.window:text():find("thinking", 1, true) ~= nil
    end, 10000)
    vim.cmd("NeostarAgentStop")
    local res = wait()
    assert.equals("stopped", res.outcome)
    assert.is_true(fake.exited)
    assert.is_nil(require("neostar.agent").current(b))
    assert.matches("stopped by :NeostarAgentStop", st.window:text(), 1, true)
    assert.same(orig, vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end)

  it("stops a request at the time limit", function()
    require("neostar").setup({ agent = agents.options(A, { timeout_ms = 400 }) })
    local b = setup()
    use_plan({ { text = "slow" }, { sleep = 10 } })
    local st, wait = start(b)
    local res = wait()
    assert.equals("stopped", res.outcome)
    assert.matches("time limit", res.message, 1, true)
    assert.is_nil(st.proposal)
  end)

  it("runs one request per buffer: a new request stops the previous one", function()
    local b = setup()
    use_plan({ { text = "explaining" }, { sleep = 10 } })
    local ex
    ex = require("neostar.explain").explain(b, 3, 3, {
      on_done = function(r)
        ex.result = r
      end,
    })
    util.wait(function()
      return ex.window:text():find("explaining", 1, true) ~= nil
    end, 10000)
    use_plan({ FAIL, { text = "x" } })
    local _, wait = start(b)
    util.wait(function()
      return ex.result ~= nil
    end, 5000)
    assert.is_true(ex.result.stopped)
    assert.matches("replaced by a new request", ex.window:text(), 1, true)
    assert.equals("no_proof", wait().outcome)
  end)
end)
end
