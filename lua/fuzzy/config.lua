local M = {}

---@class FuzzyConfig
---@field open_single_result boolean Auto-open when only one result matches
---@field file_match_limit integer Maximum number of files to return from fd
---@field grep_dedupe boolean Deduplicate grep results by file:line (default: true)
local defaults = {
    open_single_result = false,
    file_match_limit = 10000,
    grep_dedupe = true,
}

---@type FuzzyConfig
local config = vim.deepcopy(defaults)

-- Command names (centralized for consistency)
M.commands = {
    GREP = "FuzzyGrep",
    GREP_IN = "FuzzyGrepIn",
    FILES = "FuzzyFiles",
    BUFFERS = "FuzzyBuffers",
    LIST = "FuzzyList",
}

---@param opts? FuzzyConfig
function M.setup(opts)
    if opts then
        vim.validate("open_single_result", opts.open_single_result, "boolean", true)
        vim.validate("file_match_limit", opts.file_match_limit, "number", true)
        vim.validate("grep_dedupe", opts.grep_dedupe, "boolean", true)
    end
    config = vim.tbl_deep_extend("force", defaults, opts or {})
end

---@return FuzzyConfig
function M.get()
    return config
end

return M
