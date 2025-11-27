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

local function is_lower(c)
    return c:match("%l")
end

local function is_upper(c)
    return c:match("%u")
end

--- Compute match bonus based on character position context
---@param haystack string
---@param i number position in haystack (1-indexed)
---@return number bonus score
local function compute_bonus(haystack, i)
    if i == 1 then
        return SCORE_MATCH_SLASH -- Beginning of string is like after a slash
    end

    local prev = haystack:sub(i - 1, i - 1)
    local curr = haystack:sub(i, i)

    if prev == "/" or prev == "\\" then
        return SCORE_MATCH_SLASH
    elseif prev == "_" or prev == "-" or prev == " " then
        return SCORE_MATCH_WORD
    elseif prev == "." then
        return SCORE_MATCH_DOT
    elseif is_lower(prev) and is_upper(curr) then
        return SCORE_MATCH_CAPITAL
    end

    return 0
end

--- Check if needle matches haystack (case-insensitive)
---@param needle string the search pattern
---@param haystack string the string to search in
---@return boolean matches
local function has_match(needle, haystack)
    local needle_lower = needle:lower()
    local haystack_lower = haystack:lower()

    local j = 1
    for i = 1, #haystack_lower do
        if haystack_lower:sub(i, i) == needle_lower:sub(j, j) then
            j = j + 1
            if j > #needle_lower then
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
        if needle:lower() == haystack:lower() then
            return SCORE_MAX, nil
        end
    end

    if n > m then
        return SCORE_MIN, nil
    end

    local needle_lower = needle:lower()
    local haystack_lower = haystack:lower()

    -- Quick check: does needle match at all?
    if not has_match(needle, haystack) then
        return SCORE_MIN, nil
    end

    -- Dynamic programming approach
    -- D[i][j] = best score for matching needle[1..i] to haystack[1..j]
    -- M[i][j] = best score ending with a match at position j

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

        for j = i, m do
            local nc = needle_lower:sub(i, i)
            local hc = haystack_lower:sub(j, j)

            if nc == hc then
                local bonus = compute_bonus(haystack, j)

                -- Score for starting a new match sequence
                local score1 = D[i - 1][j - 1] + bonus

                -- Score for continuing a match sequence
                local score2 = Match[i - 1][j - 1] + SCORE_MATCH_CONSECUTIVE

                local match_score = math.max(score1, score2)
                Match[i][j] = match_score

                -- Best score so far
                D[i][j] = math.max(prev_score + gap_score, match_score)
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
        for i = 1, math.min(max, #items) do
            results[i] = { item = items[i], score = 0 }
        end
        return results
    end

    local scored = {}
    for _, item in ipairs(items) do
        local score = M.score(pattern, item)
        if score > SCORE_MIN then
            scored[#scored + 1] = { item = item, score = score }
        end
    end

    -- Sort by score (descending), then by length (ascending), then alphabetically
    table.sort(scored, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        if #a.item ~= #b.item then
            return #a.item < #b.item
        end
        return a.item < b.item
    end)

    if limit and #scored > limit then
        local limited = {}
        for i = 1, limit do
            limited[i] = scored[i]
        end
        return limited
    end

    return scored
end

return M
