local M = {}

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
