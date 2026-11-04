--- Project configuration discovery (`*.fst.config.json`) and F* command line.

local M = {}

---@class neostar.ProjectConfig
---@field root string            directory used as cwd and project identity
---@field config_file? string    absolute path of the config file, if any
---@field fstar_exe string
---@field options string[]
---@field include_dirs string[]
---@field warning? string        non-fatal problem to report (e.g. several configs)

local function is_abs(p)
  return p:sub(1, 1) == "/" or p:match("^%a:[/\\]") ~= nil
end

local function resolve(dir, p)
  if is_abs(p) then
    return vim.fs.normalize(p)
  end
  -- Bare executable names (no path separator) are looked up on PATH.
  return vim.fs.normalize(vim.fs.joinpath(dir, p))
end

local function config_files_in(dir)
  local found = {}
  for name, typ in vim.fs.dir(dir) do
    if (typ == "file" or typ == "link") and name:match("%.fst%.config%.json$") then
      table.insert(found, name)
    end
  end
  table.sort(found)
  return found
end

--- Find the nearest directory (the file's own, then ancestors) holding a
--- `*.fst.config.json`.
---@param file string absolute path of the F* source file
---@return string? config_file, string? warning
function M.find_config_file(file)
  local dir = vim.fs.dirname(file)
  while dir do
    local ok, found = pcall(config_files_in, dir)
    if ok and #found > 0 then
      local warning
      if #found > 1 then
        warning = ("several *.fst.config.json files in %s; using %s"):format(dir, found[1])
      end
      return vim.fs.joinpath(dir, found[1]), warning
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

--- Read and interpret a config file.
---@param config_file string
---@return neostar.ProjectConfig? cfg, string? err
function M.read_config(config_file)
  local dir = vim.fs.dirname(config_file)
  local fd = io.open(config_file, "r")
  if not fd then
    return nil, "cannot read " .. config_file
  end
  local text = fd:read("*a")
  fd:close()
  local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if not ok or type(data) ~= "table" then
    return nil, ("invalid JSON in %s"):format(config_file)
  end
  local exe = data.fstar_exe or "fstar.exe"
  if exe:find("/", 1, true) or exe:find("\\", 1, true) then
    exe = resolve(dir, exe)
  end
  local includes = {}
  for _, d in ipairs(data.include_dirs or {}) do
    table.insert(includes, resolve(dir, d))
  end
  return {
    root = dir,
    config_file = config_file,
    fstar_exe = exe,
    options = vim.deepcopy(data.options or {}),
    include_dirs = includes,
  }
end

--- Project configuration for an F* source file.
---@param file string absolute path
---@param override_exe? string user option overriding the executable
---@return neostar.ProjectConfig? cfg, string? err
function M.for_file(file, override_exe)
  local cfg_file, warning = M.find_config_file(file)
  local cfg, err
  if cfg_file then
    cfg, err = M.read_config(cfg_file)
    if not cfg then
      return nil, err
    end
    cfg.warning = warning
  else
    cfg = {
      root = vim.fs.dirname(file),
      fstar_exe = "fstar.exe",
      options = {},
      include_dirs = {},
    }
  end
  if override_exe then
    cfg.fstar_exe = override_exe
  end
  return cfg
end

--- Command line for `fstar.exe --ide` on a file.
---@param file string absolute path
---@param cfg neostar.ProjectConfig
---@return string[]
function M.command(file, cfg)
  local cmd = { cfg.fstar_exe, "--ide", file }
  vim.list_extend(cmd, cfg.options)
  for _, d in ipairs(cfg.include_dirs) do
    vim.list_extend(cmd, { "--include", d })
  end
  return cmd
end

--- Check that the executable exists; returns an error naming the path tried.
---@param exe string
---@return boolean ok, string? err
function M.check_executable(exe)
  if vim.fn.executable(exe) == 1 then
    return true
  end
  return false, ("F* executable not found: %s"):format(exe)
end

return M
