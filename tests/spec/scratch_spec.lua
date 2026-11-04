local util = require("helpers.util")
local fake_fstar = require("helpers.fake_fstar")
local scratch = require("neostar.fstar.scratch")
local decl = require("neostar.fstar.decl")

local function setup_prove()
  local b = util.open_fixture("Prove.fst")
  local s = util.attach_fake(b, "prove")
  util.wait(function()
    return util.idle(s) and #s.fragments == 6
  end)
  local target = assert(decl.target_at(b, 8))
  local fake = fake_fstar.new(fake_fstar.transcript("scratch"))
  local sc = scratch.new({
    session = s,
    target = target,
    lines = vim.api.nvim_buf_get_lines(b, 0, -1, false),
    transport_factory = fake:factory(),
    ping_interval_ms = 20,
  })
  return b, s, sc, fake
end

local function check(sc, helpers, body)
  local result
  sc:check(helpers, body, function(r)
    result = r
  end)
  util.wait(function()
    return result ~= nil
  end, 3000)
  return result
end

describe("scratch checker", function()
  after_each(util.cleanup)

  it("assembles the admitted prefix, helpers above the val, and the target", function()
    local b, _, sc = setup_prove()
    local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
    local text = scratch.assemble(lines, sc.target, "let aux (y:nat) : Lemma (y * 1 == y) = ()", "aux x")
    assert.equals(fake_fstar.read(fake_fstar.file("Prove_c3.fst")), text)
    assert.is_nil(text:find("after", 1, true))
  end)

  it("reports a failing body with positions relative to the body", function()
    local _, _, sc, fake = setup_prove()
    local r = check(sc, "", "assert (x + 1 == x)")
    assert.is_false(r.ok)
    assert.equals(1, #r.errors)
    local e = r.errors[1]
    assert.same({ "body", 1, 1 }, { e.where, e.line, e.col })
    assert.matches("could not prove", e.message)
    assert.matches("body line 1, column 1", r.text, 1, true)
    local sent = fake:sent_of("full-buffer")[1]
    assert.equals("full", sent.args.kind)
    assert.matches(scratch.PUSH, sent.args.code, 1, true)
    sc:close()
  end)

  it("accepts a passing candidate and checks follow-ups in the same process", function()
    local _, _, sc, fake = setup_prove()
    assert.is_false(check(sc, "", "assert (x + 1 == x)").ok)
    local r = check(sc, "", "()")
    assert.is_true(r.ok)
    assert.same({}, r.errors)
    assert.matches("^OK", r.text)
    r = check(sc, "let aux (y:nat) : Lemma (y * 1 == y) = ()", "aux x")
    assert.is_true(r.ok)
    assert.equals(1, fake.spawned)
    sc:close()
  end)

  it("locates errors in helpers", function()
    local _, _, sc = setup_prove()
    check(sc, "", "assert (x + 1 == x)")
    check(sc, "", "()")
    check(sc, "let aux (y:nat) : Lemma (y * 1 == y) = ()", "aux x")
    local r = check(sc, "let aux_bad (y:nat) : Lemma (y + 1 == y) = ()", "aux_bad x")
    assert.is_false(r.ok)
    assert.same({ "helpers", 1, 44 }, { r.errors[1].where, r.errors[1].line, r.errors[1].col })
    sc:close()
  end)

  it("leaves the buffer's own session alone", function()
    local b, s, sc = setup_prove()
    local before = util.statuses(s)
    local diags = #s:diagnostics()
    check(sc, "", "assert (x + 1 == x)")
    check(sc, "", "()")
    assert.same(before, util.statuses(s))
    assert.equals(diags, #s:diagnostics())
    assert.equals(0, #vim.diagnostic.get(b))
    sc:close()
  end)

  it("stops its process on close and refuses later checks", function()
    local _, _, sc, fake = setup_prove()
    check(sc, "", "()")
    assert.is_true(sc:is_running())
    sc:close()
    assert.is_true(fake.exited)
    local r = check(sc, "", "()")
    assert.is_false(r.ok)
    assert.matches("ended", r.text)
  end)

  it("maps positions on a statement line before the body as statement errors", function()
    local layout = { helpers_line = 9, helpers_lines = 2, region_line = 11, body_line = 13, body_col = 2, prefix_last = 8 }
    assert.same({ "statement" }, { scratch.locate(layout, { 13, 1 }) })
    assert.same({ "body", 1, 1 }, { scratch.locate(layout, { 13, 2 }) })
    assert.same({ "body", 2, 5 }, { scratch.locate(layout, { 14, 4 }) })
    assert.same({ "statement" }, { scratch.locate(layout, { 11, 0 }) })
    assert.same({ "helpers", 2, 1 }, { scratch.locate(layout, { 10, 0 }) })
    assert.same({ "prefix" }, { scratch.locate(layout, { 4, 0 }) })
  end)
end)

describe("proof tools", function()
  local http = require("helpers.http")
  local mcp = require("neostar.agent.mcp")
  local tools = require("neostar.agent.tools")

  after_each(function()
    mcp.stop()
    util.cleanup()
  end)

  local function setup(max_checks)
    local _, _, sc, fake = setup_prove()
    local state = { target = sc.target, scratch = sc, max_checks = max_checks or 10, checks = 0 }
    local token = mcp.register({ tools = tools.proof_tools(state) })
    return state, token, mcp.port(), fake
  end

  it("rejects admit without contacting F*", function()
    local state, token, port, fake = setup()
    local r = http.call_tool(port, token, "check_proof", { helpers = "", body = "admit ()" })
    assert.is_true(r.isError)
    assert.matches("REJECTED", http.text(r), 1, true)
    assert.equals(0, #fake:sent_of("full-buffer"))
    assert.equals(0, state.checks)
  end)

  it("checks candidates and accepts only the last passing one as the proposal", function()
    local state, token, port = setup()
    local r = http.call_tool(port, token, "check_proof", { helpers = "", body = "assert (x + 1 == x)" })
    assert.is_true(r.isError)
    assert.matches("could not prove", http.text(r))
    r = http.call_tool(port, token, "propose_proof", { helpers = "", body = "assert (x + 1 == x)" })
    assert.is_true(r.isError)
    assert.is_nil(state.proposal)
    r = http.call_tool(port, token, "check_proof", { body = "()" })
    assert.is_false(r.isError)
    r = http.call_tool(port, token, "propose_proof", { helpers = "", body = "() " })
    assert.is_true(r.isError, "a different body is not accepted")
    r = http.call_tool(port, token, "propose_proof", { helpers = "", body = "()" })
    assert.is_false(r.isError)
    assert.same({ helpers = "", body = "()" }, state.proposal)
    assert.equals(2, state.checks)
    state.scratch:close()
  end)

  it("refuses checks beyond the limit", function()
    local state, token, port = setup(1)
    http.call_tool(port, token, "check_proof", { body = "assert (x + 1 == x)" })
    local r = http.call_tool(port, token, "check_proof", { body = "()" })
    assert.is_true(r.isError)
    assert.matches("limit reached", http.text(r), 1, true)
    assert.equals(1, state.checks)
    state.scratch:close()
  end)
end)
