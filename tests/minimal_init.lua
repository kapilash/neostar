-- Minimal init for headless tests: this plugin, plenary, and test parsers.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local plenary = os.getenv("PLENARY_DIR") or (root .. "/.deps/plenary.nvim")
local parsers = os.getenv("PARSER_DIR") or (root .. "/.deps/parsers")
if not plenary:match("^/") then plenary = root .. "/" .. plenary end
if not parsers:match("^/") then parsers = root .. "/" .. parsers end

vim.opt.runtimepath = { vim.env.VIMRUNTIME, root, plenary, parsers }
vim.opt.packpath = {}
vim.o.swapfile = false
vim.o.shadafile = "NONE"
package.path = root .. "/tests/?.lua;" .. package.path

vim.cmd("runtime plugin/plenary.vim")
vim.cmd("runtime plugin/neostar.lua")
