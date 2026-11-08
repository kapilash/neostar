--- Browsing the fstardoc index as a person: picker entries, a Markdown
--- preview of one declaration, and finding its source file. Used by the
--- Telescope extension and by :NeostarDocs without Telescope.

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "neostar" })
end

--- The configured index, loaded (and re-read if the file changed).
---@return table? index, string? err
function M.index()
  local path = require("neostar").options.agent.docs.index
  return require("neostar.fstardoc").load(path)
end

--- Declarations to list: all of them, or one module's.
---@param idx table
---@param module? string
---@return table[]? decls, string? err
function M.declarations(idx, module)
  if not module or module == "" then
    return idx.decls
  end
  local out = {}
  for _, d in ipairs(idx.decls) do
    if d.module == module then
      out[#out + 1] = d
    end
  end
  if #out == 0 then
    return nil, ("no module %s in the documentation index"):format(module)
  end
  return out
end

--- Text that fuzzy matching runs on: the name, then the signature.
function M.ordinal(d)
  return d.name .. " " .. (d.signature or "")
end

--- Markdown lines describing one declaration.
function M.preview_lines(d)
  local lines = { "# " .. d.name, "" }
  local meta = { "`" .. d.kind .. "`" }
  if d.eff then
    meta[#meta + 1] = "effect `" .. d.eff .. "`"
  end
  if d.where then
    meta[#meta + 1] = ("%s:%d"):format(d.where.file, d.where.start_line)
  end
  lines[#lines + 1] = table.concat(meta, " · ")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "```fstar"
  vim.list_extend(lines, vim.split(d.signature or "", "\n", { plain = true }))
  lines[#lines + 1] = "```"
  lines[#lines + 1] = ""
  if d.doc == nil then
    lines[#lines + 1] = "_Undocumented. The signature above is checked by F*._"
  elseif #d.doc == 0 then
    lines[#lines + 1] = "_Documented with an empty comment._"
  else
    for _, l in ipairs(d.doc) do
      vim.list_extend(lines, vim.split(l, "\n", { plain = true }))
    end
  end
  local function names(title, list)
    if list and #list > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "**" .. title .. ":** " .. table.concat(vim.tbl_map(function(n)
        return "`" .. n .. "`"
      end, list), ", ")
    end
  end
  names("Requires about", d.pre)
  names("Ensures about", d.post)
  names("Mentions", d.refs)
  if d.definition and d.definition ~= "" then
    vim.list_extend(lines, { "", "**Definition:**", "", "```fstar" })
    vim.list_extend(lines, vim.split(d.definition, "\n", { plain = true }))
    lines[#lines + 1] = "```"
  end
  return lines
end

local lib_dirs = {} ---@type table<string, string[]>

--- Library include directories of an F* executable: `--locate_lib` and the
--- directories its `fstar.include` lists. Cached per executable.
function M.library_dirs(exe)
  if lib_dirs[exe] then
    return lib_dirs[exe]
  end
  local dirs = {}
  if vim.fn.executable(exe) == 1 then
    local res = vim.system({ exe, "--locate_lib" }, { text = true }):wait(5000)
    local lib = res.code == 0 and vim.trim(res.stdout or "") or ""
    if lib ~= "" then
      dirs[#dirs + 1] = lib
      local fd = io.open(lib .. "/fstar.include", "r")
      if fd then
        for line in fd:lines() do
          line = vim.trim(line)
          if line ~= "" and not line:match("^#") then
            dirs[#dirs + 1] = vim.fs.normalize(vim.fs.joinpath(lib, line))
          end
        end
        fd:close()
      end
    end
  end
  lib_dirs[exe] = dirs
  return dirs
end

--- Directories to look in for a declaration's file, seen from `from_file`:
--- that project's root and include_dirs, then the F* library.
function M.search_dirs(from_file)
  local opts = require("neostar").options
  local exe, dirs = opts.fstar_exe or "fstar.exe", {}
  if from_file and from_file ~= "" then
    local cfg = require("neostar.config").for_file(from_file, opts.fstar_exe)
    if cfg then
      exe = cfg.fstar_exe or exe
      if cfg.root then
        dirs[#dirs + 1] = cfg.root
      end
      vim.list_extend(dirs, cfg.include_dirs or {})
    end
  end
  dirs[#dirs + 1] = vim.fn.getcwd()
  vim.list_extend(dirs, M.library_dirs(exe))
  return dirs
end

--- Absolute path of a declaration's source file, or nil.
function M.locate(d, from_file)
  local file = d.where and d.where.file
  if not file or file == "" then
    return nil
  end
  if file:sub(1, 1) == "/" then
    return vim.fn.filereadable(file) == 1 and file or nil
  end
  for _, dir in ipairs(M.search_dirs(from_file)) do
    local path = vim.fs.joinpath(dir, file)
    if vim.fn.filereadable(path) == 1 then
      return vim.fs.normalize(path)
    end
  end
  return nil
end

--- Open a declaration's source at its range.
---@param d table declaration
---@param from_file? string the file the user was in, for project include paths
function M.open(d, from_file)
  local path = M.locate(d, from_file)
  if not path then
    notify(("neostar: cannot find %s for %s"):format(d.where and d.where.file or "a source file", d.name),
      vim.log.levels.WARN)
    return false
  end
  vim.cmd.edit(vim.fn.fnameescape(path))
  local line = math.max(1, d.where.start_line or 1)
  line = math.min(line, vim.api.nvim_buf_line_count(0))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(0, d.where.start_col or 0) })
  vim.cmd("normal! zz")
  return true
end

--- Insert a name at the cursor of `win`.
function M.insert(win, text)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_put({ text }, "c", true, true)
end

--- Without Telescope: pick with vim.ui.select, then open the source.
function M.select(module)
  local idx, err = M.index()
  if not idx then
    notify("neostar: " .. err, vim.log.levels.WARN)
    return
  end
  local decls, derr = M.declarations(idx, module)
  if not decls then
    notify("neostar: " .. derr, vim.log.levels.WARN)
    return
  end
  local from = vim.api.nvim_buf_get_name(0)
  vim.ui.select(decls, {
    prompt = "F* declarations",
    format_item = function(d)
      return ("%-5s %s : %s"):format(d.kind, d.name, d.signature or "")
    end,
  }, function(d)
    if d then
      M.open(d, from)
    end
  end)
end

--- :NeostarDocs [module]: Telescope when available, else vim.ui.select.
function M.command(module)
  local ok, telescope = pcall(require, "telescope")
  if ok and telescope.extensions then
    pcall(telescope.load_extension, "neostar")
    return require("neostar.telescope").declarations({ module = module })
  end
  M.select(module)
end

--- Module names, for :NeostarDocs completion.
function M.complete(lead)
  local idx = M.index()
  if not idx then
    return {}
  end
  return vim.tbl_filter(function(m)
    return vim.startswith(m, lead)
  end, idx:module_names())
end

return M
