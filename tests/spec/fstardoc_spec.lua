local util = require("helpers.util")
local fstardoc = require("neostar.fstardoc")
local docs = require("neostar.agent.docs")

local fixture = vim.fn.getcwd() .. "/tests/fixtures/docs/mini.index.json"

local function index()
  return assert(fstardoc.load(fixture))
end

local function call(name, args)
  local text, is_error = fstardoc.call(index(), name, args or {})
  local ok, value = pcall(vim.json.decode, text, { luanil = { object = true } })
  return ok and value or text, is_error
end

local function names(ds)
  return vim.tbl_map(function(d)
    return d.name
  end, ds)
end

describe("fstardoc index", function()
  after_each(function()
    fstardoc.clear()
    docs.shutdown()
    docs._spawn = nil
    docs.last_error = nil
  end)

  it("refuses an index with another schema or version", function()
    local _, err = fstardoc.new({ schema = "fstardoc-retrieval-index", version = 2, declarations = {} })
    assert.matches("unexpected index", err)
    local _, err2 = fstardoc.new({ schema = "other", version = 1 })
    assert.matches("neostar reads fstardoc%-retrieval%-index version 1", err2)
  end)

  it("resolves short names only when unambiguous", function()
    local r = call("lookup", { name = "slice" })
    assert.equals("Demo.Seq.slice", r.name)
    assert.is_false(r.documented)
    assert.matches("no documentation", r.note)
    assert.same({ "Demo.Seq.length" }, r.requires_about)
    assert.equals("Demo.Seq.fsti:5", r.at)
    local amb, is_error = call("lookup", { name = "length" })
    assert.is_true(is_error)
    assert.equals("'length' is ambiguous; it could be Demo.List.length, Demo.Seq.length.", amb.error)
    local missing, missing_error = call("lookup", { name = "nope" })
    assert.is_true(missing_error)
    assert.equals("No declaration is named 'nope'.", missing.error)
  end)

  it("joins documentation lines and truncates long definitions unless asked", function()
    assert.equals("Slicing gives\nthe expected length.", call("lookup", { name = "lemma_len_slice" }).doc)
    local old = fstardoc.DEFINITION_PREVIEW
    fstardoc.DEFINITION_PREVIEW = 5
    local short = call("lookup", { name = "Demo.List.length" })
    local whole = call("lookup", { name = "Demo.List.length", include_definition = true })
    fstardoc.DEFINITION_PREVIEW = old
    assert.equals("match", short.definition_preview)
    assert.is_true(short.definition_truncated)
    assert.is_nil(short.definition)
    assert.equals("match l with [] -> 0 | _ :: tl -> 1 + length tl", whole.definition)
  end)

  it("finds by contract, grouped by resolved name and side", function()
    local r = call("find_by_contract", { name = "length", side = "either" })
    local groups = vim.tbl_map(function(g)
      return g.side .. " " .. g.about .. " " .. table.concat(names(g.declarations), ",")
    end, r.groups)
    assert.same({
      "ensures Demo.Seq.length Demo.Seq.lemma_len_slice",
      "requires Demo.Seq.length Demo.Seq.slice,Demo.Seq.lemma_len_slice",
    }, groups)
    local limited = call("find_by_contract", { name = "length", side = "requires", limit = 1 })
    assert.equals(2, limited.groups[1].total)
    assert.equals(1, limited.groups[1].shown)
    assert.matches("No declaration's contract mentions 'nothing'", call("find_by_contract", { name = "nothing" }).note)
    local _, bad = call("find_by_contract", { name = "x", side = "both" })
    assert.is_true(bad)
  end)

  it("finds by type shape, in any argument order, and labels approximate matches", function()
    local r = call("find_by_type", { shape = "nat -> seq a -> nat -> seq a" })
    assert.same({ "Demo.Seq.slice" }, names(r.declarations))
    assert.equals("exact", r.declarations[1].match)
    -- a lone letter stands for a single-token type, so it does not match `seq a`
    assert.equals(0, call("find_by_type", { shape = "a -> nat" }).exact)
    local lengths = call("find_by_type", { shape = "Demo.Seq.seq x -> nat" })
    assert.same({ "Demo.Seq.length" }, names(lengths.declarations))
    local loose = call("find_by_type", { shape = "nat -> nat" })
    assert.equals(0, loose.exact)
    assert.same({ "Demo.List.incr" }, names(loose.declarations))
    assert.equals("approximate", loose.declarations[1].match)
    assert.matches("Nothing has exactly that shape", loose.warning)
    local _, is_error = call("find_by_type", { shape = "seq a" })
    assert.is_true(is_error)
  end)

  it("lists users, modules and module contents", function()
    local users = call("used_by", { name = "Demo.Seq.length" })
    assert.same({ "Demo.Seq.lemma_len_slice", "Demo.Seq.slice" }, names(users.declarations))
    local m = call("list_module", { module = "Demo.List" })
    assert.equals(2, m.total)
    assert.equals(1, m.documented) -- an empty doc list is documented, a null one is not
    assert.matches("It holds: Demo.List, Demo.Seq", call("list_module", { module = "X" }).error)
    assert.same({
      { module = "Demo.List", declarations = 2, documented = 1 },
      { module = "Demo.Seq", declarations = 3, documented = 2 },
    }, call("modules").modules)
  end)

  it("encodes empty lists as JSON arrays and reports a bad limit as an error", function()
    local text = fstardoc.call(index(), "lookup", { name = "incr" })
    assert.matches('"mentions":%[%]', text)
    local msg, is_error = fstardoc.call(index(), "used_by", { name = "incr", limit = "x" })
    assert.is_true(is_error)
    assert.matches("limit must be an integer", msg)
  end)

  it("re-reads the index file when it changes", function()
    local path = vim.fn.tempname() .. ".json"
    vim.fn.writefile(vim.fn.readfile(fixture), path)
    local first = assert(fstardoc.load(path))
    assert.equals(first, fstardoc.load(path))
    local data = vim.json.decode(table.concat(vim.fn.readfile(fixture), "\n"))
    table.remove(data.declarations)
    vim.uv.sleep(20)
    vim.fn.writefile({ vim.json.encode(data) }, path)
    local second = assert(fstardoc.load(path))
    assert.are_not.equal(first, second)
    assert.equals(4, #second.decls)
    vim.fn.delete(path)
  end)

  it("serves agent tools in process when no server is configured", function()
    docs._spawn = function()
      error("the local backend must not spawn")
    end
    local config = docs.normalize({ enabled = true, python = "/no/python", index = fixture })
    assert.equals("local", docs.backend(config))
    assert.is_nil(docs.problem(config))
    local run, tools, err = {}
    docs.prepare(run, config, function(t, e)
      tools, err = t, e
    end)
    util.wait(function()
      return tools ~= nil
    end)
    assert.is_nil(err)
    assert.equals(6, vim.tbl_count(tools))
    local text, is_error
    tools.fstardoc_lookup.handler({ name = "slice" }, {}, function(t, e)
      text, is_error = t, e
    end)
    assert.is_false(is_error)
    assert.equals("Demo.Seq.slice", vim.json.decode(text).name)
    docs.release(run.docs)
    tools.fstardoc_lookup.handler({ name = "slice" }, {}, function(t, e)
      text, is_error = t, e
    end)
    assert.is_true(is_error)
    assert.equals("documentation request ended", text)
  end)

  it("reports a missing or invalid local index", function()
    local missing = docs.normalize({ enabled = true, python = "python3", index = "/no/such.json" })
    assert.matches("index is not readable", docs.problem(missing))
    local bad = vim.fn.tempname() .. ".json"
    vim.fn.writefile({ '{"schema":"other"}' }, bad)
    local tools, err
    docs.prepare({}, docs.normalize({ enabled = true, python = "python3", index = bad }), function(t, e)
      tools, err = t, e
    end)
    assert.same({}, tools)
    assert.matches("unexpected index", err)
    assert.matches("unexpected index", docs.last_error)
    vim.fn.delete(bad)
  end)
end)
