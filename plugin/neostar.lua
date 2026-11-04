if vim.g.loaded_neostar then
  return
end
vim.g.loaded_neostar = true

vim.filetype.add({ extension = { fst = "fstar", fsti = "fstar" } })
vim.treesitter.language.register("fstar", "fstar")

require("neostar.ui.signs").define_highlights()
require("neostar").create_commands()
require("neostar.treesitter").register_with_nvim_treesitter()

local group = vim.api.nvim_create_augroup("neostar", { clear = true })
vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = "fstar",
  callback = function(ev)
    require("neostar").attach(ev.buf)
  end,
})
vim.api.nvim_create_autocmd("ColorScheme", {
  group = group,
  callback = function()
    require("neostar.ui.signs").define_highlights()
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    require("neostar").stop_all()
  end,
})
