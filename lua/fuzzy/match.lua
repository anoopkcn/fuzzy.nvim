-- Fuzzy matching algorithm inspired by fzy but not based on it.
-- https://github.com/jhawthorn/fzy
-- Provides scoring for fuzzy matching with bonuses for:
-- - Consecutive matches
-- - Beginning of word/path matches
-- - Shorter matches

local M = {}

-- Score constants
local SCORE_GAP_LEADING = -0.005
local SCORE_GAP_TRAILING = -0.005
local SCORE_GAP_INNER = -0.01
local SCORE_MATCH_CONSECUTIVE = 1.0
local SCORE_MATCH_SLASH = 0.9
local SCORE_MATCH_WORD = 0.8
local SCORE_MATCH_CAPITAL = 0.7
local SCORE_MATCH_DOT = 0.6
local SCORE_MAX = math.huge
local SCORE_MIN = -math.huge

-- Byte constants for fast comparisons
local BYTE_SLASH = string.byte("/")
local BYTE_BACKSLASH = string.byte("\\")
local BYTE_UNDERSCORE = string.byte("_")
local BYTE_DASH = string.byte("-")
local BYTE_SPACE = string.byte(" ")
local BYTE_DOT = string.byte(".")
local BYTE_a = string.byte("a")
local BYTE_z = string.byte("z")
local BYTE_A = string.byte("A")
local BYTE_Z = string.byte("Z")

-- Local references for performance
local string_byte = string.byte
local string_lower = string.lower
local math_max = math.max
local math_min = math.min

local function is_lower(byte)
    return byte >= BYTE_a and byte <= BYTE_z
end

local function is_upper(byte)
    return byte >= BYTE_A and byte <= BYTE_Z
end

--- Compute match bonus based on character position context
---@param haystack_bytes table pre-computed byte array
---@param i number position in haystack (1-indexed)
---@return number bonus score
local function compute_bonus(haystack_bytes, i)
    if i == 1 then
        return SCORE_MATCH_SLASH -- Beginning of string is like after a slash
    end

    local prev = haystack_bytes[i - 1]
    local curr = haystack_bytes[i]

    if prev == BYTE_SLASH or prev == BYTE_BACKSLASH then
        return SCORE_MATCH_SLASH
    elseif prev == BYTE_UNDERSCORE or prev == BYTE_DASH or prev == BYTE_SPACE then
        return SCORE_MATCH_WORD
    elseif prev == BYTE_DOT then
        return SCORE_MATCH_DOT
    elseif is_lower(prev) and is_upper(curr) then
        return SCORE_MATCH_CAPITAL
    end

    return 0
end

--- Convert string to byte array for fast access
---@param str string
---@return table bytes
local function to_bytes(str)
    local bytes = {}
    for i = 1, #str do
        bytes[i] = string_byte(str, i)
    end
    return bytes
end

--- Check if needle matches haystack (case-insensitive)
---@param needle_lower_bytes table pre-lowercased needle bytes
---@param haystack_lower_bytes table pre-lowercased haystack bytes
---@return boolean matches
local function has_match(needle_lower_bytes, haystack_lower_bytes)
    local needle_len = #needle_lower_bytes
    local haystack_len = #haystack_lower_bytes

    local j = 1
    for i = 1, haystack_len do
        if haystack_lower_bytes[i] == needle_lower_bytes[j] then
            j = j + 1
            if j > needle_len then
                return true
            end
        end
    end

    return false
end

--- Compute fuzzy match score
--- Returns SCORE_MIN if no match, otherwise a score (higher is better)
---@param needle string the search pattern
---@param haystack string the string to search in
---@return number score
---@return table|nil positions matched positions (1-indexed)
function M.score(needle, haystack)
    local n = #needle
    local m = #haystack

    if n == 0 then
        return SCORE_MIN, nil
    end

    if n == m then
        -- Exact match
        if string_lower(needle) == string_lower(haystack) then
            return SCORE_MAX, nil
        end
    end

    if n > m then
        return SCORE_MIN, nil
    end

    local needle_lower = string_lower(needle)
    local haystack_lower = string_lower(haystack)

    -- Pre-compute byte arrays for fast access
    local needle_lower_bytes = to_bytes(needle_lower)
    local haystack_lower_bytes = to_bytes(haystack_lower)
    local haystack_bytes = to_bytes(haystack)

    -- Quick check: does needle match at all?
    if not has_match(needle_lower_bytes, haystack_lower_bytes) then
        return SCORE_MIN, nil
    end

    -- Dynamic programming approach
    -- D[i][j] = best score for matching needle[1..i] to haystack[1..j]
    -- Match[i][j] = best score ending with a match at position j

    local D = {}
    local Match = {}
    for i = 0, n do
        D[i] = {}
        Match[i] = {}
        for j = 0, m do
            D[i][j] = SCORE_MIN
            Match[i][j] = SCORE_MIN
        end
    end

    D[0][0] = 0
    for j = 1, m do
        D[0][j] = 0
    end

    for i = 1, n do
        local prev_score = SCORE_MIN
        local gap_score = i == n and SCORE_GAP_TRAILING or SCORE_GAP_INNER
        local nc = needle_lower_bytes[i]

        for j = i, m do
            local hc = haystack_lower_bytes[j]

            if nc == hc then
                local bonus = compute_bonus(haystack_bytes, j)

                -- Score for starting a new match sequence
                local score1 = D[i - 1][j - 1] + bonus

                -- Score for continuing a match sequence
                local score2 = Match[i - 1][j - 1] + SCORE_MATCH_CONSECUTIVE

                local match_score = math_max(score1, score2)
                Match[i][j] = match_score

                -- Best score so far
                D[i][j] = math_max(prev_score + gap_score, match_score)
            else
                Match[i][j] = SCORE_MIN
                D[i][j] = prev_score + gap_score
            end

            prev_score = D[i][j]
        end
    end

    return D[n][m], nil
end

--- Sort a list of strings by fuzzy match score against a pattern
---@param pattern string the search pattern
---@param items table list of strings to sort
---@param limit number|nil maximum number of results to return
---@return table sorted list of {item, score} pairs
function M.filter(pattern, items, limit)
    if not pattern or pattern == "" then
        local results = {}
        local max = limit or #items
        local item_count = #items
        for i = 1, math_min(max, item_count) do
            results[i] = { item = items[i], score = 0 }
        end
        return results
    end

    local scored = {}
    local scored_count = 0
    for i = 1, #items do
        local item = items[i]
        local score = M.score(pattern, item)
        if score > SCORE_MIN then
            scored_count = scored_count + 1
            scored[scored_count] = { item = item, score = score }
        end
    end

    -- Sort by score (descending), then by length (ascending), then alphabetically
    table.sort(scored, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        local len_a, len_b = #a.item, #b.item
        if len_a ~= len_b then
            return len_a < len_b
        end
        return a.item < b.item
    end)

    if limit and scored_count > limit then
        local limited = {}
        for i = 1, limit do
            limited[i] = scored[i]
        end
        return limited
    end

    return scored
end

return M
