-- Shared LSP transport primitives for FuzzyLspSymbols and FuzzyLspProjectSymbols.
-- Knows nothing about pickers or display formatting; just discovers clients,
-- fires requests, and reshapes responses into quickfix-shaped items.

local M = {}

---@param bufnr integer
---@param method string
---@return vim.lsp.Client[]
function M.clients_for(bufnr, method)
    return vim.lsp.get_clients({ bufnr = bufnr, method = method })
end

---@param bufnr integer
---@param method string
---@param label string  Command name used in the user-facing notification
---@return boolean ok  true when at least one client supports method
function M.require_clients(bufnr, method, label)
    if #M.clients_for(bufnr, method) > 0 then return true end
    vim.notify(label .. ": no LSP client supports " .. method, vim.log.levels.INFO)
    return false
end

-- Merge per-client results into a single qf-item list and dedupe.
-- Each client's items go through vim.lsp.util.symbols_to_items with that
-- client's offset_encoding, so multi-byte columns stay correct.
---@param responses table<integer, { result?: any, err?: any }>
---@param bufnr integer
---@return table[] items
local function responses_to_items(responses, bufnr)
    local out = {}
    local seen = {}
    for client_id, response in pairs(responses) do
        local result = response and response.result
        if type(result) == "table" and not vim.tbl_isempty(result) then
            local client = vim.lsp.get_client_by_id(client_id)
            local encoding = client and client.offset_encoding or "utf-16"
            local ok, items = pcall(vim.lsp.util.symbols_to_items, result, bufnr, encoding)
            if ok and type(items) == "table" then
                for _, item in ipairs(items) do
                    local key = ("%s:%s:%s:%s"):format(
                        item.filename or "", item.lnum or 0, item.col or 0, item.text or "")
                    if not seen[key] then
                        seen[key] = true
                        out[#out + 1] = item
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        local af, bf = a.filename or "", b.filename or ""
        if af ~= bf then return af < bf end
        local al, bl = a.lnum or 0, b.lnum or 0
        if al ~= bl then return al < bl end
        return (a.col or 0) < (b.col or 0)
    end)
    return out
end

M.responses_to_items = responses_to_items

-- vim.lsp.util.symbols_to_items writes item.text as:
--   "[Kind] name"  |  "[Kind] name in Container"  (± trailing " (deprecated)")
---@param text string
---@return string kind, string name, string container, boolean deprecated
local function parse_symbol_text(text)
    local depr = false
    local body = (text or ""):gsub("%s*%(deprecated%)%s*$", function()
        depr = true
        return ""
    end)
    local kind, rest = body:match("^%[([^%]]+)%]%s*(.+)$")
    if not kind then return "", text or "", "", false end
    local name, container = rest:match("^(.-)%s+in%s+(.+)$")
    if not name or name == "" then name, container = rest, "" end
    return kind, name, container, depr
end

M.parse_symbol_text = parse_symbol_text

---@class FuzzyLspEntry
---@field qf table          { filename, lnum, col, end_lnum, end_col, kind, text }
---@field name string
---@field kind string
---@field container string  "" or parent class/namespace
---@field deprecated boolean
---@field display_name string   "container.name" or "name"
---@field filter_text string
---@field rel_path? string   workspace-symbol picker fills this in

---@param qf_item table  output of vim.lsp.util.symbols_to_items
---@return FuzzyLspEntry
function M.make_entry(qf_item)
    local kind, name, container, deprecated = parse_symbol_text(qf_item.text or "")
    local display_name = (container ~= "" and (container .. "." .. name)) or name
    return {
        qf          = qf_item,
        name        = name,
        kind        = kind,
        container   = container,
        deprecated  = deprecated,
        display_name = display_name,
        filter_text = ("[%s] %s"):format(kind, display_name),
    }
end

---@param bufnr integer
---@param cb fun(items: table[], err_msg?: string)
---@return fun()|nil cancel
function M.request_document_symbols(bufnr, cb)
    local method = "textDocument/documentSymbol"
    -- documentSymbol only needs textDocument (no cursor position). Build it
    -- from `bufnr` explicitly — *not* from the current window — because the
    -- bang picker fires this after focus has moved into the picker input
    -- window, so make_position_params(0, ...) would point at the wrong buf.
    local params = { textDocument = { uri = vim.uri_from_bufnr(bufnr) } }
    return vim.lsp.buf_request_all(bufnr, method, params, function(responses)
        cb(responses_to_items(responses, bufnr), nil)
    end)
end

---@param bufnr integer
---@param query string
---@param cb fun(items: table[], err_msg?: string)
---@return fun()|nil cancel
function M.request_workspace_symbols(bufnr, query, cb)
    local method = "workspace/symbol"
    local params = { query = query or "" }
    -- Workspace symbol requests are project-wide, so accept any attached
    -- client that supports the method. This keeps the command useful when
    -- invoked from a buffer that has no LSP attached (e.g. the quickfix
    -- window after a previous run).
    local clients = vim.lsp.get_clients({ method = method })
    if #clients == 0 then
        cb({}, nil)
        return nil
    end
    local pending = #clients
    local responses = {}
    local cancels = {}
    local function maybe_finish()
        pending = pending - 1
        if pending > 0 then return end
        cb(responses_to_items(responses, bufnr), nil)
    end
    for _, client in ipairs(clients) do
        local ok, request_id = client:request(method, params, function(err, result)
            responses[client.id] = { err = err, result = result }
            maybe_finish()
        end, bufnr)
        if ok and request_id then
            cancels[#cancels + 1] = function() client:cancel_request(request_id) end
        else
            maybe_finish()
        end
    end
    return function()
        for _, c in ipairs(cancels) do pcall(c) end
    end
end

---@param label string  Command name used in the user-facing notification
---@return boolean ok
function M.require_any_workspace_client(label)
    if #vim.lsp.get_clients({ method = "workspace/symbol" }) > 0 then return true end
    vim.notify(label .. ": no LSP client supports workspace/symbol", vim.log.levels.INFO)
    return false
end

return M
