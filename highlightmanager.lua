--[[--
Applies and removes a transient text highlight for the currently-spoken element.

Strategy (same as audiobook.koplugin):
  1. Look up the element's text in the EPUB XHTML file (cached per file).
  2. Navigate to the element's XPointer so it is on screen.
  3. Build a screen-coordinate line map via CRE's getTextFromPositions().
  4. Binary-search for the element text within the visible line map.
  5. Paint invert-style rectangles via a registered view module so they survive
     page redraws.

@module koplugin.readaloud.highlightmanager
--]]--

local Device     = require("device")
local Event      = require("ui/event")
local UIManager  = require("ui/uimanager")
local logger     = require("logger")

local Screen = Device.screen

local function ws(s)
    if not s then return "" end
    return s:gsub("%s+", " "):match("^%s*(.-)%s*$")
end

-- Normalize typographic punctuation to ASCII equivalents for text matching.
-- Handles both directions: XHTML Unicode → CRe ASCII, and CRe Unicode → XHTML ASCII.
local function normalizeForSearch(s)
    if not s then return "" end
    s = s:gsub("\xE2\x80\x98", "'")  -- U+2018 '  left single quotation mark
    s = s:gsub("\xE2\x80\x99", "'")  -- U+2019 '  right single quotation mark / apostrophe
    s = s:gsub("\xE2\x80\x9C", '"')  -- U+201C "  left double quotation mark
    s = s:gsub("\xE2\x80\x9D", '"')  -- U+201D "  right double quotation mark
    -- Em/en-dashes map to space, not hyphen. CRe handles them inconsistently at
    -- line boundaries: it may keep the dash, insert a space after it, or drop it
    -- entirely. All three produce a space after the preceding word, so mapping to
    -- space makes XHTML probe and CRe built_text agree in every case.
    s = s:gsub("\xE2\x80\x93", " ")  -- U+2013 –  en dash
    s = s:gsub("\xE2\x80\x94", " ")  -- U+2014 —  em dash
    s = s:gsub("\xC2\xA0",     " ")  -- U+00A0    non-breaking space
    -- CRe may insert a space after an ASCII hyphen at a line boundary ("egg- shaped").
    s = s:gsub("%-+%s+", "-")
    return s:gsub("%s+", " "):match("^%s*(.-)%s*$")
end

local HighlightManager = {}
HighlightManager.__index = HighlightManager

function HighlightManager:new(ui, settings)
    local o = setmetatable({}, HighlightManager)
    o.ui                      = ui
    o.settings                = settings
    o.last_text_id            = nil
    o._pending_boxes          = nil
    o._view_module_registered = false
    o._xhtml_cache            = {}
    o._line_cache             = nil
    return o
end

-- ── XHTML element text extraction ─────────────────────────────────────────────

local function extractElementText(xhtml, element_id)
    if not xhtml or not element_id then return nil end

    local eid = element_id:gsub('[%(%)%.%%%+%-%*%?%[%^%$]', '%%%1')
    local id_pat = 'id%s*=%s*["\']' .. eid .. '["\']'
    local id_pos = xhtml:find(id_pat)
    if not id_pos then return nil end

    -- Walk back to the '<' that starts this tag
    local ts = id_pos
    while ts > 1 and xhtml:sub(ts, ts) ~= "<" do ts = ts - 1 end
    if xhtml:sub(ts, ts) ~= "<" then return nil end

    -- Tag name (strip namespace prefix)
    local tag_name = xhtml:sub(ts + 1):match("^[%a%d_%-]+:([%a%d_%-]+)")
                  or xhtml:sub(ts + 1):match("^([%a%d_%-]+)")
    if not tag_name then return nil end
    tag_name = tag_name:lower()

    -- Find end of opening tag, skipping quoted attributes
    local scan = ts + 1
    while scan <= #xhtml do
        local c = xhtml:sub(scan, scan)
        if c == ">" then break end
        if     c == '"' then scan = (xhtml:find('"',  scan + 1, true) or #xhtml) + 1
        elseif c == "'" then scan = (xhtml:find("'",  scan + 1, true) or #xhtml) + 1
        else scan = scan + 1 end
    end
    -- Self-closing?
    if xhtml:sub(scan - 1, scan - 1) == "/" then return "" end

    local depth = 1
    local pos   = scan + 1
    local parts = {}

    while pos <= #xhtml and depth > 0 do
        local lt = xhtml:find("<", pos, true)
        if not lt then
            if depth > 0 then table.insert(parts, xhtml:sub(pos)) end
            break
        end
        if lt > pos then table.insert(parts, xhtml:sub(pos, lt - 1)) end

        local c2 = xhtml:sub(lt + 1, lt + 1)
        if c2 == "/" then
            local ce = xhtml:find(">", lt + 2)
            if ce then
                local cn = xhtml:sub(lt + 2, ce - 1):match("^[%a%d_%-]+:([%a%d_%-]+)")
                        or xhtml:sub(lt + 2, ce - 1):match("^([%a%d_%-]+)")
                if cn and cn:lower() == tag_name then depth = depth - 1 end
                pos = ce + 1
            else break end
        elseif c2 == "!" or c2 == "?" then
            local ce = xhtml:find(">", lt + 2)
            pos = ce and ce + 1 or (#xhtml + 1)
        else
            local ce = xhtml:find(">", lt + 1)
            if ce then
                local inner = xhtml:sub(lt + 1, ce - 1)
                local inn = inner:match("^[%a%d_%-]+:([%a%d_%-]+)")
                         or inner:match("^([%a%d_%-]+)")
                if inn and inn:lower() == tag_name and inner:sub(-1) ~= "/" then
                    depth = depth + 1
                end
                pos = ce + 1
            else break end
        end
    end

    local text = table.concat(parts)
    text = text:gsub("&amp;",  "&")
               :gsub("&lt;",   "<")
               :gsub("&gt;",   ">")
               :gsub("&quot;", '"')
               :gsub("&apos;", "'")
               :gsub("&nbsp;", " ")
               :gsub("&ldquo;", "\xE2\x80\x9C")
               :gsub("&rdquo;", "\xE2\x80\x9D")
               :gsub("&lsquo;", "\xE2\x80\x98")
               :gsub("&rsquo;", "\xE2\x80\x99")
               :gsub("&mdash;", "\xE2\x80\x94")
               :gsub("&ndash;", "\xE2\x80\x93")
               :gsub("&hellip;","\xE2\x80\xA6")
               :gsub("&shy;",   "")
               :gsub("&#[xX](%x+);", function(h)
                   local cp = tonumber(h, 16)
                   if not cp then return "" end
                   local ok, c = pcall(utf8.char, cp)
                   return ok and c or ""
               end)
               :gsub("&#(%d+);", function(n)
                   local cp = tonumber(n)
                   if not cp then return "" end
                   local ok, c = pcall(utf8.char, cp)
                   return ok and c or ""
               end)
    text = ws(text)
    return text ~= "" and text or nil
end

function HighlightManager:_getElementText(xhtml_path, element_id)
    if not xhtml_path or not element_id then return nil end
    if not self._xhtml_cache[xhtml_path] then
        local f = io.open(xhtml_path, "rb")
        if not f then
            logger.warn("HighlightManager: cannot open", xhtml_path)
            return nil
        end
        self._xhtml_cache[xhtml_path] = f:read("*a")
        f:close()
    end
    return extractElementText(self._xhtml_cache[xhtml_path], element_id)
end

-- ── XPointer lookup ───────────────────────────────────────────────────────────

local XPOINTER_METHODS = {
    "getXPointerOfElementById",
    "getXPointerForId",
    "findXPointerById",
}

local function findXPointerForId(document, id)
    for _, fname in ipairs(XPOINTER_METHODS) do
        local method = document[fname]
        if type(method) ~= "function" then
            logger.info("RA_DIAG xptr: " .. fname .. " not available (type=" .. type(method) .. ")")
        else
            local ok, xp = pcall(function()
                return method(document, id)
            end)
            logger.info("RA_DIAG xptr: " .. fname .. "(" .. id:sub(1,40) .. ") ok=" .. tostring(ok) .. " result=" .. tostring(xp and xp:sub(1,60) or (ok and "nil" or xp)))
            if ok and type(xp) == "string" and xp ~= "" then
                return xp
            end
        end
    end
    return nil
end

-- ── navigation ────────────────────────────────────────────────────────────────

local function navigateTo(ui, xp)
    ui:handleEvent(Event:new("GotoXPointer", xp))
end

-- ── view module / overlay painting ───────────────────────────────────────────

function HighlightManager:_ensureViewModule()
    if self._view_module_registered then return end
    if not self.ui or not self.ui.view then return end
    local hm = self
    local mod = { paintTo = function(_, bb) hm:_paintOverlay(bb) end }
    self.ui.view:registerViewModule("readaloud_highlight", mod)
    self._view_module_registered = true
end

function HighlightManager:_paintOverlay(bb)
    local boxes = self._pending_boxes
    if not boxes or #boxes == 0 or not bb then return end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    for _, box in ipairs(boxes) do
        local bx = math.max(0, box.x)
        local by = math.max(0, box.y)
        local bw = math.min(box.w - (bx - box.x), sw - bx)
        local bh = math.min(box.h - (by - box.y), sh - by)
        if bw > 0 and bh > 0 then
            pcall(function() bb:invertRect(bx, by, bw, bh) end)
        end
    end
end

-- ── screen-coordinate sentence highlight (ported from audiobook.koplugin) ────

function HighlightManager:_highlightTextOnScreen(sent_text, doc, _retried)
    logger.info("RA_DIAG screenSearch[" .. (_retried and "retry" or "1st") .. "]: sent=[" .. sent_text:sub(1, 60) .. "]")
    pcall(function() doc:clearSelection() end)

    local cur_w, cur_h = Screen:getWidth(), Screen:getHeight()
    local cache = self._line_cache
    local built_text, cum, sboxes, n

    if cache and cache.screen_w == cur_w and cache.screen_h == cur_h then
        built_text = cache.built_text
        cum        = cache.cum
        sboxes     = cache.sboxes
        n          = cache.n
        logger.info("RA_DIAG screenSearch: using cached built_text len=" .. #built_text .. " first60=[" .. built_text:sub(1,60) .. "]")
    else
        local full_res = doc:getTextFromPositions(
            {x = 0, y = 0}, {x = cur_w, y = cur_h}, true)
        if not full_res or not full_res.pos0 or not full_res.pos1 then
            logger.info("RA_DIAG screenSearch: getTextFromPositions returned nil — no cache built")
            return
        end

        sboxes = doc:getScreenBoxesFromPositions(full_res.pos0, full_res.pos1, true)
        if not sboxes or #sboxes == 0 then
            logger.info("RA_DIAG screenSearch: getScreenBoxesFromPositions returned empty")
            return
        end
        n = #sboxes

        built_text = ""
        cum = {[0] = 0}
        local clipped_lines = 0
        for i = 1, n do
            local box = sboxes[i]
            -- Clamp midpoint to screen bounds: lines at the very bottom of the screen
            -- have their geometric midpoint below cur_h, causing getTextFromPositions
            -- to return empty text and making those lines invisible to the cache.
            local mid_y = box.y + math.floor(box.h / 2)
            if mid_y >= cur_h then
                mid_y = cur_h - 1
                clipped_lines = clipped_lines + 1
            end
            local r = doc:getTextFromPositions(
                {x = box.x,         y = mid_y},
                {x = box.x + box.w - 1, y = mid_y},
                true)
            local lt = (r and r.text) and ws(r.text) or ""
            if i > 1 and lt ~= "" then built_text = built_text .. " " end
            built_text = built_text .. lt
            cum[i] = #built_text
        end

        self._line_cache = {
            screen_w = cur_w, screen_h = cur_h,
            built_text = built_text, cum = cum, sboxes = sboxes, n = n,
        }
        logger.info("RA_DIAG screenSearch: built new cache lines=" .. n .. " clipped=" .. clipped_lines .. " len=" .. #built_text .. " first60=[" .. built_text:sub(1,60) .. "]")
    end

    -- Locate sentence in visible text; try progressively shorter prefix/suffix
    local vis_start, matched_len
    vis_start = built_text:find(sent_text, 1, true)
    if vis_start then
        matched_len = #sent_text
        logger.info("RA_DIAG screenSearch: exact match at pos=" .. vis_start)
    else
        logger.info("RA_DIAG screenSearch: exact match FAILED, trying prefix/suffix fallbacks")
        for _, plen in ipairs({40, 20, 10}) do
            if plen < #sent_text then
                vis_start = built_text:find(sent_text:sub(1, plen), 1, true)
                if vis_start then
                    matched_len = #sent_text
                    logger.info("RA_DIAG screenSearch: prefix[" .. plen .. "] match at pos=" .. vis_start .. " probe=[" .. sent_text:sub(1, plen) .. "]")
                    break
                end
            end
        end
    end
    if not vis_start then
        for _, slen in ipairs({40, 20, 10}) do
            if slen < #sent_text then
                local pos = built_text:find(sent_text:sub(-slen), 1, true)
                if pos then
                    vis_start = pos
                    matched_len = slen
                    logger.info("RA_DIAG screenSearch: suffix[" .. slen .. "] match at pos=" .. pos .. " probe=[" .. sent_text:sub(-slen) .. "]")
                    break
                end
            end
        end
    end
    if not vis_start then
        if not _retried and self._line_cache then
            logger.info("RA_DIAG screenSearch: all direct matches failed, clearing cache and retrying")
            self._line_cache = nil
            return self:_highlightTextOnScreen(sent_text, doc, true)
        end
        -- Normalized fallback: typographic quotes/dashes in XHTML may not match what
        -- CRe returns from getTextFromPositions.  If the normalized text IS found, the
        -- sentence is on screen — return true (no boxes) so the caller skips navigation.
        local norm_sent  = normalizeForSearch(sent_text)
        local norm_built = normalizeForSearch(built_text)
        local nv = norm_built:find(norm_sent, 1, true)
        if not nv then
            for _, plen in ipairs({40, 20, 10}) do
                if plen < #norm_sent then
                    nv = norm_built:find(norm_sent:sub(1, plen), 1, true)
                    if nv then
                        logger.info("RA_DIAG screenSearch: normalized prefix[" .. plen .. "] match at pos=" .. nv)
                        break
                    end
                end
            end
        else
            logger.info("RA_DIAG screenSearch: normalized exact match at pos=" .. nv)
        end
        if nv then
            logger.info("RA_DIAG screenSearch: FOUND via normalized (no boxes) — sentence is on screen")
            return true
        end
        logger.info("RA_DIAG screenSearch: NOT FOUND anywhere. sent=[" .. sent_text:sub(1,80) .. "] built_end=[" .. built_text:sub(-60) .. "]")
        return
    end
    local vis_end = vis_start + matched_len - 1

    -- Map char offsets → line indices
    local start_line = 1
    for i = 1, n do
        if cum[i] >= vis_start then start_line = i; break end
    end
    local end_line = n
    for i = start_line, n do
        if cum[i] >= vis_end then end_line = i; break end
    end

    local sb, eb = sboxes[start_line], sboxes[end_line]
    if not sb or not eb then return end

    local function estimateX(box, line_idx, char_off)
        local total = cum[line_idx] - cum[line_idx - 1]
        if total <= 0 then return box.x end
        local x = box.x + math.floor((char_off / total) * box.w)
        return math.max(box.x, math.min(box.x + box.w - 1, x))
    end

    local function querySelection(sx, sy, ex, ey)
        local r = doc:getTextFromPositions({x=sx,y=sy},{x=ex,y=ey},true)
        return r and r.text and ws(r.text) or ""
    end

    local start_y = sb.y + math.floor(sb.h / 2)
    local end_y   = eb.y + math.floor(eb.h / 2)
    local sl_off  = vis_start - cum[start_line - 1]
    local el_off  = vis_end   - cum[end_line   - 1]
    local start_x = estimateX(sb, start_line, math.max(0, sl_off - 1))
    local end_x   = estimateX(eb, end_line,   el_off)

    -- Binary-search refinement of end_x
    local function refineEndX(cur_sx, cur_sy, cur_ey)
        local got = querySelection(cur_sx, cur_sy, end_x, cur_ey)
        if got == sent_text then return end_x end
        local lo, hi
        if #got > #sent_text then hi = end_x; lo = eb.x
        else                       lo = end_x; hi = eb.x + eb.w - 1 end
        local best_x   = end_x
        local best_diff = math.abs(#got - #sent_text)
        for _ = 1, 6 do
            if hi - lo < 2 then break end
            local mid = math.floor((lo + hi) / 2)
            local mt  = querySelection(cur_sx, cur_sy, mid, cur_ey)
            if mt == sent_text then return mid end
            local diff = math.abs(#mt - #sent_text)
            if #mt > #sent_text then hi = mid else lo = mid end
            if diff < best_diff or (diff == best_diff and #mt <= #sent_text) then
                best_diff = diff; best_x = mid
            end
        end
        return best_x
    end
    end_x = refineEndX(start_x, start_y, end_y)

    -- Refine start_x if sentence begins mid-line
    if sl_off > 1 then
        local got = querySelection(start_x, start_y, end_x, end_y)
        if got ~= sent_text then
            local want_start = sent_text:sub(1, math.min(20, #sent_text))
            if got:sub(1, #want_start) ~= want_start then
                local lo = sb.x
                local hi = math.min(start_x + math.floor(sb.w * 0.3), sb.x + sb.w - 1)
                local best_x = start_x
                for _ = 1, 6 do
                    if hi - lo < 2 then break end
                    local mid = math.floor((lo + hi) / 2)
                    local mt  = querySelection(mid, start_y, end_x, end_y)
                    if mt:sub(1, #want_start) == want_start then
                        best_x = mid; hi = mid
                    else lo = mid end
                end
                start_x = best_x
                end_x   = refineEndX(start_x, start_y, end_y)
            end
        end
    end

    -- Build highlight boxes (prefer CRe-accurate boxes, fall back to line-map estimate)
    local boxes
    local final_res = doc:getTextFromPositions(
        {x=start_x,y=start_y},{x=end_x,y=end_y},true)
    if final_res and final_res.pos0 and final_res.pos1 then
        local cre_text = final_res.text and ws(final_res.text) or ""
        if #cre_text <= #sent_text + 3 then
            local cre_boxes = doc:getScreenBoxesFromPositions(
                final_res.pos0, final_res.pos1, true)
            if cre_boxes and #cre_boxes > 0 then
                boxes = {}
                for _, cb in ipairs(cre_boxes) do
                    if cb.w > 0 and cb.h > 0 then
                        table.insert(boxes, {x=cb.x,y=cb.y,w=cb.w,h=cb.h})
                    end
                end
                if #boxes == 0 then boxes = nil end
            end
        end
    end
    if not boxes then
        boxes = {}
        for i = start_line, end_line do
            local box = sboxes[i]
            local bx, bw = box.x, box.w
            if i == start_line and i == end_line then
                bx = start_x; bw = end_x - start_x
            elseif i == start_line then
                bx = start_x; bw = (box.x + box.w) - start_x
            elseif i == end_line then
                bw = end_x - box.x
            end
            if bw > 0 and box.h > 0 then
                table.insert(boxes, {x=bx, y=box.y, w=bw, h=box.h})
            end
        end
    end

    if #boxes > 0 then
        self._pending_boxes = boxes
        self:_ensureViewModule()
        UIManager:setDirty(self.ui.dialog or "all", "ui")
        return true
    end
end

-- ── public API ────────────────────────────────────────────────────────────────

-- Highlight the element identified by text_id.
-- entry is the full SMIL timeline entry (fields: text_id, xhtml_file, …).
-- opts.no_navigate = true suppresses the navigation fallback (used by the
-- overflow re-highlight callback, which must not trigger a second page turn).
function HighlightManager:highlight(text_id, entry, opts)
    if text_id == self.last_text_id then return end
    self:clear()

    local document = self.ui and self.ui.document
    if not document then
        logger.warn("HighlightManager: no document")
        return
    end

    self.last_text_id = text_id

    -- Get element text from XHTML (needed to locate it on screen)
    local xhtml_file = entry and entry.xhtml_file
    local sent_text  = self:_getElementText(xhtml_file, text_id)
    if not sent_text or sent_text == "" then
        logger.info("RA_DIAG highlight: no XHTML text for text_id=" .. tostring(text_id))
        return
    end

    logger.info("RA_DIAG highlight: text_id=" .. tostring(text_id) .. " no_navigate=" .. tostring(opts and opts.no_navigate or false) .. " cache=" .. (self._line_cache and "yes" or "nil"))
    logger.info("RA_DIAG highlight: xhtml_text=[" .. sent_text:sub(1, 80) .. "]")

    -- Screen-coordinate highlight (rolling/EPUB only).
    -- Try highlighting on the CURRENT page first.  Only navigate when the
    -- sentence is not visible — this lets the user browse freely while audio
    -- plays; the page advances only when the audio has moved past what is
    -- on screen, matching the audiobook plugin's per-page-exhaustion model.
    if self.ui.rolling and document.getTextFromPositions then
        local found = self:_highlightTextOnScreen(sent_text, document)
        logger.info("RA_DIAG highlight: _highlightTextOnScreen returned " .. tostring(found))
        if not found then
            local no_navigate = opts and opts.no_navigate
            -- readSetting with default=true: isTrue() has no default in KOReader's native
            -- LuaSettings, so auto_page_turn would always be false on first run.
            local auto_turn = (not no_navigate)
                and (not self.settings
                    or self.settings:readSetting("auto_page_turn", true) ~= false)
            if auto_turn then
                -- Before navigating, check whether the sentence is on screen via
                -- normalized text search.  Typographic quotes in the XHTML may not
                -- match CRe's rendered ASCII, causing _highlightTextOnScreen to fail
                -- even when the sentence IS visible.  Navigating in that case turns
                -- the page away from the correct content and starts a cascade.
                local cache = self._line_cache
                local norm_probe = normalizeForSearch(sent_text):sub(1, 30)
                logger.info("RA_DIAG highlight: nav-guard cache=" .. (cache and "yes len=" .. #(cache.built_text or "") or "nil") .. " norm_probe=[" .. norm_probe .. "]")
                if cache and cache.built_text then
                    local found_in_norm = normalizeForSearch(cache.built_text):find(norm_probe, 1, true)
                    logger.info("RA_DIAG highlight: norm probe in built_text=" .. tostring(found_in_norm ~= nil))
                    if norm_probe ~= "" and found_in_norm then
                        logger.info("RA_DIAG highlight: GUARD TRIGGERED — skipping navigation, sentence is on screen")
                        return  -- sentence is on screen; skip navigation
                    end
                end
                local xp = findXPointerForId(document, text_id)
                logger.info("RA_DIAG highlight: NAVIGATING — xp=" .. tostring(xp and xp:sub(1,80)))
                if xp then
                    navigateTo(self.ui, xp)
                else
                    logger.info("RA_DIAG highlight: no XPointer found, using GotoViewRel +1")
                    self.ui:handleEvent(Event:new("GotoViewRel", 1))
                end
                self._line_cache = nil
                -- Wait for page render before retrying (mirrors audiobook.koplugin's 0.15 s delay).
                local tid = text_id
                UIManager:scheduleIn(0.15, function()
                    if self.last_text_id ~= tid then return end
                    logger.info("RA_DIAG highlight: 0.15s retry for text_id=" .. tostring(tid))
                    self:_highlightTextOnScreen(sent_text, document)
                end)
            else
                logger.info("RA_DIAG highlight: auto_turn disabled or no_navigate, skipping navigation")
            end
        end
    end
end

-- Remove the current highlight.
function HighlightManager:clear()
    if not self.last_text_id then return end
    self._pending_boxes = nil
    if self.ui then
        UIManager:setDirty(self.ui.dialog or "all", "ui")
    end
    self.last_text_id = nil
end

function HighlightManager:reset()
    self:clear()
    self._xhtml_cache = {}
    self._line_cache  = nil
    self.ui           = nil
end

function HighlightManager:clearLineCache()
    self._line_cache = nil
end

-- Returns true if next entry's text appears in the current page's cached text,
-- false if it definitely isn't there, nil if the cache isn't built yet.
function HighlightManager:isNextTextVisible(xhtml_file, text_id)
    local cache = self._line_cache
    if not cache or not cache.built_text then
        logger.info("RA_DIAG isNextTextVisible: text_id=" .. tostring(text_id) .. " → nil (no cache)")
        return nil
    end
    local text = self:_getElementText(xhtml_file, text_id)
    if not text or text == "" then
        logger.info("RA_DIAG isNextTextVisible: text_id=" .. tostring(text_id) .. " → nil (no xhtml text)")
        return nil
    end
    local probe = text:sub(1, math.min(30, #text))
    if cache.built_text:find(probe, 1, true) then
        logger.info("RA_DIAG isNextTextVisible: text_id=" .. tostring(text_id) .. " → true (exact probe found) probe=[" .. probe .. "]")
        return true
    end
    -- Normalized fallback: normalize first then truncate so we never cut mid-multibyte,
    -- and so the dash+whitespace line-break rule fires on the full string.
    local norm_probe = normalizeForSearch(text):sub(1, 30)
    if norm_probe == "" then
        logger.info("RA_DIAG isNextTextVisible: text_id=" .. tostring(text_id) .. " → false (empty norm_probe)")
        return false
    end
    local norm_result = normalizeForSearch(cache.built_text):find(norm_probe, 1, true) ~= nil
    logger.info("RA_DIAG isNextTextVisible: text_id=" .. tostring(text_id) .. " → " .. tostring(norm_result) .. " (normalized) probe=[" .. probe .. "] norm_probe=[" .. norm_probe .. "]")
    return norm_result
end

-- Returns estimated fraction (0.0–1.0) of the element's text visible on the
-- current page.  Returns 1.0 when the cache is absent or the element is short.
-- Checks tail (sentence fits) then head (sentence starts here).  If head is
-- not found the element is entirely off-screen (wrong page) → return 1.0 so
-- callers don't fire a false overflow page turn.  Callers should only act on
-- values < 0.8 to avoid false positives from normalisation noise.
function HighlightManager:getVisibleTextFraction(xhtml_file, text_id)
    local cache = self._line_cache
    if not cache or not cache.built_text then return 1.0 end
    local text = self:_getElementText(xhtml_file, text_id)
    if not text or #text < 40 then return 1.0 end
    -- Tail present → sentence fits entirely on this page
    local tail = text:sub(math.max(1, #text - 29))
    if cache.built_text:find(tail, 1, true) then return 1.0 end
    -- Head absent → sentence doesn't start here; we're on the wrong page.
    -- Try 30-char probe first; if it fails, try a 10-char probe anchored to the
    -- tail of built_text — catches extreme overflow where only a word or two of
    -- the sentence is visible at the very bottom of the screen.
    local head = text:sub(1, math.min(30, #text))
    if not cache.built_text:find(head, 1, true) then
        local head10 = text:sub(1, math.min(10, #text))
        local match_pos = #head10 >= 6 and cache.built_text:find(head10, 1, true)
        if match_pos and match_pos > #cache.built_text - 50 then
            return 0.05  -- only sentence start visible → schedule near-immediate turn
        end
        return 1.0
    end
    -- Head visible, tail not → sentence overflows; probe for visible fraction
    for _, frac in ipairs({ 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3 }) do
        local pos   = math.floor(frac * #text)
        local probe = text:sub(pos, pos + 29)
        if #probe >= 10 and cache.built_text:find(probe, 1, true) then
            return frac
        end
    end
    return 0.2  -- head visible but interior probes all miss → extreme overflow
end

return HighlightManager
