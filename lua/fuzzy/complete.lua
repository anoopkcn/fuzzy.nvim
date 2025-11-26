-- Fuzzy completion for command-line mode
-- Provides fuzzy file completion using cached file listings

local match = require("fuzzy.match")
local config = require("fuzzy.config")

local M = {}

-- Cache for file listings
local file_cache = {
    cwd = nil,
    files = nil,
    timestamp = 0,
}

-- Cache TTL in seconds (refresh if older than this)
local CACHE_TTL = 30

-- Maximum completion results to show
local MAX_COMPLETIONS = 50

local HAS_FD = vim.fn.executable("fd") == 1

--- Get current working directory
---@return string
local function get_cwd()
    return vim.fn.getcwd()
end

--- Check if cache is valid
---@return boolean
local function is_cache_valid()
    if not file_cache.files then
        return false
    end
    if file_cache.cwd ~= get_cwd() then
        return false
    end
    local now = os.time()
    if now - file_cache.timestamp > CACHE_TTL then
        return false
    end
    return true
end

--- Collect files using fd (synchronous for completion)
---@param limit number
---@return table
local function collect_files_fd(limit)
    local args = {
        "fd",
        "--hidden",
        "--follow",
        "--color", "never",
        "--exclude", ".git",
        "--type", "f",
        "--max-results", tostring(limit),
    }

    local result = vim.system(args, { text = true }):wait()

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

--- Collect files using vim.fs.find (fallback)
---@param limit number
---@return table
local function collect_files_fallback(limit)
    local ok, results = pcall(vim.fs.find, function()
        return true
    end, {
        path = ".",
        type = "file",
        limit = limit,
        skip = function(name)
            return name == ".git"
        end,
    })

    if not ok then
        return {}
    end

    -- Normalize paths (remove leading ./)
    local files = {}
    for _, path in ipairs(results) do
        local normalized = path:gsub("^%./", "")
        files[#files + 1] = normalized
    end

    return files
end

--- Collect files (uses fd if available, falls back to vim.fs.find)
---@return table
local function collect_files()
    local limit = config.get_file_match_limit() or 600

    if HAS_FD then
        return collect_files_fd(limit)
    end

    return collect_files_fallback(limit)
end

--- Update the file cache
local function update_cache()
    file_cache.cwd = get_cwd()
    file_cache.files = collect_files()
    file_cache.timestamp = os.time()
end

--- Get files (from cache or fresh)
---@return table
local function get_files()
    if not is_cache_valid() then
        update_cache()
    end
    return file_cache.files or {}
end

--- Invalidate the file cache
function M.invalidate_cache()
    file_cache.files = nil
    file_cache.timestamp = 0
end

--- Fuzzy file completion function for nvim_create_user_command
--- This is the function passed to the `complete` option
---@param arg_lead string current argument being completed
---@param cmd_line string entire command line
---@param cursor_pos number cursor position
---@return table list of completion candidates
function M.complete_files(arg_lead, cmd_line, cursor_pos)
    -- Handle fd-style options (don't fuzzy match these)
    if arg_lead:match("^%-") then
        -- Return common fd options
        return {
            "--hidden",
            "--no-ignore",
            "--noignore",
            "--no-ignore-vcs",
            "--follow",
            "--type",
            "--extension",
            "--exclude",
            "--max-depth",
            "--max-results",
        }
    end

    local files = get_files()

    -- If no input, return first N files sorted
    if arg_lead == "" then
        local results = {}
        for i = 1, math.min(MAX_COMPLETIONS, #files) do
            results[i] = files[i]
        end
        table.sort(results)
        return results
    end

    -- Fuzzy match and sort
    local scored = match.filter(arg_lead, files, MAX_COMPLETIONS)

    local results = {}
    for _, entry in ipairs(scored) do
        results[#results + 1] = entry.item
    end

    return results
end

--- Create a completion function that can be used with nvim_create_user_command
--- Returns a closure that handles completion
---@return function
function M.make_file_completer()
    return function(arg_lead, cmd_line, cursor_pos)
        return M.complete_files(arg_lead, cmd_line, cursor_pos)
    end
end

return M
