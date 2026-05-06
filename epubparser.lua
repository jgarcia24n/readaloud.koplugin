--[[--
Parses EPUB3 container.xml and OPF to build a spine list with media-overlay paths.
Returns nil when the document has no media overlays.
@module koplugin.readaloud.epubparser
--]]--

local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local DataStorage = require("datastorage")

local EpubParser = {}

-- ── helpers ──────────────────────────────────────────────────────────────────

local function localname(s)
    -- Strip XML namespace prefix: "ns:localname" or "uri}localname" → "localname"
    return s:match(":([^:]+)$") or s:match("[^}]+$") or s
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

local function mkdirp(path)
    -- Create directory and all parents
    local parts = {}
    local abs = path:sub(1,1) == "/"
    for part in path:gmatch("[^/]+") do
        table.insert(parts, part)
    end
    local cur = abs and "/" or ""
    for _, p in ipairs(parts) do
        cur = cur .. p .. "/"
        if lfs.attributes(cur, "mode") ~= "directory" then
            lfs.mkdir(cur)
        end
    end
end

local function parseXML(xml_str, handlers)
    local parser = {}
    local pos = 1
    local len = #xml_str

    local function stripNs(name)
        return name:match(":([^:]+)$") or name
    end

    -- Find the closing > of a tag, skipping over quoted attribute values.
    local function findTagClose(start)
        local i = start
        local in_quote
        while i <= len do
            local ch = xml_str:sub(i, i)
            if in_quote then
                if ch == in_quote then in_quote = nil end
            elseif ch == '"' or ch == "'" then
                in_quote = ch
            elseif ch == ">" then
                return i
            end
            i = i + 1
        end
    end

    while pos <= len do
        local lt = xml_str:find("<", pos, true)
        if not lt then break end

        local c2 = xml_str:sub(lt + 1, lt + 3)

        if c2 == "!--" then
            local e = xml_str:find("-->", lt + 4, true)
            pos = e and e + 3 or len + 1
        elseif c2:sub(1, 8) == "![CDATA[" or xml_str:sub(lt + 1, lt + 8) == "![CDATA[" then
            local e = xml_str:find("]]>", lt + 9, true)
            pos = e and e + 3 or len + 1
        elseif c2:sub(1, 1) == "?" or c2:sub(1, 1) == "!" then
            local e = xml_str:find(">", lt + 2, true)
            pos = e and e + 1 or len + 1
        elseif c2:sub(1, 1) == "/" then
            local e = xml_str:find(">", lt + 2, true)
            if not e then break end
            local name = xml_str:sub(lt + 2, e - 1):match("^%s*([^%s>]+)")
            if name and handlers.EndElement then
                handlers.EndElement(parser, stripNs(name))
            end
            pos = e + 1
        else
            local gt = findTagClose(lt + 1)
            if not gt then break end
            local self_closing = xml_str:sub(gt - 1, gt - 1) == "/"
            local inner = xml_str:sub(lt + 1, self_closing and gt - 2 or gt - 1)
            local name = inner:match("^([^%s/>]+)")
            if name then
                local ln = stripNs(name)
                local attrs = {}
                local rest = inner:sub(#name + 1)
                for k, v in rest:gmatch('%s+([%w:%-_.]+)%s*=%s*"([^"]*)"') do
                    attrs[stripNs(k)] = v
                end
                for k, v in rest:gmatch("%s+([%w:%-_.]+)%s*=%s*'([^']*)'") do
                    local ak = stripNs(k)
                    if attrs[ak] == nil then attrs[ak] = v end
                end
                if handlers.StartElement then
                    handlers.StartElement(parser, ln, attrs)
                end
                if self_closing and handlers.EndElement then
                    handlers.EndElement(parser, ln)
                end
            end
            pos = gt + 1
        end
    end
end

-- ── epub extraction ───────────────────────────────────────────────────────────

-- Returns the extraction directory (with trailing slash), or nil on failure.
-- Re-extracts if container.xml exists but the OPF is absent (stale/partial cache).
function EpubParser:extractEpub(epub_path)
    local cache_base = DataStorage:getDataDir() .. "/cache/readaloud/"
    -- Safe directory name derived from the epub path
    local safe = epub_path:gsub("[^%w%-_]", "_"):sub(-100)
    local extract_dir = cache_base .. safe .. "/"

    local marker = extract_dir .. "META-INF/container.xml"
    if lfs.attributes(marker, "mode") == "file" then
        -- Validate the cache isn't a partial extraction by checking that at
        -- least the OPF is also present.
        local opf_rel = self:findOpfPath(extract_dir)
        if opf_rel and lfs.attributes(extract_dir .. opf_rel, "mode") == "file" then
            return extract_dir
        end
        logger.warn("EpubParser: stale/partial cache detected, re-extracting:", epub_path)
    end

    mkdirp(extract_dir)

    -- Use system unzip (available on all KOReader target platforms).
    -- unzip exit codes: 0 = no errors, 1 = warnings but extracted OK, 2+ = fatal.
    -- We accept exit 1 and instead rely on the container.xml presence check below.
    local cmd = string.format('unzip -o "%s" -d "%s" > /dev/null 2>&1', epub_path, extract_dir)
    local exit_code = os.execute(cmd)
    logger.dbg("EpubParser: unzip exit code:", exit_code, "for", epub_path)

    if lfs.attributes(marker, "mode") ~= "file" then
        logger.err("EpubParser: extraction produced no container.xml (exit:", exit_code, ")")
        return nil
    end

    return extract_dir
end

-- ── container.xml ────────────────────────────────────────────────────────────

function EpubParser:findOpfPath(extract_dir)
    local xml = readFile(extract_dir .. "META-INF/container.xml")
    if not xml then return nil end

    local opf_path
    parseXML(xml, {
        StartElement = function(_, name, attrs)
            if localname(name) == "rootfile" and not opf_path then
                opf_path = attrs["full-path"]
            end
        end,
    })
    return opf_path
end

-- ── OPF parser ────────────────────────────────────────────────────────────────

function EpubParser:parseOpf(extract_dir, opf_rel)
    local opf_abs = extract_dir .. opf_rel
    local xml = readFile(opf_abs)
    if not xml then
        logger.err("EpubParser: cannot read OPF:", opf_abs)
        return nil
    end

    local opf_dir = extract_dir .. dirOf(opf_rel)

    -- manifest: id → { href, media_type, media_overlay }
    local manifest = {}
    -- spine: ordered list of manifest IDs (linear items only)
    local spine_idrefs = {}
    local in_manifest, in_spine = false, false

    parseXML(xml, {
        StartElement = function(_, name, attrs)
            local ln = localname(name)
            if ln == "manifest" then
                in_manifest, in_spine = true, false
            elseif ln == "spine" then
                in_spine, in_manifest = true, false
            elseif ln == "item" and in_manifest then
                local id = attrs["id"]
                if id then
                    manifest[id] = {
                        href          = attrs["href"],
                        media_type    = attrs["media-type"],
                        media_overlay = attrs["media-overlay"],
                    }
                end
            elseif ln == "itemref" and in_spine then
                local idref = attrs["idref"]
                -- Include ALL spine items so that _spine_items[N] aligns with CRe's
                -- DocFragment[N] numbering, which counts non-linear items (covers, etc.).
                -- Non-linear items will have no smil_path and are skipped by the timeline
                -- builder; they are kept here solely for index correspondence.
                if idref then
                    table.insert(spine_idrefs, idref)
                end
            end
        end,
        EndElement = function(_, name)
            local ln = localname(name)
            if ln == "manifest" then in_manifest = false end
            if ln == "spine"    then in_spine    = false end
        end,
    })

    -- Build spine_items table
    local spine_items = {}
    for _, idref in ipairs(spine_idrefs) do
        local item = manifest[idref]
        if item and item.href then
            local smil_path
            if item.media_overlay then
                local smil_item = manifest[item.media_overlay]
                if smil_item and smil_item.href then
                    smil_path = opf_dir .. smil_item.href
                end
            end
            table.insert(spine_items, {
                id         = idref,
                xhtml_path = opf_dir .. item.href,
                smil_path  = smil_path,
            })
        end
    end

    return spine_items
end

-- ── public API ────────────────────────────────────────────────────────────────

-- Returns true if any spine item has a media overlay.
function EpubParser:hasMediaOverlays(spine_items)
    for _, item in ipairs(spine_items) do
        if item.smil_path then return true end
    end
    return false
end

-- Main entry point.  Returns a result table or nil when the epub has no overlays.
--   result.extract_dir   absolute path to extracted epub (trailing slash)
--   result.opf_dir       absolute path to directory containing the OPF
--   result.spine_items   array of { id, xhtml_path, smil_path }
function EpubParser:parse(epub_path)
    local extract_dir = self:extractEpub(epub_path)
    if not extract_dir then return nil end

    local opf_rel = self:findOpfPath(extract_dir)
    if not opf_rel then
        logger.err("EpubParser: OPF not found in container.xml")
        return nil
    end

    local spine_items = self:parseOpf(extract_dir, opf_rel)
    if not spine_items then return nil end

    if not self:hasMediaOverlays(spine_items) then
        logger.dbg("EpubParser: no media overlays in this epub")
        return nil
    end

    return {
        extract_dir = extract_dir,
        opf_dir     = extract_dir .. dirOf(opf_rel),
        spine_items = spine_items,
    }
end

return EpubParser
