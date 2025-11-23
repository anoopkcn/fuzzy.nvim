local DEFAULT_CONFIG = {
    open_single_result = false,
    file_match_limit = 600,
}

local config = vim.deepcopy(DEFAULT_CONFIG)

local M = {}

function M.setup(user_opts)
    if user_opts and type(user_opts) == "table" then
        config = vim.tbl_deep_extend("force", {}, config, user_opts)
    end
end

function M.get()
    return config
end

function M.get_file_match_limit()
    local limit = tonumber(config.file_match_limit) or DEFAULT_CONFIG.file_match_limit
    return math.max(math.floor(limit), 1)
end

return M
