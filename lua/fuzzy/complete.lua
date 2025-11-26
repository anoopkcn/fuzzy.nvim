-- Fuzzy completion for command-line mode
-- Provides fuzzy file and buffer completion

local match = require("fuzzy.match")
local config = require("fuzzy.config")

local M = {}

-- Maximum completion results to show
local MAX_COMPLETIONS = 50

-------------------------------------------------------------------------------
-- File completion
-------------------------------------------------------------------------------

local file_cache = {
    cwd = nil,
    files = nil,
    timestamp = 0,
}

local CACHE_TTL = 30
local HAS_FD = vim.fn.executable("fd") == 1

local function get_cwd()
    return vim.fn.getcwd()
end

local function is_file_cache_valid()
    if not file_cache.files then
        return false
    end
    if file_cache.cwd ~= get_cwd() then
        return false
    end
    return (os.time() - file_cache.timestamp) <= CACHE_TTL
end

local function collect_files_fd(limit)
    local result = vim.system({
        "fd", "--hidden", "--follow", "--color", "never",
        "--exclude", ".git", "--type", "f",
        "--max-results", tostring(limit),
    }, { text = true }):wait()

    if result.code ~= 0 then
        return {}
    end

    local files = {}
    for line in result.stdout:gmatch("[^\r\n]+") do
        if line ~= "" then
            files[#files + 1] = line
        end
    end
    return files
end

local function collect_files_fallback(limit)
    local ok, results = pcall(vim.fs.find, function() return true end, {
        path = ".",
        type = "file",
        limit = limit,
        skip = function(name) return name == ".git" end,
    })

    if not ok then
        return {}
    end

    return vim.iter(results):map(function(p)
        return p:gsub("^%./", "")
    end):totable()
end

local function get_files()
    if not is_file_cache_valid() then
        local limit = config.get_file_match_limit() or 600
        file_cache.cwd = get_cwd()
        file_cache.files = HAS_FD and collect_files_fd(limit) or collect_files_fallback(limit)
        file_cache.timestamp = os.time()
    end
    return file_cache.files or {}
end

function M.complete_files(arg_lead, cmd_line, cursor_pos)
    if arg_lead:match("^%-") then
        return {
            "--hidden", "--no-ignore", "--noignore", "--no-ignore-vcs",
            "--follow", "--type", "--extension", "--exclude",
            "--max-depth", "--max-results",
        }
    end

    local files = get_files()

    if arg_lead == "" then
        local results = {}
        for i = 1, math.min(MAX_COMPLETIONS, #files) do
            results[i] = files[i]
        end
        table.sort(results)
        return results
    end

    local scored = match.filter(arg_lead, files, MAX_COMPLETIONS)
    return vim.iter(scored):map(function(e) return e.item end):totable()
end

function M.make_file_completer()
    return function(arg_lead, cmd_line, cursor_pos)
        return M.complete_files(arg_lead, cmd_line, cursor_pos)
    end
end

-------------------------------------------------------------------------------
-- Buffer completion
-------------------------------------------------------------------------------

--- Get list of buffer file paths (same format as file completion)
---@return table list of buffer paths
local function get_buffer_paths()
    local paths = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
            local buftype = vim.bo[buf].buftype
            if buftype == "" then
                local name = vim.api.nvim_buf_get_name(buf)
                if name ~= "" then
                    paths[#paths + 1] = name
                end
            end
        end
    end
    return paths
end

function M.complete_buffers(arg_lead, cmd_line, cursor_pos)
    local buffers = get_buffer_paths()

    if arg_lead == "" then
        local results = {}
        for i = 1, math.min(MAX_COMPLETIONS, #buffers) do
            results[i] = buffers[i]
        end
        return results
    end

    local scored = match.filter(arg_lead, buffers, MAX_COMPLETIONS)
    return vim.iter(scored):map(function(e) return e.item end):totable()
end

function M.make_buffer_completer()
    return function(arg_lead, cmd_line, cursor_pos)
        return M.complete_buffers(arg_lead, cmd_line, cursor_pos)
    end
end

return M
