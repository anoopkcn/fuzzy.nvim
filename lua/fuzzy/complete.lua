local match = require("fuzzy.match")
local config = require("fuzzy.config")
local util = require("fuzzy.util")

local MAX_COMPLETIONS = 50
local CACHE_TTL = 120
local HAS_FD = vim.fn.executable("fd") == 1

local file_cache = { cwd = nil, files = nil, timestamp = 0, warming = false }

--- Warm the file cache asynchronously in the background
local function warm_cache()
    local cwd = vim.fn.getcwd()
    if file_cache.warming then return end
    if file_cache.files and file_cache.cwd == cwd and (os.time() - file_cache.timestamp) <= CACHE_TTL then
        return
    end

    file_cache.warming = true
    local limit = config.get().file_match_limit or 10000

    if HAS_FD then
        local system = require("fuzzy.system")
        system.run({
            "fd", "--hidden", "--color", "never",
            "--exclude", ".git", "--type", "f", "--max-results", tostring(limit),
        }, function(lines, code)
            file_cache.warming = false
            if code == 0 then
                file_cache = { cwd = cwd, files = lines, timestamp = os.time(), warming = false }
            end
        end, { cwd = cwd })
    else
        -- Fallback is synchronous but fast for small directories
        local ok, results = pcall(vim.fs.find, function() return true end, {
            path = ".", type = "file", limit = limit,
            skip = function(name) return name == ".git" end,
        })
        file_cache.warming = false
        if ok then
            local files = vim.iter(results):map(function(p) return p:gsub("^%./", "") end):totable()
            file_cache = { cwd = cwd, files = files, timestamp = os.time(), warming = false }
        end
    end
end

local function get_files()
    local cwd = vim.fn.getcwd()
    if file_cache.files and file_cache.cwd == cwd and (os.time() - file_cache.timestamp) <= CACHE_TTL then
        return file_cache.files
    end

    -- Return stale/empty cache, trigger async refresh
    warm_cache()
    return file_cache.files or {}
end

local function complete_files(arg_lead)
    if arg_lead:match("^%-") then
        return { "--hidden", "--no-ignore", "--follow", "--type", "--extension", "--exclude", "--max-depth" }
    end
    local files = get_files()
    if arg_lead == "" then
        local results = {}
        for i = 1, math.min(MAX_COMPLETIONS, #files) do results[i] = files[i] end
        table.sort(results)
        return results
    end
    return vim.iter(match.filter(arg_lead, files, MAX_COMPLETIONS)):map(function(e) return e.item end):totable()
end

local function complete_buffers(arg_lead)
    local paths = vim.iter(util.get_listed_buffers())
        :map(function(b) return vim.fn.fnamemodify(b.path, ":.") end)
        :totable()
    if arg_lead == "" then
        local results = {}
        for i = 1, math.min(MAX_COMPLETIONS, #paths) do results[i] = paths[i] end
        return results
    end
    return vim.iter(match.filter(arg_lead, paths, MAX_COMPLETIONS)):map(function(e) return e.item end):totable()
end

return {
    complete_files = complete_files,
    complete_buffers = complete_buffers,
    warm_cache = warm_cache,
    get_files = get_files,
    make_file_completer = function() return function(a) return complete_files(a) end end,
    make_buffer_completer = function() return function(a) return complete_buffers(a) end end,
}
