local function system_lines(command, callback)
    local stdout, stderr = {}, {}
    local stdout_pending, stderr_pending = "", ""

    local function handle_chunk(chunk, acc, pending)
        if not chunk or chunk == "" then
            return pending
        end

        local pieces = vim.split(pending .. chunk, "\n", { plain = true, trimempty = false })
        pending = table.remove(pieces) or ""

        for _, line in ipairs(pieces) do
            if line ~= "" then
                acc[#acc + 1] = line
            end
        end
        return pending
    end

    local function flush_pending(pending, acc)
        if pending ~= "" then
            acc[#acc + 1] = pending
        end
    end

    local handle, err = vim.system(command, {
        text = true,
        stdout = function(_, data)
            stdout_pending = handle_chunk(data, stdout, stdout_pending)
        end,
        stderr = function(_, data)
            stderr_pending = handle_chunk(data, stderr, stderr_pending)
        end,
    }, function(obj)
        flush_pending(stdout_pending, stdout)
        flush_pending(stderr_pending, stderr)

        vim.schedule(function()
            callback(stdout, obj.code or 0, stderr)
        end)
    end)

    if not handle then
        vim.schedule(function()
            vim.notify(string.format("Fuzzy: failed to start command: %s", err or "unknown"), vim.log.levels.ERROR)
            callback({ err or "failed to execute command" }, 1, {})
        end)
    end
end

return {
    system_lines = system_lines,
}
