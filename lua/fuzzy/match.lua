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

-- Module-level reusable flat arrays to avoid per-call allocations
local _D = {}
local _Match = {}
local _D_size = 0

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

    -- Pre-compute byte arrays using multi-return string.byte
    local needle_lower_bytes = { string_byte(needle_lower, 1, n) }
    local haystack_lower_bytes = { string_byte(haystack_lower, 1, m) }
    local haystack_bytes = { string_byte(haystack, 1, m) }

    -- Quick check: does needle match at all?
    if not has_match(needle_lower_bytes, haystack_lower_bytes) then
        return SCORE_MIN, nil
    end

    -- Dynamic programming with reusable flat arrays
    -- Index as [i * stride + j + 1] (1-indexed Lua)
    local stride = m + 1
    local needed = (n + 1) * stride

    -- Grow arrays if needed, zero the portion we use
    if needed > _D_size then
        for k = _D_size + 1, needed do
            _D[k] = SCORE_MIN
            _Match[k] = SCORE_MIN
        end
        _D_size = needed
    else
        for k = 1, needed do
            _D[k] = SCORE_MIN
            _Match[k] = SCORE_MIN
        end
    end

    -- D[0][0] = 0
    _D[1] = 0
    -- D[0][j] = 0 for j = 1..m
    for j = 1, m do
        _D[j + 1] = 0
    end

    for i = 1, n do
        local prev_score = SCORE_MIN
        local gap_score = i == n and SCORE_GAP_TRAILING or SCORE_GAP_INNER
        local nc = needle_lower_bytes[i]
        local row_base = i * stride

        for j = i, m do
            local hc = haystack_lower_bytes[j]
            local idx = row_base + j + 1

            if nc == hc then
                local bonus = compute_bonus(haystack_bytes, j)

                -- Score for starting a new match sequence
                local prev_row_prev_col = (i - 1) * stride + j
                local score1 = _D[prev_row_prev_col] + bonus

                -- Score for continuing a match sequence
                local score2 = _Match[prev_row_prev_col] + SCORE_MATCH_CONSECUTIVE

                local match_score = math_max(score1, score2)
                _Match[idx] = match_score

                -- Best score so far
                _D[idx] = math_max(prev_score + gap_score, match_score)
            else
                _Match[idx] = SCORE_MIN
                _D[idx] = prev_score + gap_score
            end

            prev_score = _D[idx]
        end
    end

    return _D[n * stride + m + 1], nil
end

--- Greedy left-to-right byte positions where needle matched haystack
--- (case-insensitive). Returns nil if no match. Suitable for highlighting;
--- the DP scorer in M.score may pick different positions for ranking.
---@param needle string
---@param haystack string
---@return integer[]|nil 1-indexed byte positions in haystack
function M.positions(needle, haystack)
    if needle == nil or needle == "" then return nil end
    if #needle > #haystack then return nil end
    local nlow = string_lower(needle)
    local hlow = string_lower(haystack)
    local positions = {}
    local hi = 1
    for ni = 1, #nlow do
        local nc = string_byte(nlow, ni)
        local found = false
        while hi <= #hlow do
            if string_byte(hlow, hi) == nc then
                positions[ni] = hi
                found = true
                hi = hi + 1
                break
            end
            hi = hi + 1
        end
        if not found then return nil end
    end
    return positions
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
