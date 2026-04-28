local M = {}

---@class FuzzyConfig
---@field open_single_result boolean Auto-open when only one result matches
---@field file_match_limit integer Maximum number of files to return from fd
---@field grep_dedupe boolean Deduplicate grep results by file:line (default: true)
---@field send_to_qf_key string|false Key to send picker results to quickfix (false to disable)
local defaults = {
    open_single_result = false,
    file_match_limit = 10000,
    grep_dedupe = true,
    send_to_qf_key = "<M-q>",
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
        if opts.send_to_qf_key ~= nil then
            assert(
                opts.send_to_qf_key == false or type(opts.send_to_qf_key) == "string",
                "send_to_qf_key must be a string or false"
            )
        end
    end
    config = vim.tbl_deep_extend("force", defaults, opts or {})
end

---@return FuzzyConfig
function M.get()
    return config
end

return M
