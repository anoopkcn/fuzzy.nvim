--- Run a command and collect output lines
--- @param command table Command and arguments
--- @param callback function(lines, code, stderr) Called on completion
--- @return table|nil handle Process handle with :kill() method, or nil on error
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
        return nil
    end

    return handle
end

--- Run a command with incremental/streaming results
--- @param command table Command and arguments
--- @param on_lines function(lines) Called incrementally as lines arrive
--- @param on_done function(code, stderr) Called on completion
--- @return table|nil handle Process handle with :kill() method
local function system_lines_streaming(command, on_lines, on_done)
    local stderr = {}
    local stdout_pending, stderr_pending = "", ""
    local batch = {}
    local batch_timer = nil
    local BATCH_INTERVAL_MS = 16 -- ~60fps, batches rapid output

    local function flush_batch()
        if #batch > 0 then
            local to_send = batch
            batch = {}
            vim.schedule(function()
                on_lines(to_send)
            end)
        end
    end

    local function handle_stdout_chunk(chunk, pending)
        if not chunk or chunk == "" then
            return pending
        end

        local pieces = vim.split(pending .. chunk, "\n", { plain = true, trimempty = false })
        pending = table.remove(pieces) or ""

        for _, line in ipairs(pieces) do
            if line ~= "" then
                batch[#batch + 1] = line
            end
        end

        -- Start batch timer if not running
        if #batch > 0 and not batch_timer then
            batch_timer = vim.uv.new_timer()
            batch_timer:start(BATCH_INTERVAL_MS, 0, function()
                batch_timer:stop()
                batch_timer:close()
                batch_timer = nil
                flush_batch()
            end)
        end

        return pending
    end

    local function handle_stderr_chunk(chunk, acc, pending)
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

    local handle, err = vim.system(command, {
        text = true,
        stdout = function(_, data)
            stdout_pending = handle_stdout_chunk(data, stdout_pending)
        end,
        stderr = function(_, data)
            stderr_pending = handle_stderr_chunk(data, stderr, stderr_pending)
        end,
    }, function(obj)
        -- Cancel pending batch timer
        if batch_timer then
            batch_timer:stop()
            batch_timer:close()
            batch_timer = nil
        end

        -- Flush remaining
        if stdout_pending ~= "" then
            batch[#batch + 1] = stdout_pending
        end
        if stderr_pending ~= "" then
            stderr[#stderr + 1] = stderr_pending
        end

        -- Final flush
        vim.schedule(function()
            if #batch > 0 then
                on_lines(batch)
            end
            on_done(obj.code or 0, stderr)
        end)
    end)

    if not handle then
        vim.schedule(function()
            vim.notify(string.format("Fuzzy: failed to start command: %s", err or "unknown"), vim.log.levels.ERROR)
            on_done(1, { err or "failed to execute command" })
        end)
        return nil
    end

    return handle
end

return {
    system_lines = system_lines,
    system_lines_streaming = system_lines_streaming,
}
