--- Tree-sitter parser registration for F* and Pulse.

local M = {}

M.url = "https://github.com/FStarLang/tree-sitter-fstar"
--- Pinned grammar revision; queries in queries/ were copied from it.
M.revision = "f5aca8ce0122f0ac10eaeb6f3081382d59d294f2"

M.parsers = {
  fstar = { location = nil, files = { "src/parser.c", "src/scanner.c" } },
  pulse = { location = "pulse", files = { "src/parser.c", "src/scanner.c" } },
}

local function install_info(lang)
  local p = M.parsers[lang]
  return {
    url = M.url,
    revision = M.revision,
    files = p.files,
    location = p.location,
    generate_requires_npm = false,
    requires_generate_from_grammar = false,
  }
end

--- Register parsers with nvim-treesitter (both the `master` and `main`
--- branch APIs), so `:TSInstall fstar pulse` works.
function M.register_with_nvim_treesitter()
  local ok, parsers = pcall(require, "nvim-treesitter.parsers")
  if not ok then
    return false
  end
  if type(parsers.get_parser_configs) == "function" then
    -- master branch
    local configs = parsers.get_parser_configs()
    for lang in pairs(M.parsers) do
      configs[lang] = { install_info = install_info(lang), filetype = lang == "fstar" and "fstar" or nil }
    end
  else
    -- main branch: parsers is a plain table, refreshed on User TSUpdate
    local function add()
      local p = require("nvim-treesitter.parsers")
      for lang in pairs(M.parsers) do
        p[lang] = { install_info = install_info(lang), tier = 3 }
      end
    end
    add()
    vim.api.nvim_create_autocmd("User", { pattern = "TSUpdate", callback = add })
  end
  return true
end

local warned = false

--- Start tree-sitter highlighting in a buffer; warn once if the grammar is missing.
---@param bufnr integer
---@param notify? fun(msg: string, level: integer)
---@return boolean started
function M.start(bufnr, notify)
  vim.treesitter.language.register("fstar", "fstar")
  -- language.add returns nil (with an error message) when no parser is
  -- found; older versions raised instead.
  local ok, loaded = pcall(vim.treesitter.language.add, "fstar")
  if not ok or not loaded then
    if not warned then
      warned = true
      notify = notify or function(msg, level)
        vim.notify(msg, level, { title = "neostar" })
      end
      notify(
        "neostar: tree-sitter parser for F* not found; syntax highlighting is off.\n"
          .. "Install it with :TSInstall fstar pulse (nvim-treesitter) or see :help neostar-treesitter.",
        vim.log.levels.WARN
      )
    end
    return false
  end
  return pcall(vim.treesitter.start, bufnr, "fstar")
end

--- For tests: forget that the warning was shown.
function M._reset_warning()
  warned = false
end

return M
