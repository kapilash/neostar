--- Telescope pickers over the fstardoc index:
---   :Telescope neostar declarations [module=FStar.Seq.Base]
---   :Telescope neostar modules
--- <CR> opens the declaration's source, <C-y> inserts its fully qualified name.

local M = {}

local browse = require("neostar.docs_browse")

local function notify(msg)
  vim.notify("neostar: " .. msg, vim.log.levels.WARN, { title = "neostar" })
end

local function deps()
  local ok = pcall(require, "telescope")
  if not ok then
    notify("telescope.nvim is not installed; use :NeostarDocs instead")
    return nil
  end
  return {
    pickers = require("telescope.pickers"),
    finders = require("telescope.finders"),
    previewers = require("telescope.previewers"),
    actions = require("telescope.actions"),
    state = require("telescope.actions.state"),
    conf = require("telescope.config").values,
    entry_display = require("telescope.pickers.entry_display"),
  }
end

local function preview(T)
  return T.previewers.new_buffer_previewer({
    title = "F* documentation",
    define_preview = function(self, entry)
      local buf = self.state.bufnr
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, browse.preview_lines(entry.value))
      vim.bo[buf].filetype = "markdown"
      vim.api.nvim_set_option_value("wrap", true, { win = self.state.winid })
      vim.api.nvim_set_option_value("conceallevel", 2, { win = self.state.winid })
    end,
  })
end

--- Every public declaration in the index, or one module's.
---@param opts? {module?: string}
function M.declarations(opts)
  opts = opts or {}
  local T = deps()
  if not T then
    return
  end
  local idx, err = browse.index()
  if not idx then
    notify(err)
    return
  end
  local decls, derr = browse.declarations(idx, opts.module)
  if not decls then
    notify(derr)
    return
  end
  local from_win = vim.api.nvim_get_current_win()
  local from_file = vim.api.nvim_buf_get_name(0)
  local displayer = T.entry_display.create({
    separator = " ",
    items = { { width = 6 }, { width = 0.4 }, { remaining = true } },
  })
  T.pickers
    .new(opts, {
      prompt_title = opts.module and ("F* declarations in " .. opts.module) or "F* declarations",
      finder = T.finders.new_table({
        results = decls,
        entry_maker = function(d)
          return {
            value = d,
            ordinal = browse.ordinal(d),
            display = function()
              return displayer({
                { d.kind, "TelescopeResultsIdentifier" },
                d.name,
                { (d.signature or ""):gsub("%s+", " "), "TelescopeResultsComment" },
              })
            end,
          }
        end,
      }),
      sorter = T.conf.generic_sorter(opts),
      previewer = preview(T),
      attach_mappings = function(prompt, map)
        T.actions.select_default:replace(function()
          local entry = T.state.get_selected_entry()
          T.actions.close(prompt)
          if entry then
            browse.open(entry.value, from_file)
          end
        end)
        local function insert()
          local entry = T.state.get_selected_entry()
          T.actions.close(prompt)
          if entry then
            browse.insert(from_win, entry.value.name)
          end
        end
        map({ "i", "n" }, "<C-y>", insert)
        return true
      end,
    })
    :find()
end

--- The indexed modules; choosing one lists its declarations.
---@param opts? table
function M.modules(opts)
  opts = opts or {}
  local T = deps()
  if not T then
    return
  end
  local idx, err = browse.index()
  if not idx then
    notify(err)
    return
  end
  local counts = {}
  for _, d in ipairs(idx.decls) do
    local c = counts[d.module] or { total = 0, documented = 0 }
    c.total = c.total + 1
    if d.doc ~= nil then
      c.documented = c.documented + 1
    end
    counts[d.module] = c
  end
  T.pickers
    .new(opts, {
      prompt_title = "F* modules",
      finder = T.finders.new_table({
        results = idx:module_names(),
        entry_maker = function(m)
          local c = counts[m]
          return {
            value = m,
            ordinal = m,
            display = ("%s  (%d declarations, %d documented)"):format(m, c.total, c.documented),
          }
        end,
      }),
      sorter = T.conf.generic_sorter(opts),
      attach_mappings = function(prompt)
        T.actions.select_default:replace(function()
          local entry = T.state.get_selected_entry()
          T.actions.close(prompt)
          if entry then
            vim.schedule(function()
              M.declarations({ module = entry.value })
            end)
          end
        end)
        return true
      end,
    })
    :find()
end

return M
