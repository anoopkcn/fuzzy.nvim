local M = {}

--- Optional: customize configuration. The plugin works without this call;
--- commands are registered automatically by plugin/fuzzy.lua at startup.
function M.setup(opts)
    require("fuzzy.config").setup(opts)
end

--- Programmatically run a grep search and populate the quickfix list.
function M.grep(args) require("fuzzy.commands.grep").run(args) end

return M
