local match = require("fuzzy.match")
local config = require("fuzzy.config")
local util = require("fuzzy.util")

local MAX_COMPLETIONS = 50
local CACHE_TTL = 120
local HAS_FD = vim.fn.executable("fd") == 1

local file_cache = { cwd = nil, files = nil, timestamp = 0 }

local function get_files()
    local cwd = vim.fn.getcwd()
    if file_cache.files and file_cache.cwd == cwd and (os.time() - file_cache.timestamp) <= CACHE_TTL then
        return file_cache.files
    end

    local limit = config.get().file_match_limit or 600
    local files = {}

    if HAS_FD then
        local result = vim.system({
            "fd", "--hidden", "--color", "never",
            "--exclude", ".git", "--type", "f", "--max-results", tostring(limit),
        }, { text = true }):wait()
        if result.code == 0 then
            for line in result.stdout:gmatch("[^\r\n]+") do
                if line ~= "" then files[#files + 1] = line end
            end
        end
    else
        local ok, results = pcall(vim.fs.find, function() return true end, {
            path = ".", type = "file", limit = limit,
            skip = function(name) return name == ".git" end,
        })
        if ok then
            files = vim.iter(results):map(function(p) return p:gsub("^%./", "") end):totable()
        end
    end

    file_cache = { cwd = cwd, files = files, timestamp = os.time() }
    return files
end

local function complete_files(arg_lead)
    if arg_lead:match("^%-") then
        return { "--hidden", "--no-ignore", "--noignore", "--follow", "--type", "--extension", "--exclude", "--max-depth" }
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
    make_file_completer = function() return function(a) return complete_files(a) end end,
    make_buffer_completer = function() return function(a) return complete_buffers(a) end end,
}
