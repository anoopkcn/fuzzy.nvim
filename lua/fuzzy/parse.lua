local function parse_command_args(raw)
    if not raw or raw == "" then return {} end

    local args = {}
    local current = {}
    local quote = nil

    local function push_current()
        if #current > 0 then
            args[#args + 1] = table.concat(current)
            current = {}
        end
    end

    local escapes = { n = "\n", r = "\r", t = "\t" }

    local i = 1
    while i <= #raw do
        local ch = raw:sub(i, i)

        if quote == "'" then
            if ch == "'" then
                quote = nil
            else
                current[#current + 1] = ch
            end
        elseif quote == '"' then
            if ch == '"' then
                quote = nil
            elseif ch == "\\" then
                local next_char = raw:sub(i + 1, i + 1)
                if next_char:match('["$`\\nrt]') then
                    current[#current + 1] = escapes[next_char] or next_char
                    i = i + 1
                else
                    current[#current + 1] = ch
                end
            else
                current[#current + 1] = ch
            end
        else
            if ch:match("%s") then
                push_current()
            elseif ch == "'" or ch == '"' then
                quote = ch
            elseif ch == "\\" then
                local next_char = raw:sub(i + 1, i + 1)
                if next_char ~= "" then
                    current[#current + 1] = next_char
                    i = i + 1
                end
            else
                current[#current + 1] = ch
            end
        end
        i = i + 1
    end

    push_current()
    if quote then
        vim.notify(string.format("Fuzzy: unmatched %s quote, treating literally.", quote), vim.log.levels.WARN)
    end

    return args
end

local function expand_tilde(arg)
    if type(arg) ~= "string" then
        return arg
    end

    local prefix, tilde_path = arg:match("^(.-=)(~.+)$")
    if tilde_path then
        return prefix .. vim.fn.expand(tilde_path)
    end

    if arg:match("^~") then
        return vim.fn.expand(arg)
    end

    return arg
end

local function normalize_args(arg_input)
    if type(arg_input) == "table" then
        return vim.iter(arg_input)
            :map(function(v) return expand_tilde(tostring(v)) end)
            :filter(function(v) return v ~= nil and tostring(v) ~= "" end)
            :totable()
    end
    return vim.iter(parse_command_args(arg_input)):map(expand_tilde):totable()
end

local function parse_vimgrep_line(line)
    local filename, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    if filename then
        return {
            filename = filename,
            lnum = tonumber(lnum, 10),
            col = tonumber(col, 10),
            text = text,
        }
    end

    -- Fallback for grep output without column info: file:line:text
    local filename2, lnum2, text2 = line:match("^(.-):(%d+):(.*)$")
    if filename2 then
        return {
            filename = filename2,
            lnum = tonumber(lnum2, 10),
            col = 1,
            text = text2,
        }
    end
end

return {
    parse_command_args = parse_command_args,
    normalize_args = normalize_args,
    parse_vimgrep_line = parse_vimgrep_line,
}
