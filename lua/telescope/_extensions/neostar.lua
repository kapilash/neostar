--- `:Telescope neostar` — browse the F* documentation index (see :h neostar-telescope).
return require("telescope").register_extension({
  exports = {
    neostar = function(opts)
      require("neostar.telescope").declarations(opts)
    end,
    declarations = function(opts)
      require("neostar.telescope").declarations(opts)
    end,
    modules = function(opts)
      require("neostar.telescope").modules(opts)
    end,
  },
})
