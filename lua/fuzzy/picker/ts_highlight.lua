-- Per-line treesitter highlighting against persistent hidden scratch buffers.
-- One buffer per language is reused for every line of that language across
-- picker sessions; we only swap content via nvim_buf_set_lines and re-parse.
-- The single-line context is sometimes ambiguous (unterminated strings, etc),
-- but treesitter still produces good-enough captures for keywords/strings.

local M = {}

local scratch_bufs = {}    -- lang (string) -> bufnr
local lang_cache   = {}    -- filename (string) -> lang|false (false = no parser)

local function get_lang(filename)
    if filename == nil or filename == "" then return nil end
    local cached = lang_cache[filename]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end

    local ft = vim.filetype.match({ filename = filename })
    if not ft or ft == "" then
        lang_cache[filename] = false
        return nil
    end
    local lang = vim.treesitter.language.get_lang(ft) or ft
    local ok = pcall(vim.treesitter.language.add, lang)
    if not ok then
        lang_cache[filename] = false
        return nil
    end
    lang_cache[filename] = lang
    return lang
end

local function get_scratch_buf(lang)
    local buf = scratch_bufs[lang]
    if buf and vim.api.nvim_buf_is_valid(buf) then return buf end
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden  = "hide"
    vim.bo[buf].buftype    = "nofile"
    vim.bo[buf].swapfile   = false
    vim.bo[buf].undolevels = -1
    scratch_bufs[lang] = buf
    return buf
end

--- Compute treesitter highlight ranges for a single line of code from
--- `filename`. Returns an array of `{ col, end_col, hl_group }` tuples
--- (0-indexed byte columns), or nil if no parser/query is available.
---@param filename string
---@param text string
---@return table[]|nil
function M.get_line_highlights(filename, text)
    if text == nil or text == "" then return nil end
    local lang = get_lang(filename)
    if not lang then return nil end

    local buf = get_scratch_buf(lang)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })

    local ok_parser, parser = pcall(vim.treesitter.get_parser, buf, lang)
    if not ok_parser or not parser then return nil end
    local ok_parse, trees = pcall(parser.parse, parser, true)
    if not ok_parse or not trees or not trees[1] then return nil end

    local query = vim.treesitter.query.get(lang, "highlights")
    if not query then return nil end

    local root = trees[1]:root()
    local out = {}
    local ok_iter, iter = pcall(query.iter_captures, query, root, buf, 0, 1)
    if not ok_iter then return nil end
    for id, node in iter do
        local name = query.captures[id]
        if name then
            local r1, c1, r2, c2 = node:range()
            if r1 == 0 and r2 == 0 and c2 > c1 then
                out[#out + 1] = {
                    col       = c1,
                    end_col   = c2,
                    hl_group  = "@" .. name .. "." .. lang,
                }
            end
        end
    end
    return out
end

--- Drop all cached scratch buffers and resolved langs. Not required during
--- normal use (Neovim cleans up on exit); useful for tests / debug.
function M.cleanup()
    for _, buf in pairs(scratch_bufs) do
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    scratch_bufs = {}
    lang_cache = {}
end

return M
