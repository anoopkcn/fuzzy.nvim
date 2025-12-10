local M = {}

---@class FuzzyConfig
---@field open_single_result boolean Auto-open when only one result matches
---@field file_match_limit integer Maximum number of files to return from fd
local defaults = {
    open_single_result = false,
    file_match_limit = 600,
}

---@type FuzzyConfig
local config = vim.deepcopy(defaults)

-- Command names (centralized for consistency)
M.commands = {
    GREP = "FuzzyGrep",
    FILES = "FuzzyFiles",
    BUFFERS = "FuzzyBuffers",
    LIST = "FuzzyList",
}

---@param opts? FuzzyConfig
function M.setup(opts)
    if opts then
        vim.validate({
            open_single_result = { opts.open_single_result, "boolean", true },
            file_match_limit = { opts.file_match_limit, "number", true },
        })
    end
    config = vim.tbl_deep_extend("force", defaults, opts or {})
end

---@return FuzzyConfig
function M.get()
    return config
end

return M
