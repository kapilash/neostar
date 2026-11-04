local config = require("neostar.config")

local function tmpdir()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return vim.fs.normalize(vim.fn.resolve(d))
end

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(text)
  fd:close()
end

describe("fstar/checking-session: configuration discovery", function()
  it("uses a config file in an ancestor directory", function()
    local d = tmpdir()
    write(d .. "/Proj.fst.config.json", vim.json.encode({
      fstar_exe = "/opt/fstar/bin/fstar.exe",
      options = { "--z3rlimit", "20" },
      include_dirs = { "/abs/lib" },
    }))
    local file = d .. "/src/A.fst"
    write(file, "module A\n")
    local cfg = assert(config.for_file(file))
    assert.equals(d, cfg.root)
    assert.equals("/opt/fstar/bin/fstar.exe", cfg.fstar_exe)
    assert.same({ "/opt/fstar/bin/fstar.exe", "--ide", file, "--z3rlimit", "20", "--include", "/abs/lib" }, config.command(file, cfg))
  end)

  it("falls back to fstar.exe on PATH without a config", function()
    local d = tmpdir()
    local file = d .. "/A.fst"
    write(file, "module A\n")
    local cfg = assert(config.for_file(file))
    assert.equals("fstar.exe", cfg.fstar_exe)
    assert.equals(d, cfg.root)
    assert.same({ "fstar.exe", "--ide", file }, config.command(file, cfg))
  end)

  it("resolves relative paths against the config file's directory", function()
    local d = tmpdir()
    write(d .. "/P.fst.config.json", vim.json.encode({
      fstar_exe = "./out/bin/fstar.exe",
      include_dirs = { "src", "../shared" },
    }))
    local cfg = assert(config.for_file(d .. "/src/A.fst"))
    assert.equals(d .. "/out/bin/fstar.exe", cfg.fstar_exe)
    assert.same({ d .. "/src", vim.fs.normalize(vim.fs.dirname(d) .. "/shared") }, cfg.include_dirs)
  end)

  it("keeps a bare executable name for PATH lookup", function()
    local d = tmpdir()
    write(d .. "/P.fst.config.json", vim.json.encode({ fstar_exe = "fstar.exe" }))
    local cfg = assert(config.for_file(d .. "/A.fst"))
    assert.equals("fstar.exe", cfg.fstar_exe)
  end)

  it("picks the alphabetically first of several configs and warns", function()
    local d = tmpdir()
    write(d .. "/b.fst.config.json", vim.json.encode({ fstar_exe = "/b/fstar.exe" }))
    write(d .. "/a.fst.config.json", vim.json.encode({ fstar_exe = "/a/fstar.exe" }))
    local cfg = assert(config.for_file(d .. "/A.fst"))
    assert.equals("/a/fstar.exe", cfg.fstar_exe)
    assert.matches("several", cfg.warning)
  end)

  it("prefers the nearest config", function()
    local d = tmpdir()
    write(d .. "/Outer.fst.config.json", vim.json.encode({ fstar_exe = "/outer/fstar.exe" }))
    write(d .. "/sub/Inner.fst.config.json", vim.json.encode({ fstar_exe = "/inner/fstar.exe" }))
    local cfg = assert(config.for_file(d .. "/sub/A.fst"))
    assert.equals("/inner/fstar.exe", cfg.fstar_exe)
    assert.equals(d .. "/sub", cfg.root)
  end)

  it("reports invalid JSON", function()
    local d = tmpdir()
    write(d .. "/P.fst.config.json", "{ not json")
    local cfg, err = config.for_file(d .. "/A.fst")
    assert.is_nil(cfg)
    assert.matches("invalid JSON", err)
  end)
end)
