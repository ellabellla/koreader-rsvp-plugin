--[[--
FastReader plugin for KOReader

@module koplugin.FastReader
--]]--

-- This is a debug plugin, remove the following if block to enable it
-- if true then
--     return { disabled = true, }
-- end

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local TextWidget = require("ui/widget/textwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Screen = Device.screen
local ok_input, InputContainer = pcall(require, "ui/widget/container/inputcontainer")
if not ok_input then
    InputContainer = require("ui/widget/inputcontainer")
end
local GestureRange = require("ui/gesturerange")
local logger = require("logger")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local FastReader = WidgetContainer:extend{
    name = "fastreader",
    is_doc_only = true,
}

local function charSet(list)
    local set = {}
    for _, ch in ipairs(list) do
        set[ch] = true
    end
    return set
end

-- Non-ASCII punctuation; ASCII punctuation is matched with %p
local UNICODE_PUNCTUATION = charSet{
    "…", "—", "–", "“", "”", "‘", "’", "«", "»",
    "。", "！", "？", "，", "；", "：", "、",
}
-- A word ending in one of these is held longer
local PAUSE_CHARS = charSet{
    ".", "!", "?", "…", ",", ";", ":", "—", "–", "-",
    "。", "！", "？", "，", "；", "：", "、",
}
-- Skipped when looking for a word's final punctuation, so `end."` pauses
local CLOSING_CHARS = charSet{ '"', "'", ")", "]", "”", "’", "»" }
-- Standalone tokens made only of these are attached to a neighbouring word
local GROUPED_CHARS = charSet{ ".", "…", "-", "–", "—" }

local function isPunctuationChar(ch)
    return UNICODE_PUNCTUATION[ch] or (#ch == 1 and ch:match("^%p$") ~= nil)
end

-- Remove leading/trailing punctuation from a word
local function stripPunctuation(word)
    local chars = util.splitToChars(word)
    local first, last = 1, #chars
    while first <= last and isPunctuationChar(chars[first]) do
        first = first + 1
    end
    while last >= first and isPunctuationChar(chars[last]) do
        last = last - 1
    end
    return table.concat(chars, "", first, last)
end

local function isGroupedToken(token)
    for _, ch in ipairs(util.splitToChars(token)) do
        if not GROUPED_CHARS[ch] then
            return false
        end
    end
    return true
end

-- Whether a word ends in punctuation that should hold it on screen longer
local function endsWithPausePunctuation(word)
    if not word or word == "" then
        return false
    end
    local chars = util.splitToChars(word)
    local i = #chars
    while i > 0 and CLOSING_CHARS[chars[i]] do
        i = i - 1
    end
    return i > 0 and PAUSE_CHARS[chars[i]] == true
end

-- Number of letters in text, ignoring punctuation, whitespace and soft hyphens.
-- Used to line our words up with the document's own words, which may be split differently.
local function countLetters(text)
    local n = 0
    for _, ch in ipairs(util.splitToChars(text or "")) do
        if not isPunctuationChar(ch) and not ch:match("^%s$") and ch ~= "\194\173" then
            n = n + 1
        end
    end
    return n
end

-- Split text into words, keeping their punctuation. Standalone ellipses and
-- dashes ("wait . . ." / "said —") are attached to the previous word; other
-- punctuation-only tokens are dropped. Shared by page extraction and
-- tap-position lookup so word indices agree.
local function splitWords(text)
    local words = {}
    if type(text) ~= "string" then
        return words
    end
    -- Soft hyphens (U+00AD) are invisible break hints from the book's text
    text = text:gsub("\194\173", "")
    local pending_prefix = ""
    for token in text:gmatch("%S+") do
        if stripPunctuation(token) ~= "" then
            table.insert(words, pending_prefix .. token)
            pending_prefix = ""
        elseif isGroupedToken(token) then
            if #words > 0 then
                words[#words] = words[#words] .. token
            else
                pending_prefix = pending_prefix .. token
            end
        end
    end
    return words
end

-- Flatten a getPageText() result (table of lines of word boxes) into a string
local function flattenPageText(page_text)
    if type(page_text) == "string" then
        return page_text
    end
    if type(page_text) ~= "table" then
        return ""
    end
    local parts = {}
    for _, line in ipairs(page_text) do
        if type(line) == "table" then
            for _, box in ipairs(line) do
                if type(box) == "table" and box.word then
                    table.insert(parts, box.word)
                end
            end
        end
    end
    return table.concat(parts, " ")
end

function FastReader:onDispatcherRegisterActions()
    Dispatcher:registerAction("fastreader_action", {category="none", event="FastReader", title=_("Fast Reader"), general=true,})
    Dispatcher:registerAction("fastreader_rsvp", {category="none", event="FastReaderRSVP", title=_("RSVP Reading"), general=true,})
end

function FastReader:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    
    -- Load settings
    self.settings_file = DataStorage:getSettingsDir() .. "/fastreader.lua"
    self.settings = LuaSettings:open(self.settings_file)
    
    -- RSVP state
    self.rsvp_enabled = false
    self.rsvp_paused = false
    self.rsvp_timer = nil
    self.pending_resume_task = nil
    self.rsvp_widget = nil
    
    -- Tap-to-launch RSVP settings
    self.tap_to_launch_enabled = self.settings:readSetting("tap_to_launch_enabled") or false
    self.rsvp_speed = self.settings:readSetting("rsvp_speed") or 250  -- words per minute
    self.current_word_index = 1
    self.current_chunk_index = 1
    self.words = {}
    self.original_view_mode = nil
    
    local ovp_setting = self.settings:readSetting("ovp_alignment_enabled")
    if ovp_setting == nil then
        self.ovp_alignment_enabled = true
    else
        self.ovp_alignment_enabled = ovp_setting
    end

    local punctuation_setting = self.settings:readSetting("punctuation_pause_enabled")
    if punctuation_setting == nil then
        self.punctuation_pause_enabled = true
    else
        self.punctuation_pause_enabled = punctuation_setting
    end
    self.punctuation_pause_multiplier = self.settings:readSetting("punctuation_pause_multiplier") or 1.5

    -- RSVP font: a crengine face name, or nil for the built-in default fonts
    self.rsvp_font_face = self.settings:readSetting("rsvp_font_face")
    self.rsvp_font_size = self.settings:readSetting("rsvp_font_size") or 28

    -- OVP crosshair distance from the left margin, in wide-letter widths
    self.ovp_offset_letters = self.settings:readSetting("ovp_offset_letters") or 6.5
    local hyphenate_setting = self.settings:readSetting("hyphenate_long_words")
    if hyphenate_setting == nil then
        self.hyphenate_long_words = true
    else
        self.hyphenate_long_words = hyphenate_setting
    end
    -- Highlight on stop: "off", "replace" (move the previous one) or "keep" (keep all)
    self.highlight_on_stop = self.settings:readSetting("highlight_on_stop") or "replace"
    self.highlight_style = self.settings:readSetting("highlight_style") or "lighten"
    self.highlight_color = self.settings:readSetting("highlight_color") or "red"
    local split_setting = self.settings:readSetting("split_hyphenated_words")
    if split_setting == nil then
        self.split_hyphenated_words = true
    else
        self.split_hyphenated_words = split_setting
    end

    -- Position tracking for resume functionality
    self.last_page_hash = nil -- Hash to identify current page content
    self.last_word_index = 1  -- Last read word index on this page
    self.show_position_indicator = self.settings:readSetting("show_position_indicator") or true
    
    -- Multi-word display settings
    self.words_preview_count = self.settings:readSetting("words_preview_count") or 3 -- Show current + 2 next words
    
    -- Register for document events to setup callbacks when document is ready
    self.ui:registerPostReaderReadyCallback(function()
        self:setupTapHandler()
    end)
end

function FastReader:saveSettings()
    if self.settings then
        self.settings:saveSetting("rsvp_speed", self.rsvp_speed)
        self.settings:saveSetting("tap_to_launch_enabled", self.tap_to_launch_enabled)
        self.settings:saveSetting("show_position_indicator", self.show_position_indicator)
        self.settings:saveSetting("words_preview_count", self.words_preview_count)
        self.settings:saveSetting("ovp_alignment_enabled", self.ovp_alignment_enabled)
        self.settings:saveSetting("punctuation_pause_enabled", self.punctuation_pause_enabled)
        self.settings:saveSetting("punctuation_pause_multiplier", self.punctuation_pause_multiplier)
        self.settings:saveSetting("rsvp_font_face", self.rsvp_font_face)
        self.settings:saveSetting("rsvp_font_size", self.rsvp_font_size)
        self.settings:saveSetting("ovp_offset_letters", self.ovp_offset_letters)
        self.settings:saveSetting("hyphenate_long_words", self.hyphenate_long_words)
        self.settings:saveSetting("split_hyphenated_words", self.split_hyphenated_words)
        self.settings:saveSetting("highlight_on_stop", self.highlight_on_stop)
        self.settings:saveSetting("highlight_style", self.highlight_style)
        self.settings:saveSetting("highlight_color", self.highlight_color)
        self.settings:flush()
    end
end

-- Returns a font file and face index for the chosen RSVP font, or nil for the default fonts
function FastReader:getRSVPFontFile()
    if not self.rsvp_font_face then
        return nil
    end
    local ok, filename, faceindex = pcall(function()
        local cre = require("document/credocument"):engineInit()
        return cre.getFontFaceFilenameAndFaceIndex(self.rsvp_font_face)
    end)
    if ok and filename then
        return filename, faceindex
    end
    logger.warn("FastReader: RSVP font not found, using default: " .. tostring(self.rsvp_font_face))
    return nil
end

-- Highlight on Stop submenu: mode, then style and color
function FastReader:getHighlightMenuItems()
    local function radio(text, get, set, value)
        return {
            text = text,
            radio = true,
            checked_func = function()
                return get() == value
            end,
            callback = function()
                set(value)
                self:saveSettings()
            end,
        }
    end
    local function highlightEnabled()
        return self.highlight_on_stop ~= "off"
    end

    local get_mode = function() return self.highlight_on_stop end
    local set_mode = function(v) self.highlight_on_stop = v end
    local items = {
        radio(_("Off"), get_mode, set_mode, "off"),
        radio(_("Replace previous"), get_mode, set_mode, "replace"),
        radio(_("Keep all"), get_mode, set_mode, "keep"),
    }
    items[#items].separator = true

    local get_style = function() return self.highlight_style end
    local set_style = function(v) self.highlight_style = v end
    local style_labels = { lighten = _("Color"), underscore = _("Underline") }
    table.insert(items, {
        text_func = function()
            return T(_("Style: %1"), style_labels[self.highlight_style] or self.highlight_style)
        end,
        enabled_func = highlightEnabled,
        sub_item_table = {
            radio(_("Color"), get_style, set_style, "lighten"),
            radio(_("Underline"), get_style, set_style, "underscore"),
        },
    })

    -- Same color names as KOReader's own highlights
    local colors = {
        { _("Red"), "red" }, { _("Orange"), "orange" }, { _("Yellow"), "yellow" },
        { _("Green"), "green" }, { _("Olive"), "olive" }, { _("Cyan"), "cyan" },
        { _("Blue"), "blue" }, { _("Purple"), "purple" }, { _("Gray"), "gray" },
    }
    local get_color = function() return self.highlight_color end
    local set_color = function(v) self.highlight_color = v end
    local color_items = {}
    local color_labels = {}
    for _, c in ipairs(colors) do
        table.insert(color_items, radio(c[1], get_color, set_color, c[2]))
        color_labels[c[2]] = c[1]
    end
    table.insert(items, {
        text_func = function()
            return T(_("Color: %1"), color_labels[self.highlight_color] or self.highlight_color)
        end,
        enabled_func = highlightEnabled,
        sub_item_table = color_items,
        help_text = _("Colors show on color screens; black-and-white screens show them as gray."),
    })
    return items
end

-- Font submenu: Default, then the same faces as the book font menu (Typeset > Font)
function FastReader:getFontMenuItems()
    local items = {
        {
            text = _("Default"),
            radio = true,
            checked_func = function()
                return self.rsvp_font_face == nil
            end,
            callback = function()
                self.rsvp_font_face = nil
                self:saveSettings()
            end,
            separator = true,
        },
    }

    local ok, err = pcall(function()
        local cre = require("document/credocument"):engineInit()
        local FontList = require("fontlist")
        local faces = cre.getFontFaces()
        table.sort(faces, function(a, b) return a:lower() < b:lower() end)
        for _, face in ipairs(faces) do
            local filename, faceindex, is_monospace = cre.getFontFaceFilenameAndFaceIndex(face)
            local name = filename and FontList:getLocalizedFontName(filename, faceindex) or face
            if is_monospace then
                name = name .. " 🄼"
            end
            table.insert(items, {
                text = name,
                radio = true,
                font_func = filename and function(size)
                    return Font:getFace(filename, size, faceindex)
                end or nil,
                checked_func = function()
                    return self.rsvp_font_face == face
                end,
                callback = function()
                    self.rsvp_font_face = face
                    self:saveSettings()
                end,
            })
        end
    end)
    if not ok then
        logger.warn("FastReader: Could not load font list: " .. tostring(err))
        UIManager:show(InfoMessage:new{
            text = _("Could not load font list"),
            timeout = 3,
        })
    end
    return items
end

function FastReader:enableContinuousView()
    -- Save original view mode
    if self.ui.rolling then
        -- Already in continuous mode for reflowable documents
        logger.info("FastReader: Document already in rolling mode")
        return true
    elseif self.ui.paging then
        -- For paged documents, save original mode
        self.original_view_mode = "paging"
        logger.info("FastReader: Document in paging mode, will use page-by-page navigation")
        
        -- Try to enable scroll mode if document supports it
        if self.ui.document.provider == "crengine" then
            -- This is a reflowable document in paging mode, could switch to scroll
            logger.info("FastReader: Could potentially switch to scroll mode for crengine document")
        elseif self.ui.document.provider == "mupdf" then
            -- PDF document - can't really switch to continuous, but we'll handle page navigation
            logger.info("FastReader: PDF document - will use page-by-page navigation")
        end
        
        return true
    end
    logger.warn("FastReader: Unknown document type")
    return false
end

function FastReader:restoreOriginalView()
    if self.original_view_mode and self.original_view_mode == "paging" then
        -- Restore paging mode if it was originally used
        -- Implementation would depend on KOReader's internal APIs
        self.original_view_mode = nil
    end
end

function FastReader:extractWordsFromCurrentPage()
    if not self.ui.document then
        logger.warn("FastReader: No document available")
        return {}
    end
    
    local text = ""
    local debug_info = {}
    self.page_start_xp = nil
    
    logger.info("FastReader: Starting text extraction")
    logger.info("FastReader: Document type: " .. tostring(self.ui.document.provider))
    
    if self.ui.rolling then
        -- For reflowable documents (EPUB, FB2, etc.)
        -- Use the same method as readerview.lua getCurrentPageLineWordCounts()
        logger.info("FastReader: Rolling document - using getTextFromPositions")
        
        local success, text_result = pcall(function()
            local Screen = require("device").screen
            local res = self.ui.document:getTextFromPositions(
                {x = 0, y = 0},
                {x = Screen:getWidth(), y = Screen:getHeight()}, 
                true -- do not highlight
            )
            
            if res and res.text then
                logger.info("FastReader: getTextFromPositions success: " .. string.len(res.text) .. " characters")
                -- Where this page's text starts, used to locate a word for highlighting
                self.page_start_xp = res.pos0
                return res.text
            else
                logger.warn("FastReader: getTextFromPositions returned empty result")
                return nil
            end
        end)
        
        if success and text_result and text_result ~= "" then
            text = text_result
            table.insert(debug_info, "SUCCESS: getTextFromPositions returned " .. string.len(text_result) .. " chars")
            logger.info("FastReader: Text extraction success: " .. string.len(text_result) .. " characters")
        else
            table.insert(debug_info, "FAILED: getTextFromPositions - " .. tostring(text_result))
            logger.warn("FastReader: getTextFromPositions failed: " .. tostring(text_result))
            
            -- Fallback: try to get text from XPointers
            local fallback_success, fallback_text = pcall(function()
                -- For rolling documents, try XPointer method
                if self.ui.rolling and self.ui.document.getTextFromXPointers then
                    local current_xpointer = self.ui.rolling:getBookLocation()
                    if current_xpointer then
                        local text_result = self.ui.document:getTextFromXPointers(current_xpointer, current_xpointer, true)
                        if text_result and text_result.text and text_result.text ~= "" then
                            return text_result.text
                        end
                    end
                end
                return nil
            end)
            
            if fallback_success and fallback_text and fallback_text ~= "" then
                text = fallback_text
                table.insert(debug_info, "SUCCESS: XPointer fallback returned " .. string.len(fallback_text) .. " chars")
                logger.info("FastReader: XPointer fallback success: " .. string.len(fallback_text) .. " characters")
            else
                table.insert(debug_info, "FAILED: XPointer fallback - " .. tostring(fallback_text))
                logger.warn("FastReader: XPointer fallback failed: " .. tostring(fallback_text))
            end
        end
        
    elseif self.ui.paging then
        -- For paged documents (PDF, DjVu, etc.)
        local page = self.ui.paging.current_page
        table.insert(debug_info, "Document type: paging (PDF/DjVu/etc), page: " .. tostring(page))
        logger.info("FastReader: Paging document, page: " .. tostring(page))
        
        -- Use getTextFromPositions over the whole page, the same call used to locate
        -- a tapped word, so word order and indices stay consistent
        if page then
            local success, page_text = pcall(function()
                local dims = self.ui.document:getNativePageDimensions(page)
                local res = self.ui.document:getTextFromPositions(
                    {x = 0, y = 0, page = page},
                    {x = dims.w, y = dims.h, page = page}
                )
                return res and res.text
            end)
            if success and type(page_text) == "string" and page_text ~= "" then
                text = page_text
                table.insert(debug_info, "SUCCESS: getTextFromPositions returned " .. string.len(page_text) .. " chars")
                logger.info("FastReader: Successfully extracted " .. string.len(page_text) .. " characters")
            else
                table.insert(debug_info, "FAILED: getTextFromPositions - " .. tostring(page_text))
                logger.warn("FastReader: getTextFromPositions failed: " .. tostring(page_text))
            end
        end

        if text == "" and page and self.ui.document.getPageText then
            local success, page_text = pcall(self.ui.document.getPageText, self.ui.document, page)
            page_text = success and flattenPageText(page_text) or ""
            if page_text ~= "" then
                text = page_text
                table.insert(debug_info, "SUCCESS: getPageText returned " .. string.len(page_text) .. " chars")
                logger.info("FastReader: getPageText fallback extracted " .. string.len(page_text) .. " characters")
            else
                table.insert(debug_info, "FAILED: getPageText fallback")
                logger.warn("FastReader: getPageText fallback failed")
            end
        end
    else
        table.insert(debug_info, "ERROR: Unknown document type - neither rolling nor paging")
        logger.warn("FastReader: Unknown document type")
    end
    
    logger.info("FastReader: Final text extraction result: " .. (text and string.len(text) or 0) .. " characters")
    
    -- Show debug info if no text was found
    if not text or text == "" then
        logger.warn("FastReader: Text extraction completely failed")
        logger.info("FastReader: Debug info: " .. table.concat(debug_info, " | "))
        
        UIManager:show(InfoMessage:new{
            text = _("Cannot extract text from this document type"),
            timeout = 3,
        })
        
        return {}
    end
    
    local words = splitWords(text)

    logger.info("FastReader: Successfully extracted " .. #words .. " words")
    return words
end

-- Focus letter position for a word of char_count letters (OpenSpritz pivot table)
local function getOptimalRecognitionIndex(char_count)
    if char_count <= 1 then
        return 1
    elseif char_count <= 5 then
        return 2
    elseif char_count <= 9 then
        return 3
    elseif char_count <= 13 then
        return 4
    end
    return 5
end

local function measureTextWidth(face, text, bold)
    if not text or text == "" then
        return 0
    end
    local metrics = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, text, true, bold)
    return math.floor(metrics.x or 0)
end

local function calculateAnchorOffset(word, face, bold)
    if not word or word == "" then
        return 0, 1
    end

    local chars = util.splitToChars(word)
    local char_count = #chars
    if char_count == 0 then
        return 0, 1
    end

    -- Pick the focus letter from the word itself, ignoring surrounding punctuation
    local lead = 0
    while lead < char_count and isPunctuationChar(chars[lead + 1]) do
        lead = lead + 1
    end
    local trail = 0
    while trail < char_count - lead and isPunctuationChar(chars[char_count - trail]) do
        trail = trail + 1
    end
    local core_count = char_count - lead - trail
    local ovp_index
    if core_count > 0 then
        ovp_index = lead + getOptimalRecognitionIndex(core_count)
    else
        ovp_index = getOptimalRecognitionIndex(char_count)
    end
    local prefix_text = table.concat(chars, "", 1, ovp_index - 1)
    local key_char = chars[ovp_index] or ""

    local prefix_width = measureTextWidth(face, prefix_text, bold)
    local key_width = measureTextWidth(face, key_char, bold)

    return prefix_width + (key_width / 2), ovp_index
end

-- Positions in `core` (a list of characters) after which a word may be broken:
-- after its own hyphens, and at dictionary break points from `hyphenate`,
-- which returns a hyphen-separated hyphenation of a hyphen-free segment
local function findBreakPoints(core, hyphenate)
    local breaks = {}
    local seg_start = 1
    for i = 1, #core + 1 do
        if i > #core or core[i] == "-" then
            local seg_len = i - seg_start
            if hyphenate and seg_len >= 4 then
                local segment = table.concat(core, "", seg_start, i - 1)
                local hyphenated = hyphenate(segment)
                if type(hyphenated) == "string" then
                    -- Align the hyphenated string with the segment; give up on any mismatch
                    local seg_breaks = {}
                    local j = seg_start - 1
                    local aligned = true
                    for _, ch in ipairs(util.splitToChars(hyphenated)) do
                        if j < i - 1 and ch == core[j + 1] then
                            j = j + 1
                        elseif ch == "-" and j >= seg_start and j < i - 1 then
                            seg_breaks[j] = true
                        else
                            aligned = false
                            break
                        end
                    end
                    if aligned and j == i - 1 then
                        for pos in pairs(seg_breaks) do
                            breaks[pos] = true
                        end
                    end
                end
            end
            if i < #core then
                breaks[i] = true -- after an existing hyphen
            end
            seg_start = i + 1
        end
    end
    return breaks
end

-- Characters that join the parts of a compound word ("well-known", "word—word")
local COMPOUND_SEPARATORS = charSet{ "-", "—" }

-- Split a hyphenated compound into its parts for easier reading:
-- "mother-in-law" -> "mother-", "in-", "law". Runs of separators ("word--word")
-- count as one break. A break is skipped when either side has fewer than 2
-- letters, so "e-mail" and "T-shirt" stay whole. Leading punctuation stays on
-- the first part, trailing punctuation on the last.
local function splitCompound(word)
    local chars = util.splitToChars(word)
    local lead = 0
    while lead < #chars and isPunctuationChar(chars[lead + 1]) do
        lead = lead + 1
    end
    local trail = 0
    while trail < #chars - lead and isPunctuationChar(chars[#chars - trail]) do
        trail = trail + 1
    end

    -- Segments of the core, each with the separator run that follows it
    local segments = {}
    local current = { text = {}, letters = 0, sep = {} }
    for i = lead + 1, #chars - trail do
        local ch = chars[i]
        if COMPOUND_SEPARATORS[ch] then
            table.insert(current.sep, ch)
        else
            if #current.sep > 0 then
                table.insert(segments, current)
                current = { text = {}, letters = 0, sep = {} }
            end
            table.insert(current.text, ch)
            if not isPunctuationChar(ch) then
                current.letters = current.letters + 1
            end
        end
    end
    table.insert(segments, current)
    if #segments < 2 then
        return { word }
    end

    local pieces = {}
    local piece = table.concat(chars, "", 1, lead)
    for k, seg in ipairs(segments) do
        piece = piece .. table.concat(seg.text) .. table.concat(seg.sep)
        local next_seg = segments[k + 1]
        if next_seg and seg.letters >= 2 and next_seg.letters >= 2 then
            table.insert(pieces, piece)
            piece = ""
        end
    end
    table.insert(pieces, piece .. table.concat(chars, "", #chars - trail + 1, #chars))
    return pieces
end

local MIN_LAST_CHUNK = 3

-- Split a word that doesn't fit into hyphenated chunks that do.
-- fits(text) says whether a chunk fits in the widget; hyphenate(segment) returns
-- dictionary break points (or nil). Leading punctuation stays on the first chunk,
-- trailing punctuation on the last.
local function chunkWord(word, fits, hyphenate)
    if fits(word) then
        return { word }
    end
    local chars = util.splitToChars(word)
    local lead = 0
    while lead < #chars and isPunctuationChar(chars[lead + 1]) do
        lead = lead + 1
    end
    local trail = 0
    while trail < #chars - lead and isPunctuationChar(chars[#chars - trail]) do
        trail = trail + 1
    end
    local prefix = table.concat(chars, "", 1, lead)
    local suffix = table.concat(chars, "", #chars - trail + 1, #chars)
    local core = {}
    for i = lead + 1, #chars - trail do
        table.insert(core, chars[i])
    end
    if #core < MIN_LAST_CHUNK + 1 then
        return { word }
    end

    local breaks = findBreakPoints(core, hyphenate)
    local chunks = {}
    local start = 1
    while start <= #core do
        local head = (start == 1) and prefix or ""
        local rest = head .. table.concat(core, "", start, #core) .. suffix
        if fits(rest) then
            table.insert(chunks, rest)
            break
        end

        local function candidate(p)
            local piece = head .. table.concat(core, "", start, p)
            if core[p] ~= "-" then
                piece = piece .. "-"
            end
            return piece
        end
        -- Longest piece ending at a preferred break point, leaving at least MIN_LAST_CHUNK letters
        local best
        for p = #core - MIN_LAST_CHUNK, start + 1, -1 do
            if breaks[p] and fits(candidate(p)) then
                best = p
                break
            end
        end
        -- Otherwise break between any two letters
        if not best then
            for p = #core - MIN_LAST_CHUNK, start, -1 do
                if fits(candidate(p)) then
                    best = p
                    break
                end
            end
        end
        -- Nothing fits (very narrow widget): take one letter so we always make progress
        if not best then
            best = start
        end
        table.insert(chunks, candidate(best))
        start = best + 1
    end
    return chunks
end

local RSVPWidget = InputContainer:extend{
    name = "fastreader_rsvp_widget",
}

function RSVPWidget:init()
    self.word_widgets = {}
    self:updateDimensions()
    if Device:hasKeys() then
        self.key_events = {
            Close = { { "Back" }, doc = "close RSVP reader" },
            TogglePause = { { "Press" }, doc = "pause/resume RSVP reader" },
        }
    end
end

function RSVPWidget:updateDimensions(new_dimen)
    local sw = (new_dimen and new_dimen.w) or Screen:getWidth()
    local sh = (new_dimen and new_dimen.h) or Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    local preview_count = self.plugin.words_preview_count or 3
    local width_ratio = (preview_count <= 2) and 0.7 or 0.9
    local fixed_width = math.floor(sw * width_ratio)
    local max_width = math.max(sw - Screen:scaleBySize(40), Screen:scaleBySize(220))
    local min_width = math.min(Screen:scaleBySize(320), max_width)
    fixed_width = math.max(fixed_width, min_width)
    fixed_width = math.min(fixed_width, max_width)
    -- Layout constants below were tuned for the default 28pt font; scale them with the chosen size
    local font_size = self.plugin.rsvp_font_size or 28
    self.size_scale = font_size / 28
    local fixed_height = Screen:scaleBySize(math.max(80, 120 * self.size_scale))
    local frame_x = math.floor((sw - fixed_width) / 2)
    local frame_y = math.floor((sh - fixed_height) / 2)

    self.box_dimen = Geom:new{
        x = frame_x,
        y = frame_y,
        w = fixed_width,
        h = fixed_height,
    }

    self.text_padding = Screen:scaleBySize(20)
    self.inter_word_gap = Screen:scaleBySize(15)

    local secondary_size = math.floor(font_size * 24 / 28 + 0.5)
    local anchor_face, secondary_face
    local font_file, font_faceindex = self.plugin:getRSVPFontFile()
    if font_file then
        anchor_face = Font:getFace(font_file, font_size, font_faceindex)
        secondary_face = Font:getFace(font_file, secondary_size, font_faceindex)
    end
    if not anchor_face or not secondary_face then
        local base_font_name = self.plugin.ovp_alignment_enabled and "infont" or "cfont"
        anchor_face = Font:getFace(base_font_name, font_size)
        secondary_face = Font:getFace(base_font_name, secondary_size)
    end
    self.anchor_face = anchor_face
    self.secondary_face = secondary_face
    -- Average lowercase letter width in the current word's font, the unit for the OVP offset
    local alphabet = "abcdefghijklmnopqrstuvwxyz"
    self.letter_w = measureTextWidth(anchor_face, alphabet, true) / #alphabet
    self.chunk_cache = {}

    self.ges_events = {
        Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen }
        },
        Hold = {
            GestureRange:new{ ges = "hold", range = self.dimen }
        },
        HoldRelease = {
            GestureRange:new{ ges = "hold_release", range = self.dimen }
        },
    }
end

function RSVPWidget:handleResize(new_dimen)
    local sw = (new_dimen and new_dimen.w) or Screen:getWidth()
    local sh = (new_dimen and new_dimen.h) or Screen:getHeight()
    if self.dimen and self.dimen.w == sw and self.dimen.h == sh then
        return
    end
    self:updateDimensions(new_dimen)
    self:freeWidgets()
    UIManager:setDirty(nil, "full")
end

function RSVPWidget:onSetDimensions(dimen)
    self:handleResize(dimen)
    return false
end

function RSVPWidget:onScreenResize(dimen)
    self:handleResize(dimen)
    return false
end

function RSVPWidget:onTap(arg, ges)
    self.plugin:togglePause()
    return true
end

function RSVPWidget:onHold(arg, ges)
    -- Long press only stops once paused, so a stray hold while reading is harmless
    if self.plugin.rsvp_paused then
        self.plugin:stopRSVP({ user_initiated = true })
    end
    return true
end

function RSVPWidget:onHoldRelease(arg, ges)
    return true
end

function RSVPWidget:onTogglePause()
    self.plugin:togglePause()
    return true
end

function RSVPWidget:onClose()
    self.plugin:stopRSVP({ user_initiated = true })
    return true
end

function RSVPWidget:freeWidgets()
    if self.word_widgets then
        for _, w in ipairs(self.word_widgets) do
            w:free()
        end
        self.word_widgets = {}
    end
    self.chunk_cache = {}
end

-- Box-wide layout values shared by painting and the chunk fit check
function RSVPWidget:getLayout()
    local inner_w = self.box_dimen.w - (self.text_padding * 2)
    local preview_count = self.plugin.words_preview_count or 3
    local size_scale = self.size_scale or 1
    local min_left_padding = Screen:scaleBySize(20)
    local base_right_padding = Screen:scaleBySize(((preview_count <= 2) and 140 or 180) * size_scale)
    base_right_padding = math.max(Screen:scaleBySize(80 * size_scale), math.min(base_right_padding, math.floor(inner_w * 0.6)))

    local anchor_target
    if self.plugin.ovp_alignment_enabled then
        -- Crosshair sits ovp_offset_letters average letter widths from the inner edge,
        -- measured in the current font/size so it stays fixed for every word
        anchor_target = math.floor(self.plugin.ovp_offset_letters * self.letter_w + 0.5)
        anchor_target = math.min(anchor_target, math.floor(inner_w * 0.75))
    end

    return {
        inner_w = inner_w,
        min_left_padding = min_left_padding,
        base_right_padding = base_right_padding,
        anchor_target = anchor_target,
        fixed_leading = math.max(math.floor((inner_w - base_right_padding) * 0.2), min_left_padding),
    }
end

-- Anchor offset and left padding for the current word's text
function RSVPWidget:layoutCurrent(text, layout)
    if self.plugin.ovp_alignment_enabled then
        local anchor_offset = calculateAnchorOffset(text, self.anchor_face, true)
        -- The offset is measured from the inner edge (the box padding already clears the border),
        -- so only clamp at that edge
        return anchor_offset, math.max(layout.anchor_target - anchor_offset, 0)
    end
    return 0, layout.fixed_leading
end

-- Words keep their punctuation only when punctuation pauses are enabled
function RSVPWidget:displayText(word)
    return self.plugin.punctuation_pause_enabled and word or stripPunctuation(word)
end

-- The displayed chunks of a word: the word itself, its compound parts
-- ("well-" / "known"), and hyphenated parts of anything too long to fit
function RSVPWidget:getChunks(text)
    local split_compounds = self.plugin.split_hyphenated_words
    local hyphenate = self.plugin.hyphenate_long_words
    if not split_compounds and not hyphenate then
        return { text }
    end
    local chunks = self.chunk_cache[text]
    if not chunks then
        local pieces = split_compounds and splitCompound(text) or { text }
        if hyphenate then
            local layout = self:getLayout()
            local function fits(t)
                local _, leading = self:layoutCurrent(t, layout)
                -- Small safety margin: the drawn TextWidget can be a pixel or two wider than this measurement
                return leading + measureTextWidth(self.anchor_face, t, true) <= layout.inner_w - Screen:scaleBySize(2)
            end
            local function dictionary(segment)
                return self.plugin:getHyphenation(segment)
            end
            chunks = {}
            for _, piece in ipairs(pieces) do
                for _, chunk in ipairs(chunkWord(piece, fits, dictionary)) do
                    table.insert(chunks, chunk)
                end
            end
        else
            chunks = pieces
        end
        self.chunk_cache[text] = chunks
    end
    return chunks
end

function RSVPWidget:getWordWidget(idx)
    local widget = self.word_widgets[idx]
    if not widget then
        local is_current = (idx == 1)
        widget = TextWidget:new{
            text = "",
            face = is_current and self.anchor_face or self.secondary_face,
            bold = is_current,
            fgcolor = Blitbuffer.COLOR_BLACK,
            padding = 0,
        }
        self.word_widgets[idx] = widget
    end
    return widget
end

function RSVPWidget:updateWord(words, current_index)
    self.words = words
    self.current_index = current_index
end

function RSVPWidget:paintTo(bb, x, y)
    local box = self.box_dimen
    local bx, by, bw, bh = box.x, box.y, box.w, box.h
    local pad = self.text_padding
    local inner_w = bw - (pad * 2)
    local inner_h = bh - (pad * 2)
    local inner_x = bx + pad
    local inner_y = by + pad

    -- 1. Wipe the entire RSVP box clean with solid white (erases previous word and anti-aliasing)
    bb:paintRect(bx, by, bw, bh, Blitbuffer.COLOR_WHITE)

    -- 2. Draw crisp 2-pixel black border (anti_alias = false for crisp 1-bit E-ink rendering)
    bb:paintBorder(bx, by, bw, bh, 2, Blitbuffer.COLOR_BLACK, 0, false)

    if not self.words or not self.current_index or not self.words[self.current_index] then
        return
    end

    -- Current item: the word, or the current hyphenated chunk of a long word
    local chunks = self:getChunks(self:displayText(self.words[self.current_index]))
    local current_word = chunks[math.min(self.plugin.current_chunk_index or 1, #chunks)]
    local preview_count = self.plugin.words_preview_count or 3

    -- Gather preview words (current + next words)
    local preview_words = { current_word }
    for i = 1, preview_count - 1 do
        local idx = self.current_index + i
        if idx <= #self.words then
            table.insert(preview_words, self:displayText(self.words[idx]))
        end
    end

    local anchor_face = self.anchor_face
    local inter_word_gap = self.inter_word_gap
    local size_scale = self.size_scale or 1
    local layout = self:getLayout()
    local min_left_padding = layout.min_left_padding
    local base_right_padding = layout.base_right_padding
    local anchor_offset, leading_padding = self:layoutCurrent(current_word, layout)

    -- Setup current word widget (always slot 1)
    local current_widget = self:getWordWidget(1)
    current_widget:setMaxWidth(nil)
    current_widget:setText(current_word)
    local current_w = current_widget:getSize().w

    -- If current word exceeds space from leading_padding to right edge, shift left towards min_left_padding
    if leading_padding + current_w > inner_w and leading_padding > min_left_padding then
        local overflow = (leading_padding + current_w) - inner_w
        leading_padding = math.max(min_left_padding, leading_padding - overflow)
    end

    -- Issue 1: Bound current word so it can never draw outside box_dimen
    local max_current_w = inner_w - leading_padding
    if current_w > max_current_w then
        current_widget:setMaxWidth(max_current_w)
        current_w = current_widget:getSize().w
    end

    local items = {
        {
            widget = current_widget,
            width = current_w,
            is_current = true,
        },
    }
    local total_w = leading_padding + current_w
    local max_allowed_w = inner_w - base_right_padding

    -- Measure and add preview words
    for i = 2, #preview_words do
        local word = preview_words[i]
        local widget = self:getWordWidget(i)
        widget:setMaxWidth(nil)
        widget:setText(word)
        local w = widget:getSize().w
        table.insert(items, {
            widget = widget,
            width = w,
            is_current = false,
        })
        total_w = total_w + inter_word_gap + w
    end

    -- Trim preview words that exceed max allowed width
    while #items > 1 and total_w > max_allowed_w do
        local last = table.remove(items)
        total_w = total_w - last.width - inter_word_gap
    end

    local word_x = inner_x + leading_padding
    local baseline_y = by + math.floor(bh / 2) + math.floor(anchor_face.size * 0.3)

    -- 3. Draw OVP crosshairs / fixation guide if enabled (pure black, crisp 1-bit lines)
    if self.plugin.ovp_alignment_enabled then
        local crosshair_x = math.floor(word_x + anchor_offset)
        crosshair_x = math.max(inner_x + 1, math.min(crosshair_x, inner_x + inner_w - 2))
        local guide_h = Screen:scaleBySize(12 * size_scale)
        -- Top guide tick at fixation point
        bb:paintRect(crosshair_x - 1, inner_y, 2, guide_h, Blitbuffer.COLOR_BLACK)
        -- Bottom guide tick at fixation point
        bb:paintRect(crosshair_x - 1, inner_y + inner_h - guide_h, 2, guide_h, Blitbuffer.COLOR_BLACK)
    end

    -- 4. Render words using TextWidgets via paintTo, ensuring every widget is bounded by remaining box width
    local cur_x = word_x
    for _, item in ipairs(items) do
        local widget = item.widget
        local remaining_w = (inner_x + inner_w) - cur_x
        if remaining_w > 0 then
            widget:setMaxWidth(remaining_w)
            local widget_y = baseline_y - widget:getBaseline()
            widget:paintTo(bb, cur_x, widget_y)
            cur_x = cur_x + widget:getSize().w + inter_word_gap
        end
    end
end

function FastReader:showRSVPWord(current_word)
    if not current_word or current_word == "" then
        return
    end

    if not self.rsvp_widget then
        self.rsvp_widget = RSVPWidget:new{
            plugin = self,
        }
        self.rsvp_widget:updateWord(self.words, self.current_word_index)
        -- Opens on a still (paused) word, so use a clean "ui" refresh rather than "fast"
        UIManager:show(self.rsvp_widget, "ui", self.rsvp_widget.box_dimen)
        return
    end

    -- Screen rotation / window resize check
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    if self.rsvp_widget.dimen.w ~= sw or self.rsvp_widget.dimen.h ~= sh then
        self.rsvp_widget:handleResize()
    end

    self.rsvp_widget:updateWord(self.words, self.current_word_index)

    -- Use "fast" mode for smooth word updates
    UIManager:setDirty(self.rsvp_widget, "fast", self.rsvp_widget.box_dimen)
end

function FastReader:onSetDimensions(dimen)
    if self.rsvp_widget then
        self.rsvp_widget:onSetDimensions(dimen)
    end
end

function FastReader:onScreenResize(dimen)
    if self.rsvp_widget then
        self.rsvp_widget:onScreenResize(dimen)
    end
end

-- Displayed chunks of the current word (more than one when it's hyphenated)
function FastReader:getCurrentChunks()
    local word = self.words[self.current_word_index]
    if not word or not self.rsvp_widget then
        return { word }
    end
    return self.rsvp_widget:getChunks(self.rsvp_widget:displayText(word))
end

-- Dictionary hyphenation of a word segment ("in-ter-na-tion-al"), or nil if unavailable
function FastReader:getHyphenation(segment)
    local ok, result = pcall(function()
        local cre = require("document/credocument"):engineInit()
        return cre.getHyphenationForWord(segment)
    end)
    if ok and type(result) == "string" then
        return result
    end
    return nil
end

-- Letter range (first, last) of the current word within the page's letters
function FastReader:getCurrentWordLetterRange()
    local offset = 0
    for i = 1, self.current_word_index - 1 do
        offset = offset + countLetters(self.words[i])
    end
    local len = countLetters(self.words[self.current_word_index])
    if len == 0 then
        return nil
    end
    return offset + 1, offset + len
end

-- Locate the current word in the document, as a selection ReaderHighlight can save
function FastReader:locateCurrentWord()
    local first, last = self:getCurrentWordLetterRange()
    if not first then
        return nil
    end
    local doc = self.ui.document

    if self.ui.rolling then
        -- Walk the document's words from the start of the page, counting letters
        local s = self.page_start_xp
        local count, pos0, pos1 = 0, nil, nil
        for _ = 1, 10000 do
            if not s then
                break
            end
            local e = doc:getNextVisibleWordEnd(s)
            if not e then
                break
            end
            local n = countLetters(doc:getTextFromXPointers(s, e))
            if n > 0 then
                if not pos0 and count + n >= first then
                    pos0 = s
                end
                count = count + n
                if count >= last then
                    pos1 = e
                    break
                end
            end
            local next_s = doc:getNextVisibleWordStart(s)
            if next_s == s then
                break
            end
            s = next_s
        end
        if pos0 and pos1 then
            return { pos0 = pos0, pos1 = pos1, text = doc:getTextFromXPointers(pos0, pos1) }
        end
        return nil
    end

    -- Paging: walk the page's word boxes, the same boxes the page text was built from
    local page = self.ui.paging.current_page
    local boxes = doc:getTextBoxes(page)
    if not boxes then
        return nil
    end
    local count, first_box, last_box = 0, nil, nil
    for _, line in ipairs(boxes) do
        for _, box in ipairs(line) do
            local n = countLetters(box.word)
            if n > 0 then
                if not first_box and count + n >= first then
                    first_box = box
                end
                count = count + n
                if count >= last then
                    last_box = box
                    break
                end
            end
        end
        if last_box then
            break
        end
    end
    if not (first_box and last_box) then
        return nil
    end
    local function centre(box)
        return { x = (box.x0 + box.x1) / 2, y = (box.y0 + box.y1) / 2, page = page }
    end
    local res = doc:getTextFromPositions(centre(first_box), centre(last_box))
    if not (res and res.pos0 and res.pos1) then
        return nil
    end
    return { pos0 = res.pos0, pos1 = res.pos1, text = res.text, pboxes = res.pboxes }
end

local function samePosition(a, b)
    if type(a) == "table" and type(b) == "table" then
        return a.page == b.page and a.x == b.x and a.y == b.y
    end
    return a == b
end

-- Highlight the current word on stop, replacing the plugin's previous highlight
-- in "replace" mode. Returns true if annotations changed.
function FastReader:highlightCurrentWord()
    if self.highlight_on_stop == "off" or not self.ui.highlight or not self.ui.annotation then
        return false
    end
    local ok, result = pcall(function()
        local loc = self:locateCurrentWord()
        if not loc then
            logger.warn("FastReader: Could not locate current word for highlight")
            return false
        end

        local annotations = self.ui.annotation.annotations
        local stored = self.ui.doc_settings:readSetting("fastreader_stop_highlight")
        if self.highlight_on_stop == "replace" and stored then
            -- Find our previous highlight, if it still exists and the user hasn't edited it
            for i, item in ipairs(annotations) do
                if item.drawer and item.datetime == stored.datetime and samePosition(item.pos0, stored.pos0) then
                    if not item.note and not item.datetime_updated
                            and item.color == stored.color and item.drawer == stored.drawer then
                        if samePosition(item.pos0, loc.pos0) and samePosition(item.pos1, loc.pos1)
                                and item.color == self.highlight_color and item.drawer == self.highlight_style then
                            return false -- already highlighted, nothing to do
                        end
                        self.ui.highlight:deleteHighlight(i)
                    end
                    break
                end
            end
        end

        self.ui.highlight.selected_text = {
            text = loc.text or self.words[self.current_word_index],
            pos0 = loc.pos0,
            pos1 = loc.pos1,
            pboxes = loc.pboxes,
            drawer = self.highlight_style,
            color = self.highlight_color,
        }
        local index = self.ui.highlight:saveHighlight()
        self.ui.highlight.selected_text = nil
        local item = index and annotations[index]
        if item then
            self.ui.doc_settings:saveSetting("fastreader_stop_highlight", {
                datetime = item.datetime,
                pos0 = item.pos0,
                color = item.color,
                drawer = item.drawer,
            })
        end
        return true
    end)
    if not ok then
        logger.warn("FastReader: Highlight on stop failed: " .. tostring(result))
        if self.ui.highlight then
            self.ui.highlight.selected_text = nil
        end
        return false
    end
    return result
end

function FastReader:scheduleNextTick()
    if self.rsvp_timer then
        UIManager:unschedule(self.rsvp_timer)
        self.rsvp_timer = nil
    end
    local interval = 60 / self.rsvp_speed  -- seconds per word (or per chunk of a hyphenated word)
    -- Only the last chunk of a hyphenated word carries its real trailing punctuation
    local is_last_chunk = self.current_chunk_index >= #self:getCurrentChunks()
    if self.punctuation_pause_enabled and is_last_chunk
            and endsWithPausePunctuation(self.words[self.current_word_index]) then
        interval = interval * self.punctuation_pause_multiplier
    end
    self.rsvp_timer = function()
        self.rsvp_timer = nil
        self:rsvpTick()
    end
    UIManager:scheduleIn(interval, self.rsvp_timer)
end

function FastReader:pauseRSVP()
    if not self.rsvp_enabled or self.rsvp_paused then
        return
    end
    self.rsvp_paused = true
    -- Cancel any queued tick so no word slips by after the tap
    if self.rsvp_timer then
        UIManager:unschedule(self.rsvp_timer)
        self.rsvp_timer = nil
    end
    -- Words are drawn with "fast" (A2) refreshes, which leave ghosting. Redraw the
    -- static paused word with a higher-quality "ui" refresh to clean it up.
    if self.rsvp_widget then
        UIManager:setDirty(self.rsvp_widget, "ui", self.rsvp_widget.box_dimen)
    end
    logger.info("FastReader: RSVP paused at word " .. self.current_word_index)
end

function FastReader:resumeRSVP()
    if not self.rsvp_enabled or not self.rsvp_paused then
        return
    end
    self.rsvp_paused = false
    -- Flash the box so the "fast" (A2) word refreshes restart from a clean panel;
    -- A2 drawn over residue from earlier refreshes leaves heavy ghosting
    if self.rsvp_widget then
        UIManager:setDirty(self.rsvp_widget, "flashui", self.rsvp_widget.box_dimen)
    end
    -- If a page turn is in flight, continueRSVPWithNewPage schedules the next tick
    if not self.pending_resume_task then
        self:scheduleNextTick()
    end
    logger.info("FastReader: RSVP resumed at word " .. self.current_word_index)
end

function FastReader:togglePause()
    if self.rsvp_paused then
        self:resumeRSVP()
    else
        self:pauseRSVP()
    end
end

function FastReader:startRSVP(opts)
    opts = opts or {}
    if self.rsvp_enabled then
        logger.info("FastReader: RSVP already enabled, ignoring start request")
        return
    end
    
    logger.info("FastReader: Starting RSVP mode")
    
    -- Enable continuous view mode
    self:enableContinuousView()
    
    -- Extract words from current page
    self.words = self:extractWordsFromCurrentPage()
    
    logger.info("FastReader: Extracted " .. #self.words .. " words from current page")
    
    if #self.words == 0 then
        -- Show error message and abort
        UIManager:show(InfoMessage:new{
            text = _("Cannot extract text from this document. Check logs for details."),
            timeout = 5,
        })
        logger.warn("FastReader: Cannot start RSVP - no words extracted")
        return
    end
    
    self.rsvp_enabled = true
    -- Always open paused on the start word: tap to play, long press to close
    self.rsvp_paused = true
    self.rsvp_has_played = false
    self.current_chunk_index = 1

    -- A tapped word overrides the saved resume position
    local tapped_index = opts.start_pos and self:getWordIndexAtPosition(opts.start_pos)

    if tapped_index then
        self.current_word_index = tapped_index
        logger.info("FastReader: Starting from tapped word " .. self.current_word_index .. " of " .. #self.words)
    elseif self:shouldResumeFromLastPosition() then
        self.current_word_index = self.last_word_index
        logger.info("FastReader: Resuming from word " .. self.current_word_index .. " of " .. #self.words)
        
        -- Show position indicator if enabled
        if self.show_position_indicator then
            self:showPositionIndicator()
        end
    else
        self.current_word_index = 1
        logger.info("FastReader: Starting from beginning")
    end
    
    logger.info("FastReader: RSVP interval set to " .. (60000 / self.rsvp_speed) .. "ms for " .. self.rsvp_speed .. " WPM")

    -- Show the first word paused; resumeRSVP schedules the first tick when the user taps
    self:showRSVPWord(self.words[self.current_word_index])

    logger.info("FastReader: RSVP started successfully")
end

-- opts.user_initiated: stopped by the user (long press, Back, menu), not by reaching
-- the end of the document or closing the book. Only those stops add a highlight.
function FastReader:stopRSVP(opts)
    if not self.rsvp_enabled then
        return
    end

    logger.info("FastReader: Stopping RSVP mode")

    -- Highlight the current word, only if the user stopped after actually reading
    local highlighted = false
    if opts and opts.user_initiated and self.rsvp_has_played then
        highlighted = self:highlightCurrentWord()
    end
    
    -- Save current position before stopping
    if #self.words > 0 and self.current_word_index > 1 then
        self:updateLastReadPosition()
    end
    
    self.rsvp_enabled = false
    self.rsvp_paused = false

    -- Stop timer
    if self.rsvp_timer then
        UIManager:unschedule(self.rsvp_timer)
        self.rsvp_timer = nil
    end

    if self.pending_resume_task then
        UIManager:unschedule(self.pending_resume_task)
        self.pending_resume_task = nil
    end
    
    -- Remove RSVP widget
    if self.rsvp_widget then
        self.rsvp_widget:freeWidgets()
        local refresh_region = self.rsvp_widget.box_dimen or self.rsvp_widget.dimen
        if highlighted then
            -- The highlight (and any removed one) can be anywhere on the page: repaint the
            -- page and flash the whole screen once, which also clears the box's ghosting
            UIManager:setDirty(self.ui.dialog or self.ui)
            refresh_region = nil
        end
        -- Flash on close to clear ghosting left by the "fast" word refreshes
        UIManager:close(self.rsvp_widget, "flashui", refresh_region)
        self.rsvp_widget = nil
    end
    
    -- Remove position indicator if shown
    self:hidePositionIndicator()
    
    -- Restore original view mode
    self:restoreOriginalView()
end

function FastReader:rsvpTick()
    if not self.rsvp_enabled or self.rsvp_paused or #self.words == 0 then
        return
    end
    self.rsvp_has_played = true

    -- Show the next chunk of a hyphenated word before moving on
    if self.current_chunk_index < #self:getCurrentChunks() then
        self.current_chunk_index = self.current_chunk_index + 1
        self:showRSVPWord(self.words[self.current_word_index])
        self:scheduleNextTick()
        return
    end

    self.current_word_index = self.current_word_index + 1
    self.current_chunk_index = 1

    if self.current_word_index <= #self.words then
        self:showRSVPWord(self.words[self.current_word_index])
        self:scheduleNextTick()
    else
        -- End of current page reached, try to go to next page
        logger.info("FastReader: End of current page, attempting to go to next page")
        self:goToNextPageAndContinueRSVP()
    end
end

function FastReader:goToNextPageAndContinueRSVP()
    -- Try to go to next page
    local success = false
    
    if self.ui.paging then
        -- For paged documents (PDF, DjVu, etc.)
        local current_page = self.ui.paging.current_page
        local total_pages = self.ui.document:getPageCount()
        
        if current_page < total_pages then
            self.ui.paging:onGotoPage(current_page + 1)
            success = true
            logger.info("FastReader: Moved to page " .. (current_page + 1))
        else
            logger.info("FastReader: Already at last page")
            self:stopRSVP()
            UIManager:show(InfoMessage:new{
                text = _("End of document reached"),
                timeout = 2,
            })
            return
        end
        
    elseif self.ui.rolling then
        -- For reflowable documents (EPUB, FB2, etc.)
        -- Try to scroll down by one screen
        local Event = require("ui/event")
        local ret = self.ui:handleEvent(Event:new("GotoViewRel", 1))
        if ret then
            success = true
            logger.info("FastReader: Scrolled to next screen in rolling mode")
        else
            logger.info("FastReader: Could not scroll further in rolling mode")
            self:stopRSVP()
            UIManager:show(InfoMessage:new{
                text = _("End of document reached"),
                timeout = 2,
            })
            return
        end
    else
        logger.warn("FastReader: Unknown document type")
        self:stopRSVP()
        return
    end
    
    if success then
        -- Small delay to let the page render, then extract words and continue
        if self.pending_resume_task then
            UIManager:unschedule(self.pending_resume_task)
        end
        self.pending_resume_task = function()
            self.pending_resume_task = nil
            self:continueRSVPWithNewPage()
        end
        UIManager:scheduleIn(0.1, self.pending_resume_task)
    end
end

function FastReader:continueRSVPWithNewPage()
    if not self.rsvp_enabled then
        return
    end
    -- Extract words from new page/position
    local new_words = self:extractWordsFromCurrentPage()
    
    if #new_words > 0 then
        self.words = new_words
        self.current_word_index = 1
        self.current_chunk_index = 1
        -- Reset position tracking for new page
        self.last_page_hash = nil
        self.last_word_index = 1
        logger.info("FastReader: Extracted " .. #new_words .. " words from new page")
        
        -- Continue with first word of new page
        self:showRSVPWord(self.words[self.current_word_index])

        -- Stay paused if the user paused during the page turn
        if not self.rsvp_paused then
            self:scheduleNextTick()
        end
    else
        logger.warn("FastReader: No words extracted from new page, trying next page")
        -- Try one more page if this one is empty
        self:goToNextPageAndContinueRSVP()
    end
end

function FastReader:toggleRSVP()
    if self.rsvp_enabled then
        self:stopRSVP({ user_initiated = true })
    else
        self:startRSVP()
    end
end

function FastReader:addToMainMenu(menu_items)
    menu_items.fastreader = {
        text = _("FastReader"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Start/Stop RSVP"),
                callback = function()
                    self:toggleRSVP()
                end,
            },
            {
                text = _("Tap on Text to Launch RSVP"),
                checked_func = function()
                    return self.tap_to_launch_enabled
                end,
                callback = function()
                    self.tap_to_launch_enabled = not self.tap_to_launch_enabled
                    self:saveSettings()
                    
                    if self.tap_to_launch_enabled then
                        UIManager:show(InfoMessage:new{
                            text = _("Tap-to-launch RSVP enabled. Tap on text to start RSVP reading."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Tap-to-launch RSVP disabled"),
                            timeout = 2,
                        })
                    end
                end,
                help_text = _("When enabled, tapping on text will automatically start RSVP reading without going through the menu."),
            },
            {
                text = _("Show Reading Position"),
                checked_func = function()
                    return self.show_position_indicator
                end,
                callback = function()
                    self.show_position_indicator = not self.show_position_indicator
                    self:saveSettings()
                    
                    if self.show_position_indicator then
                        UIManager:show(InfoMessage:new{
                            text = _("Position indicator enabled. Shows reading progress when resuming."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Position indicator disabled"),
                            timeout = 2,
                        })
                    end
                end,
                help_text = _("When enabled, shows reading position indicator when resuming RSVP on the same page."),
            },
            {
                text = _("Optimal Alignment (OVP)"),
                checked_func = function()
                    return self.ovp_alignment_enabled
                end,
                callback = function()
                    self.ovp_alignment_enabled = not self.ovp_alignment_enabled
                    self:saveSettings()

                    if self.ovp_alignment_enabled then
                        UIManager:show(InfoMessage:new{
                            text = _("Optimal alignment enabled. Words align to the focus crosshair."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Optimal alignment disabled. Words center in the widget."),
                            timeout = 3,
                        })
                    end
                end,
                help_text = _("Aligns each word to its optimal recognition point and shows the subtle crosshair guide."),
            },
            {
                text_func = function()
                    return T(_("OVP Offset: %1 letters"), string.format("%.1f", self.ovp_offset_letters))
                end,
                enabled_func = function()
                    return self.ovp_alignment_enabled
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local spin_widget = SpinWidget:new{
                        title_text = _("OVP Offset"),
                        info_text = _("Distance of the focus crosshair from the left edge, in average letter widths (2.0-10.0)"),
                        width = math.floor(Screen:getWidth() * 0.6),
                        value = self.ovp_offset_letters,
                        value_min = 2.0,
                        value_max = 10.0,
                        value_step = 0.5,
                        value_hold_step = 1.0,
                        precision = "%.1f",
                        default_value = 6.5,
                        callback = function(spin)
                            self.ovp_offset_letters = math.floor(spin.value * 10 + 0.5) / 10
                            self:saveSettings()
                            touchmenu_instance:updateItems()
                        end
                    }
                    UIManager:show(spin_widget)
                end,
                help_text = _("How far the focus crosshair sits from the left edge, measured in average letter widths of the RSVP font. 6.5 fits the start of nearly every word, including one with a leading quote. Smaller values leave more room on the right, but words with long starts may shift."),
            },
            {
                text = _("Hyphenate Long Words"),
                checked_func = function()
                    return self.hyphenate_long_words
                end,
                callback = function()
                    self.hyphenate_long_words = not self.hyphenate_long_words
                    self:saveSettings()
                end,
                help_text = _("Splits words too long for the RSVP widget into hyphenated parts shown one after another, using the book's hyphenation dictionary."),
            },
            {
                text = _("Split Hyphenated Words"),
                checked_func = function()
                    return self.split_hyphenated_words
                end,
                callback = function()
                    self.split_hyphenated_words = not self.split_hyphenated_words
                    self:saveSettings()
                end,
                help_text = _("Shows the parts of hyphenated compound words one after another (well- / known), splitting at hyphens and em dashes. Words with a one-letter part, like e-mail, stay whole."),
            },
            {
                text_func = function()
                    local labels = { off = _("Off"), replace = _("Replace previous"), keep = _("Keep all") }
                    return T(_("Highlight on Stop: %1"), labels[self.highlight_on_stop] or self.highlight_on_stop)
                end,
                sub_item_table_func = function()
                    return self:getHighlightMenuItems()
                end,
                help_text = _("When you stop RSVP after reading (long press, Back or the menu), highlight the word you stopped on. Replace previous moves the highlight each time; Keep all leaves every one. A highlight you've edited is never removed."),
            },
            {
                text = _("Pause on Punctuation"),
                checked_func = function()
                    return self.punctuation_pause_enabled
                end,
                callback = function()
                    self.punctuation_pause_enabled = not self.punctuation_pause_enabled
                    self:saveSettings()

                    if self.punctuation_pause_enabled then
                        UIManager:show(InfoMessage:new{
                            text = _("Pause on punctuation enabled. Words show their punctuation and stay longer after it."),
                            timeout = 3,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Pause on punctuation disabled. Punctuation is hidden and every word gets the same time."),
                            timeout = 3,
                        })
                    end
                end,
                help_text = _("Shows punctuation and holds words ending in punctuation (. , ; : ! ? … —) longer, by the punctuation pause multiplier."),
            },
            {
                text_func = function()
                    return T(_("Punctuation Pause: %1×"), string.format("%.1f", self.punctuation_pause_multiplier))
                end,
                enabled_func = function()
                    return self.punctuation_pause_enabled
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local spin_widget = SpinWidget:new{
                        title_text = _("Punctuation Pause"),
                        info_text = _("How much longer a word ending in punctuation stays on screen (1.0-4.0×)"),
                        width = math.floor(Screen:getWidth() * 0.6),
                        value = self.punctuation_pause_multiplier,
                        value_min = 1.0,
                        value_max = 4.0,
                        value_step = 0.1,
                        value_hold_step = 0.5,
                        precision = "%.1f",
                        default_value = 1.5,
                        unit = "×",
                        callback = function(spin)
                            self.punctuation_pause_multiplier = math.floor(spin.value * 10 + 0.5) / 10
                            self:saveSettings()
                            touchmenu_instance:updateItems()
                        end
                    }
                    UIManager:show(spin_widget)
                end,
                help_text = _("Multiplier applied to a word's display time when it ends in punctuation. 1.0 means no extra pause."),
            },
            {
                text_func = function()
                    return T(_("Font: %1"), self.rsvp_font_face or _("Default"))
                end,
                sub_item_table_func = function()
                    return self:getFontMenuItems()
                end,
                help_text = _("Font used in the RSVP widget. Lists the same fonts as the book font menu. Thin or light fonts may look ragged while words are playing on e-ink."),
            },
            {
                text_func = function()
                    return T(_("Font Size: %1"), self.rsvp_font_size)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local spin_widget = SpinWidget:new{
                        title_text = _("RSVP Font Size"),
                        info_text = _("Size of the current word (16-72). Preview words are slightly smaller."),
                        width = math.floor(Screen:getWidth() * 0.6),
                        value = self.rsvp_font_size,
                        value_min = 16,
                        value_max = 72,
                        value_step = 1,
                        value_hold_step = 4,
                        default_value = 28,
                        callback = function(spin)
                            self.rsvp_font_size = spin.value
                            self:saveSettings()
                            touchmenu_instance:updateItems()
                        end
                    }
                    UIManager:show(spin_widget)
                end,
                help_text = _("Size of the RSVP text. The widget grows to fit larger sizes."),
            },
            {
                text_func = function()
                    return T(_("Preview Words: %1"), self.words_preview_count)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local spin_widget = SpinWidget:new{
                        title_text = _("RSVP Preview Words"),
                        info_text = _("Number of words to show in RSVP widget (1-10)"),
                        width = math.floor(Screen:getWidth() * 0.6),
                        value = self.words_preview_count,
                        value_min = 1,
                        value_max = 10,
                        value_step = 1,
                        value_hold_step = 2,
                        default_value = 3,
                        unit = _("words"),
                        callback = function(spin)
                            self.words_preview_count = spin.value
                            self:saveSettings()
                            touchmenu_instance:updateItems()
                            UIManager:show(InfoMessage:new{
                                text = T(_("Preview words set to %1"), self.words_preview_count),
                                timeout = 2,
                            })
                        end
                    }
                    UIManager:show(spin_widget)
                end,
                help_text = _("Controls how many words are shown in the RSVP widget. The current word is highlighted, upcoming words are dimmed."),
            },
            {
                text = _("RSVP Speed"),
                sub_item_table = {
                    {
                        text_func = function()
                            return T(_("Current: %1 WPM"), self.rsvp_speed)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            local spin_widget = SpinWidget:new{
                                title_text = _("RSVP Reading Speed"),
                                info_text = _("Words per minute (50-1000)"),
                                width = math.floor(Screen:getWidth() * 0.6),
                                value = self.rsvp_speed,
                                value_min = 50,
                                value_max = 1000,
                                value_step = 25,
                                value_hold_step = 100,
                                default_value = 250,
                                unit = "WPM",
                                callback = function(spin)
                                    self.rsvp_speed = spin.value
                                    self:saveSettings()
                                    touchmenu_instance:updateItems()
                                    UIManager:show(InfoMessage:new{
                                        text = T(_("RSVP speed set to %1 WPM"), self.rsvp_speed),
                                        timeout = 1,
                                    })
                                end
                            }
                            UIManager:show(spin_widget)
                        end,
                        separator = true,
                    },
                    {
                        text = _("100 WPM (Very slow)"),
                        callback = function()
                            self.rsvp_speed = 100
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 100 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("150 WPM (Slow)"),
                        callback = function()
                            self.rsvp_speed = 150
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 150 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("200 WPM (Normal)"),
                        callback = function()
                            self.rsvp_speed = 200
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 200 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("250 WPM (Fast)"),
                        callback = function()
                            self.rsvp_speed = 250
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 250 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("300 WPM (Very fast)"),
                        callback = function()
                            self.rsvp_speed = 300
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 300 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("400 WPM (Extreme)"),
                        callback = function()
                            self.rsvp_speed = 400
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 400 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                    {
                        text = _("500 WPM (Ultra fast)"),
                        callback = function()
                            self.rsvp_speed = 500
                            self:saveSettings()
                            UIManager:show(InfoMessage:new{
                                text = _("RSVP speed set to 500 WPM"),
                                timeout = 1,
                            })
                        end,
                    },
                },
            },
        },
    }
end

function FastReader:onFastReaderRSVP()
    self:toggleRSVP()
end

-- Key event handlers for RSVP control
function FastReader:onKeyPress(key)
    if not self.rsvp_enabled then
        return false
    end
    
    if key == "Menu" or key == "Back" then
        self:stopRSVP({ user_initiated = true })
        return true
    elseif key == "Press" or key == "LPgFwd" then
        self:togglePause()
        return true
    elseif key == "LPgBack" then
        -- Go to previous word
        if self.current_word_index > 1 then
            self.current_word_index = self.current_word_index - 1
            self.current_chunk_index = 1
            self:showRSVPWord(self.words[self.current_word_index])
        end
        return true
    end
    
    return false
end

function FastReader:onCloseDocument()
    -- Clean up when document is closed
    self:stopRSVP()
    self.enabled = false
end

function FastReader:onExit()
    -- Clean up when exiting
    self:stopRSVP()
end

function FastReader:setupTapHandler()
    -- Always register the tap handler, but check settings in the handler itself
    self.ui:registerTouchZones({
        {
            id = "fastreader_tap_to_launch",
            ges = "tap",
            screen_zone = {
                ratio_x = 0, ratio_y = 0, 
                ratio_w = 1, ratio_h = 1,  -- Full screen
            },
            overrides = {
                -- Override specific tap handlers to intercept taps on text
                "readerhighlight_tap",
                "tap_top_left_corner",
                "tap_top_right_corner", 
                "tap_left_bottom_corner",
                "tap_right_bottom_corner",
                "tap_forward",
                "tap_backward",
            },
            handler = function(ges)
                return self:onTapToLaunchRSVP(ges)
            end,
        },
    })
    
    logger.info("FastReader: Tap handler registered for RSVP launch")
end

function FastReader:onTapToLaunchRSVP(ges)
    -- Only handle if tap-to-launch is enabled and RSVP is not already running
    if not self.tap_to_launch_enabled or self.rsvp_enabled then
        return false -- Let other handlers process this
    end
    
    -- Check if we tapped on text area (similar to dictionary mode)
    local pos = self:isTapOnTextArea(ges)
    if pos then
        logger.info("FastReader: Tap on text area detected, launching RSVP from tapped word")
        self:startRSVP({ start_pos = pos })
        return true -- Consumed the tap, prevent other handlers
    end
    
    return false -- Let other handlers process this tap
end

function FastReader:isTapOnTextArea(ges)
    -- More sophisticated check based on DictionaryMode approach
    local Screen = require("device").screen
    local x, y = ges.pos.x, ges.pos.y
    
    -- Exclude UI areas (similar margins as used in KOReader)
    local ui_margin = Screen:scaleBySize(30)
    local footer_height = self.ui.view.footer_visible and self.ui.view.footer:getHeight() or 0
    
    -- Check if tap is in main reading area
    if x > ui_margin and x < (Screen:getWidth() - ui_margin) and 
       y > ui_margin and y < (Screen:getHeight() - footer_height - ui_margin) then
        
        -- Additional check: try to get text at tap position to confirm it's over text
        if self.ui.document and self.ui.view then
            local pos = self.ui.view:screenToPageTransform(ges.pos)
            if pos then
                -- do_not_draw_selection: avoid leaving a crengine selection highlight
                local text_result = self.ui.document:getTextFromPositions(pos, pos, true)
                if text_result and text_result.text and text_result.text:match("%S") then
                    -- We have non-whitespace text at this position
                    return pos
                end
            end
        end
    end

    return nil
end

-- Find the index in self.words of the word at a page position (from screenToPageTransform).
-- Counts words in the text from the top of the page up to the position, then checks
-- the result against the word under the finger. Returns nil if it can't be determined.
function FastReader:getWordIndexAtPosition(pos)
    if not pos or #self.words == 0 then
        return nil
    end

    local ok, idx = pcall(function()
        local doc = self.ui.document
        local prefix
        if self.ui.paging then
            prefix = doc:getTextFromPositions({x = 0, y = 0, page = pos.page}, pos)
        else
            prefix = doc:getTextFromPositions({x = 0, y = 0}, pos, true)
        end
        if not prefix or not prefix.text then
            return nil
        end

        local index = #splitWords(prefix.text)
        index = math.max(1, math.min(index, #self.words))

        -- Verify against the word under the finger; search nearby if the counts drifted
        local wordbox = doc:getWordFromPosition(pos, true)
        -- Compare without punctuation: the document's word under the finger may not include it
        local tapped = wordbox and wordbox.word and stripPunctuation(wordbox.word)
        local function matches(i)
            return self.words[i] ~= nil and stripPunctuation(self.words[i]) == tapped
        end
        if tapped and tapped ~= "" and not matches(index) then
            for offset = 1, 3 do
                if matches(index - offset) then
                    return index - offset
                elseif matches(index + offset) then
                    return index + offset
                end
            end
        end
        return index
    end)

    if ok then
        return idx
    end
    logger.warn("FastReader: Could not locate tapped word: " .. tostring(idx))
    return nil
end

function FastReader:getCurrentPageHash()
    -- Create a hash to identify current page content and position
    local hash_data = ""
    
    if self.ui.paging then
        -- For paged documents, use page number
        hash_data = "page_" .. tostring(self.ui.paging.current_page)
    elseif self.ui.rolling then
        -- For rolling documents, use xpointer or position
        local xpointer = self.ui.rolling:getBookLocation()
        hash_data = "rolling_" .. tostring(xpointer or "unknown")
    end
    
    -- Add document file path to make hash unique per document
    if self.ui.document and self.ui.document.file then
        hash_data = hash_data .. "_" .. self.ui.document.file
    end
    
    return hash_data
end

function FastReader:shouldResumeFromLastPosition()
    local current_hash = self:getCurrentPageHash()
    return self.last_page_hash == current_hash and self.last_word_index > 1
end

function FastReader:updateLastReadPosition()
    self.last_page_hash = self:getCurrentPageHash()
    self.last_word_index = self.current_word_index
    logger.info("FastReader: Updated last read position to word " .. self.last_word_index)
end

function FastReader:showPositionIndicator()
    if not self.show_position_indicator or self.current_word_index <= 1 then
        return
    end
    
    -- Hide any existing indicator first
    self:hidePositionIndicator()
    
    -- Create a small indicator showing reading progress
    local progress_text = string.format("📖 %d/%d", self.current_word_index, #self.words)
    local percentage = math.floor((self.current_word_index / #self.words) * 100)
    
    local indicator_widget = TextWidget:new{
        text = progress_text,
        face = Font:getFace("cfont", 16),
        fgcolor = Blitbuffer.COLOR_WHITE,
    }
    
    local indicator_frame = FrameContainer:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        bordersize = 1,
        padding = 4,
        margin = 0,
        radius = 4,
        indicator_widget,
    }
    
    -- Position in top-right corner
    local Screen = require("device").screen
    local margin = Screen:scaleBySize(10)
    
    self.position_indicator_widget = OverlapGroup:new{
        dimen = Geom:new{
            x = Screen:getWidth() - indicator_frame:getSize().w - margin,
            y = margin,
            w = indicator_frame:getSize().w,
            h = indicator_frame:getSize().h,
        },
        indicator_frame,
    }
    
    UIManager:show(self.position_indicator_widget, "ui", self.position_indicator_widget.dimen)
    UIManager:forceRePaint()
    
    -- Auto-hide after 3 seconds
    if self.indicator_timer then
        UIManager:unschedule(self.indicator_timer)
        self.indicator_timer = nil
    end
    self.indicator_timer = function()
        self.indicator_timer = nil
        self:hidePositionIndicator()
    end
    UIManager:scheduleIn(3, self.indicator_timer)
end

function FastReader:hidePositionIndicator()
    if self.position_indicator_widget then
        local refresh_region = self.position_indicator_widget.dimen
        UIManager:close(self.position_indicator_widget, "ui", refresh_region)
        self.position_indicator_widget = nil
        UIManager:forceRePaint()
    end
    
    if self.indicator_timer then
        UIManager:unschedule(self.indicator_timer)
        self.indicator_timer = nil
    end
end

return FastReader
