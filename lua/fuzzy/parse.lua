local M = {}

local RG_SHORT_FLAGS_WITH_VALUE = {
    ["-A"] = true,
    ["-B"] = true,
    ["-C"] = true,
    ["-E"] = true,
    ["-e"] = true,
    ["-f"] = true,
    ["-g"] = true,
    ["-j"] = true,
    ["-M"] = true,
    ["-m"] = true,
    ["-r"] = true,
    ["-t"] = true,
    ["-T"] = true,
}

local RG_LONG_FLAGS_WITH_VALUE = {
    ["--after-context"] = true,
    ["--before-context"] = true,
    ["--color"] = true,
    ["--colors"] = true,
    ["--context"] = true,
    ["--context-separator"] = true,
    ["--engine"] = true,
    ["--encoding"] = true,
    ["--field-context-separator"] = true,
    ["--field-match-separator"] = true,
    ["--glob"] = true,
    ["--iglob"] = true,
    ["--ignore-file"] = true,
    ["--max-columns"] = true,
    ["--max-count"] = true,
    ["--max-depth"] = true,
    ["--path-separator"] = true,
    ["--pre"] = true,
    ["--pre-glob"] = true,
    ["--regex-size-limit"] = true,
    ["--replace"] = true,
    ["--sort"] = true,
    ["--sortr"] = true,
    ["--threads"] = true,
    ["--type"] = true,
    ["--type-add"] = true,
    ["--type-clear"] = true,
    ["--type-not"] = true,
}

--- Parse shell-like command arguments with quote handling
---@param raw string
---@return table
function M.args(raw)
    if not raw or raw == "" then return {} end

    local args, current, quote = {}, {}, nil
    local escapes = { n = "\n", r = "\r", t = "\t" }
    local i = 1

    while i <= #raw do
        local ch = raw:sub(i, i)

        if quote == "'" then
            if ch == "'" then quote = nil else current[#current + 1] = ch end
        elseif quote == '"' then
            if ch == '"' then
                quote = nil
            elseif ch == "\\" and raw:sub(i + 1, i + 1):match('["$`\\nrt]') then
                local nc = raw:sub(i + 1, i + 1)
                current[#current + 1] = escapes[nc] or nc
                i = i + 1
            else
                current[#current + 1] = ch
            end
        elseif ch:match("%s") then
            if #current > 0 then args[#args + 1] = table.concat(current); current = {} end
        elseif ch == "'" or ch == '"' then
            quote = ch
        elseif ch == "\\" and raw:sub(i + 1, i + 1) ~= "" then
            current[#current + 1] = raw:sub(i + 1, i + 1)
            i = i + 1
        else
            current[#current + 1] = ch
        end
        i = i + 1
    end

    if #current > 0 then args[#args + 1] = table.concat(current) end
    return args
end

--- Split the first shell-token off a raw string, preserving the raw remainder.
--- The first token is fully unquoted/unescaped; the remainder is returned verbatim
--- so it can be re-parsed later (e.g. as rg arguments or an initial picker query).
---@param raw string
---@return string|nil first_token, string raw_rest
function M.split_first(raw)
    if not raw or raw == "" then return nil, "" end
    local i = 1
    while i <= #raw and raw:sub(i, i):match("%s") do i = i + 1 end
    if i > #raw then return nil, "" end

    local token = {}
    local quote = nil
    local escapes = { n = "\n", r = "\r", t = "\t" }

    while i <= #raw do
        local ch = raw:sub(i, i)
        if quote == "'" then
            if ch == "'" then quote = nil else token[#token + 1] = ch end
        elseif quote == '"' then
            if ch == '"' then
                quote = nil
            elseif ch == "\\" and raw:sub(i + 1, i + 1):match('["$`\\nrt]') then
                local nc = raw:sub(i + 1, i + 1)
                token[#token + 1] = escapes[nc] or nc
                i = i + 1
            else
                token[#token + 1] = ch
            end
        elseif ch:match("%s") then
            local j = i
            while j <= #raw and raw:sub(j, j):match("%s") do j = j + 1 end
            return table.concat(token), j <= #raw and raw:sub(j) or ""
        elseif ch == "'" or ch == '"' then
            quote = ch
        elseif ch == "\\" and raw:sub(i + 1, i + 1) ~= "" then
            token[#token + 1] = raw:sub(i + 1, i + 1)
            i = i + 1
        else
            token[#token + 1] = ch
        end
        i = i + 1
    end
    return #token > 0 and table.concat(token) or nil, ""
end

--- Normalize arguments: expand tilde, handle string or table input
---@param input string|table
---@return table
function M.normalize(input)
    local args = type(input) == "table" and input or M.args(input)
    return vim.iter(args):map(function(arg)
        return arg:match("^~") and vim.fn.expand(arg) or arg
    end):filter(function(v) return v ~= "" end):totable()
end

local function shell_quote(arg)
    if arg == "" then return "''" end
    if not arg:find("[%s'\"]") then return arg end
    return "'" .. arg:gsub("'", [["'"']]) .. "'"
end

local function rg_flag_takes_value(token)
    if not token or token == "" or token == "--" then return false end
    if token:match("^%-%-[^=]+=") then return false end
    return RG_SHORT_FLAGS_WITH_VALUE[token] or RG_LONG_FLAGS_WITH_VALUE[token] or false
end

--- Join normalized arguments into a shell-like string for display or editing.
---@param args string[]|string
---@return string
function M.join(args)
    local parts = type(args) == "string" and M.normalize(args) or M.normalize(args or {})
    return table.concat(vim.tbl_map(shell_quote, parts), " ")
end

--- Split a grep picker invocation into the editable query and backend flags.
--- The picker keeps a single live query string, so only the first positional
--- argument is treated as the query; supported rg flags stay in the backend
--- flag list, preserving their original order.
---@param raw string
---@return string|nil query, string[] flags
function M.split_grep_picker_args(raw)
    local tokens = M.args(raw or "")
    local flags = {}
    local query = nil
    local expect_value = false

    for _, token in ipairs(tokens) do
        if expect_value then
            flags[#flags + 1] = token
            expect_value = false
        elseif token ~= "-" and token:sub(1, 1) == "-" then
            flags[#flags + 1] = token
            expect_value = rg_flag_takes_value(token)
        elseif not query then
            query = token
        else
            flags[#flags + 1] = token
        end
    end

    return query, M.normalize(flags)
end

--- Parse vimgrep format line (file:line:col:text)
---@param line string
---@return table|nil {filename, lnum, col, text}
function M.vimgrep(line)
    local f, l, c, t = line:match("^(.-):(%d+):(%d+):(.*)$")
    if f then return { filename = f, lnum = tonumber(l), col = tonumber(c), text = t } end
    -- Fallback without column
    f, l, t = line:match("^(.-):(%d+):(.*)$")
    if f then return { filename = f, lnum = tonumber(l), col = 1, text = t } end
end

return M
