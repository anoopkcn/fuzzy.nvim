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

-- Module-level reusable flat arrays to avoid per-call allocations.
-- _D / _Match: dynamic-programming grids (flat, indexed as i*stride + j+1).
-- _NB / _HBL / _HB: byte scratch for needle-lower, haystack-lower, haystack.
-- Sizes grow monotonically; entries past the current logical length are stale
-- but never read because the score loop is driven by explicit n / m lengths.
local _D = {}
local _Match = {}
local _D_size = 0
local _NB = {}
local _HBL = {}
local _HB = {}

--- Fill scratch[1..len] with the bytes of s. Returns len.
--- Uses single-return string_byte per index — zero allocation, JIT-friendly.
local function fill_bytes(scratch, s, len)
    for k = 1, len do
        scratch[k] = string_byte(s, k)
    end
    return len
end

--- Quick "is needle a subsequence of haystack" check operating directly on
--- strings, no array fills required. Used as a cheap reject test before
--- committing to the DP scoring work.
local function has_match_str(needle_lower, haystack_lower)
    local nlen = #needle_lower
    local hlen = #haystack_lower
    if nlen == 0 then return false end
    if nlen > hlen then return false end
    local j = 1
    local nc = string_byte(needle_lower, 1)
    for i = 1, hlen do
        if string_byte(haystack_lower, i) == nc then
            j = j + 1
            if j > nlen then return true end
            nc = string_byte(needle_lower, j)
        end
    end
    return false
end

--- True when the string contains no ASCII uppercase letter, so string.lower()
--- would be a no-op. Lets us skip the lowercase allocation for the common
--- case (most file paths and lowercase identifiers).
local function is_already_lower(s)
    for i = 1, #s do
        local b = string_byte(s, i)
        if b >= BYTE_A and b <= BYTE_Z then return false end
    end
    return true
end

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

--- DP scorer. Caller must have already filled _NB[1..n], _HBL[1..m], _HB[1..m]
--- and confirmed has_match. Returns the numeric score only.
local function score_dp(n, m)
    local stride = m + 1
    local needed = (n + 1) * stride

    if needed > _D_size then
        for k = _D_size + 1, needed do
            _D[k] = SCORE_MIN
            _Match[k] = SCORE_MIN
        end
        _D_size = needed
    end

    -- D[0][0] = 0; D[0][j] = 0 for j = 1..m
    _D[1] = 0
    for j = 1, m do
        _D[j + 1] = 0
    end

    for i = 1, n do
        local prev_score = SCORE_MIN
        local gap_score = i == n and SCORE_GAP_TRAILING or SCORE_GAP_INNER
        local nc = _NB[i]
        local row_base = i * stride

        for j = i, m do
            local hc = _HBL[j]
            local idx = row_base + j + 1

            if nc == hc then
                local bonus = compute_bonus(_HB, j)

                local prev_row_prev_col = (i - 1) * stride + j
                local score1 = _D[prev_row_prev_col] + bonus
                local score2 = _Match[prev_row_prev_col] + SCORE_MATCH_CONSECUTIVE

                local match_score = math_max(score1, score2)
                _Match[idx] = match_score

                _D[idx] = math_max(prev_score + gap_score, match_score)
            else
                _Match[idx] = SCORE_MIN
                _D[idx] = prev_score + gap_score
            end

            prev_score = _D[idx]
        end
    end

    return _D[n * stride + m + 1]
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
        if string_lower(needle) == string_lower(haystack) then
            return SCORE_MAX, nil
        end
    end

    if n > m then
        return SCORE_MIN, nil
    end

    local needle_lower = is_already_lower(needle) and needle or string_lower(needle)
    local haystack_lower = is_already_lower(haystack) and haystack or string_lower(haystack)

    if not has_match_str(needle_lower, haystack_lower) then
        return SCORE_MIN, nil
    end

    fill_bytes(_NB, needle_lower, n)
    fill_bytes(_HBL, haystack_lower, m)
    fill_bytes(_HB, haystack, m)

    return score_dp(n, m), nil
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
    local nlow = is_already_lower(needle) and needle or string_lower(needle)
    local hlow = is_already_lower(haystack) and haystack or string_lower(haystack)
    local positions = {}
    local hi = 1
    local nlen = #nlow
    for ni = 1, nlen do
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

--- Sort a list of items by fuzzy match score against a pattern
---@param pattern string the search pattern
---@param items table list of items to sort
---@param limit number|nil maximum number of results to return
---@param text_fn? fun(item: any): string text extractor for non-string items
---@return table sorted list of {item, score} pairs
function M.filter(pattern, items, limit, text_fn)
    text_fn = text_fn or function(item)
        if type(item) == "string" then return item end
        return tostring(item or "")
    end

    if not pattern or pattern == "" then
        local results = {}
        local max = limit or #items
        local item_count = #items
        for i = 1, math_min(max, item_count) do
            results[i] = { item = items[i], score = 0, text = text_fn(items[i]) }
        end
        return results
    end

    -- Hoist needle preparation out of the per-item loop. Filter is called on
    -- every keystroke; doing this work N times per call adds up at 10k items.
    local n = #pattern
    local needle_lower = is_already_lower(pattern) and pattern or string_lower(pattern)
    local needle_lower_eq = needle_lower  -- for == m exact-match fast path

    -- Fill the shared needle byte buffer once per filter call.
    fill_bytes(_NB, needle_lower, n)

    local scored = {}
    local scored_count = 0

    for i = 1, #items do
        local item = items[i]
        local text = text_fn(item)
        if type(text) ~= "string" then text = tostring(text or "") end

        local m = #text
        local score
        if n == 0 then
            score = SCORE_MIN
        elseif n > m then
            score = SCORE_MIN
        else
            local haystack_lower = is_already_lower(text) and text or string_lower(text)
            -- Cheap reject: subsequence test on strings, no array fills.
            if not has_match_str(needle_lower, haystack_lower) then
                score = SCORE_MIN
            elseif n == m and needle_lower_eq == haystack_lower then
                score = SCORE_MAX
            else
                fill_bytes(_HBL, haystack_lower, m)
                fill_bytes(_HB, text, m)
                score = score_dp(n, m)
            end
        end

        if score > SCORE_MIN then
            scored_count = scored_count + 1
            scored[scored_count] = { item = item, score = score, text = text }
        end
    end

    -- Sort by score (descending), then by length (ascending), then alphabetically
    table.sort(scored, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        local len_a, len_b = #a.text, #b.text
        if len_a ~= len_b then
            return len_a < len_b
        end
        return a.text < b.text
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
