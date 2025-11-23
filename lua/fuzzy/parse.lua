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

local function normalize_args(arg_input)
    if type(arg_input) == "table" then
        local mapped = vim.tbl_map(tostring, arg_input)
        return vim.tbl_filter(function(v)
            return v ~= nil and tostring(v) ~= ""
        end, mapped)
    end
    return parse_command_args(arg_input)
end

local function parse_vimgrep_line(line)
    local filename, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    return filename and {
        filename = filename,
        lnum = tonumber(lnum, 10),
        col = tonumber(col, 10),
        text = text,
    }
end

return {
    parse_command_args = parse_command_args,
    normalize_args = normalize_args,
    parse_vimgrep_line = parse_vimgrep_line,
}
