local M = {}

local config = {
    open_single_result = false,
    file_match_limit = 600,
}

function M.setup(opts)
    config = vim.tbl_deep_extend("force", config, opts or {})
end

function M.get()
    return config
end

return M
