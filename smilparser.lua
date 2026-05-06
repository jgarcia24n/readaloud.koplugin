--[[--
Parses EPUB3 SMIL files and builds a global playback timeline.

Each timeline entry:
  { text_id, xhtml_file, audio_file, begin_s, end_s, global_offset_s }

"global_offset_s" is the monotonic position within the concatenated audio
stream that corresponds to the begin of this clip.
@module koplugin.readaloud.smilparser
--]]--

local logger = require("logger")

local SmilParser = {}

-- Pure-Lua SAX-style XML parser (no lxp dependency).
-- Calls handlers.StartElement(_, name, attrs) and handlers.EndElement(_, name).
local function parseXML(xml, handlers)
    local pos = 1
    local len = #xml
    while pos <= len do
        local lt = xml:find("<", pos, true)
        if not lt then break end
        pos = lt + 1
        -- Skip comments
        if xml:sub(pos, pos + 2) == "!--" then
            local e = xml:find("-->", pos + 3, true)
            pos = e and (e + 3) or (len + 1)
        -- Skip CDATA
        elseif xml:sub(pos, pos + 7) == "![CDATA[" then
            local e = xml:find("]]>", pos + 8, true)
            pos = e and (e + 3) or (len + 1)
        -- Skip processing instructions and DOCTYPE
        elseif xml:sub(pos, pos) == "?" or xml:sub(pos, pos + 1) == "!D" then
            local e = xml:find(">", pos, true)
            pos = e and (e + 1) or (len + 1)
        -- Closing tag
        elseif xml:sub(pos, pos) == "/" then
            local e = xml:find(">", pos + 1, true)
            if e then
                local raw = xml:sub(pos + 1, e - 1):match("^%s*(.-)%s*$")
                local name = raw:match("[^:]+$") or raw  -- strip namespace prefix
                if handlers.EndElement then handlers.EndElement(nil, name) end
                pos = e + 1
            else
                pos = len + 1
            end
        else
            -- Opening or self-closing tag
            -- Find end of tag, skipping quoted attribute values
            local scan = pos
            while scan <= len do
                local c = xml:sub(scan, scan)
                if c == ">" then break end
                if c == '"' then
                    scan = (xml:find('"', scan + 1, true) or len) + 1
                elseif c == "'" then
                    scan = (xml:find("'", scan + 1, true) or len) + 1
                else
                    scan = scan + 1
                end
            end
            local tag_content = xml:sub(pos, scan - 1)
            local self_close = tag_content:sub(-1) == "/"
            if self_close then tag_content = tag_content:sub(1, -2) end
            -- Extract tag name (first token)
            local raw_name = tag_content:match("^([^%s/>]+)")
            if raw_name then
                local name = raw_name:match("[^:]+$") or raw_name
                -- Parse attributes
                local attrs = {}
                local attr_str = tag_content:sub(#raw_name + 1)
                for raw_key, _, val in attr_str:gmatch('%s+([^%s=]+)%s*=%s*(["\'])(.-)%2') do
                    local key = raw_key:match("[^:]+$") or raw_key
                    attrs[key] = val
                end
                if handlers.StartElement then handlers.StartElement(nil, name, attrs) end
                if self_close and handlers.EndElement then handlers.EndElement(nil, name) end
            end
            pos = scan + 1
        end
    end
end

-- ── helpers ───────────────────────────────────────────────────────────────────

local function localname(s)
    return s:match("[^}]+$") or s
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function dirOf(path)
    return path:match("^(.*/)") or ""
end

-- Parse EPUB Media Overlay clock value to seconds (float).
-- Handles: H:MM:SS.mmm  MM:SS.mmm  SS.mmm  Xh Xmin Xs Xms
local function parseTime(s)
    if not s or s == "" then return 0 end
    -- H+:MM:SS.mmm
    local h, m, sec = s:match("^(%d+):(%d+):(%d+%.?%d*)$")
    if h then
        return tonumber(h)*3600 + tonumber(m)*60 + tonumber(sec)
    end
    -- MM:SS.mmm
    local m2, s2 = s:match("^(%d+):(%d+%.?%d*)$")
    if m2 then
        return tonumber(m2)*60 + tonumber(s2)
    end
    -- Plain seconds or metric (Xh / Xmin / Xs / Xms)
    local v, unit = s:match("^(%d+%.?%d*)(%a*)$")
    if v then
        local n = tonumber(v) or 0
        if     unit == "h"   then return n * 3600
        elseif unit == "min" then return n * 60
        elseif unit == "ms"  then return n / 1000
        else                       return n
        end
    end
    return 0
end

-- ── per-file SMIL parser ──────────────────────────────────────────────────────

-- Returns an ordered list of par entries:
--   { text_id, xhtml_file, audio_file, begin_s, end_s }
-- audio_file and xhtml_file paths are relative to the SMIL directory.
function SmilParser:parseSmilFile(smil_path)
    local xml = readFile(smil_path)
    if not xml then
        logger.err("SmilParser: cannot read", smil_path)
        return {}
    end

    local smil_dir = dirOf(smil_path)
    local entries = {}
    -- State for current <par>
    local cur_text_id, cur_xhtml, cur_audio, cur_begin, cur_end
    local in_par = false

    local function flushPar()
        if cur_audio and cur_text_id then
            table.insert(entries, {
                text_id    = cur_text_id,
                xhtml_file = cur_xhtml and (smil_dir .. cur_xhtml) or nil,
                audio_file = smil_dir .. cur_audio,
                begin_s    = cur_begin or 0,
                end_s      = cur_end   or 0,
            })
        end
        cur_text_id, cur_xhtml, cur_audio, cur_begin, cur_end = nil, nil, nil, nil, nil
        in_par = false
    end

    parseXML(xml, {
        StartElement = function(_, name, attrs)
            local ln = localname(name)
            if ln == "par" then
                in_par = true
            elseif ln == "text" and in_par then
                local src = attrs["src"] or ""
                -- src may be "chapter.xhtml#id" or just "#id"
                local file_part, id_part = src:match("^([^#]*)#(.+)$")
                if id_part then
                    cur_text_id = id_part
                    cur_xhtml   = (file_part ~= "") and file_part or nil
                else
                    cur_text_id = src  -- fallback
                end
            elseif ln == "audio" and in_par then
                local src = attrs["src"] or ""
                -- Strip leading "./" if present
                cur_audio = src:gsub("^%./", "")
                cur_begin = parseTime(attrs["clipBegin"])
                cur_end   = parseTime(attrs["clipEnd"])
            end
        end,
        EndElement = function(_, name)
            if localname(name) == "par" then
                flushPar()
            end
        end,
    })

    return entries
end

-- ── audio duration ────────────────────────────────────────────────────────────

-- Try ffprobe first; fall back to max clipEnd seen in timeline entries.
local function getAudioDuration(audio_path, fallback_s)
    local cmd = string.format(
        'ffprobe -v error -show_entries format=duration'
        .. ' -of default=noprint_wrappers=1:nokey=1 "%s" 2>/dev/null',
        audio_path
    )
    local f = io.popen(cmd)
    if f then
        local result = f:read("*n")
        f:close()
        if result and result > 0 then return result end
    end
    return fallback_s or 0
end

-- ── global timeline builder ───────────────────────────────────────────────────

-- Builds the global timeline from all spine items that have SMIL paths.
-- Returns:
--   timeline  – ordered array of entries with global_offset_s added
--   audio_seq – ordered list of unique audio file paths (playback order)
function SmilParser:buildGlobalTimeline(spine_items)
    -- Pass 1: collect per-SMIL entries and discover unique audio files in order
    local all_entries  = {}     -- flat list, in spine order
    local audio_order  = {}     -- unique audio files, first-seen order
    local audio_seen   = {}
    local max_end      = {}     -- audio_path → max end_s seen (duration fallback)

    for _, spine_item in ipairs(spine_items) do
        if spine_item.smil_path then
            local entries = self:parseSmilFile(spine_item.smil_path)
            for _, e in ipairs(entries) do
                table.insert(all_entries, e)
                local af = e.audio_file
                if not audio_seen[af] then
                    audio_seen[af] = true
                    table.insert(audio_order, af)
                    max_end[af] = 0
                end
                if e.end_s > (max_end[af] or 0) then
                    max_end[af] = e.end_s
                end
            end
        end
    end

    -- Pass 2: get duration of each audio file and compute cumulative offsets
    local audio_duration   = {}   -- audio_path → duration in seconds
    local audio_global_start = {} -- audio_path → global start offset
    local cumulative = 0
    for _, af in ipairs(audio_order) do
        audio_global_start[af] = cumulative
        local dur = getAudioDuration(af, max_end[af])
        audio_duration[af] = dur
        cumulative = cumulative + dur
        logger.dbg("SmilParser: audio", af, "dur=", dur, "global_start=", audio_global_start[af])
    end

    -- Pass 3: annotate each entry with global_offset_s
    local timeline = {}
    for _, e in ipairs(all_entries) do
        local gs = (audio_global_start[e.audio_file] or 0) + e.begin_s
        table.insert(timeline, {
            text_id        = e.text_id,
            xhtml_file     = e.xhtml_file,
            audio_file     = e.audio_file,
            begin_s        = e.begin_s,
            end_s          = e.end_s,
            global_offset_s = gs,
        })
    end

    return timeline, audio_order, audio_duration, audio_global_start
end

-- Binary-search the timeline for the entry active at global_pos_s.
-- Returns the index of the active entry, or nil.
function SmilParser:findActiveEntry(timeline, global_pos_s)
    if not timeline or #timeline == 0 then return nil end

    -- The entry is the last one whose global_offset_s <= global_pos_s
    -- and whose (global_offset_s + (end_s - begin_s)) > global_pos_s
    local lo, hi = 1, #timeline
    local result = nil

    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if timeline[mid].global_offset_s <= global_pos_s then
            result = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end

    return result
end

-- Expose time parser for use in tests
SmilParser.parseTime = parseTime
-- Expose XML parser for use by other modules (e.g. main.lua XHTML path walking)
SmilParser.parseXML = parseXML

return SmilParser
