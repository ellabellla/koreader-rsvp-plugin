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

-- Split text into words, keeping their punctuation. Standalone ellipses and
-- dashes ("wait . . ." / "said —") are attached to the previous word; other
-- punctuation-only tokens are dropped. Shared by page extraction and
-- tap-position lookup so word indices agree.
local function splitWords(text)
    local words = {}
    if type(text) ~= "string" then
        return words
    end
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
        self.settings:flush()
    end
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

local function getOptimalRecognitionIndex(char_count)
    if char_count <= 1 then
        return 1
    elseif char_count == 2 then
        return 1
    elseif char_count == 3 then
        return 2
    elseif char_count == 4 then
        return 2
    elseif char_count == 5 then
        return 3
    elseif char_count == 6 then
        return 3
    elseif char_count == 7 then
        return 4
    elseif char_count == 8 then
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
    local fixed_height = Screen:scaleBySize(120)
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

    local base_font_name = self.plugin.ovp_alignment_enabled and "infont" or "cfont"
    self.anchor_face = Font:getFace(base_font_name, 28)
    self.secondary_face = Font:getFace(base_font_name, 24)

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
        self.plugin:stopRSVP()
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
    self.plugin:stopRSVP()
    return true
end

function RSVPWidget:freeWidgets()
    if self.word_widgets then
        for _, w in ipairs(self.word_widgets) do
            w:free()
        end
        self.word_widgets = {}
    end
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

    -- Words keep their punctuation only when punctuation pauses are enabled
    local show_punctuation = self.plugin.punctuation_pause_enabled
    local function displayWord(word)
        return show_punctuation and word or stripPunctuation(word)
    end

    local current_word = displayWord(self.words[self.current_index])
    local preview_count = self.plugin.words_preview_count or 3

    -- Gather preview words (current + next words)
    local preview_words = {}
    for i = 0, preview_count - 1 do
        local idx = self.current_index + i
        if idx <= #self.words then
            table.insert(preview_words, displayWord(self.words[idx]))
        end
    end

    local anchor_face = self.anchor_face
    local inter_word_gap = self.inter_word_gap
    local min_left_padding = Screen:scaleBySize(20)
    local base_right_padding = (preview_count <= 2) and Screen:scaleBySize(140) or Screen:scaleBySize(180)
    base_right_padding = math.max(Screen:scaleBySize(80), math.min(base_right_padding, math.floor(inner_w * 0.6)))

    local anchor_offset = 0
    if self.plugin.ovp_alignment_enabled then
        anchor_offset = calculateAnchorOffset(current_word, anchor_face, true)
    end

    local anchor_target
    if self.plugin.ovp_alignment_enabled then
        local target_limit = Screen:scaleBySize((preview_count <= 2) and 90 or 140)
        anchor_target = math.min(inner_w - base_right_padding, target_limit)
        anchor_target = math.max(anchor_target, Screen:scaleBySize(90))
    else
        anchor_target = math.floor(inner_w / 2)
    end

    local leading_padding
    if self.plugin.ovp_alignment_enabled then
        leading_padding = math.max(anchor_target - anchor_offset, min_left_padding)
    else
        leading_padding = math.max(math.floor((inner_w - base_right_padding) * 0.2), min_left_padding)
    end

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
        local guide_h = Screen:scaleBySize(12)
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
        UIManager:show(self.rsvp_widget, "fast", self.rsvp_widget.box_dimen)
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

function FastReader:scheduleNextTick()
    if self.rsvp_timer then
        UIManager:unschedule(self.rsvp_timer)
        self.rsvp_timer = nil
    end
    local interval = 60 / self.rsvp_speed  -- seconds per word
    if self.punctuation_pause_enabled and endsWithPausePunctuation(self.words[self.current_word_index]) then
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
    self.rsvp_paused = false

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
    self:scheduleNextTick()

    -- Show first word
    self:showRSVPWord(self.words[self.current_word_index])
    
    logger.info("FastReader: RSVP started successfully")
end

function FastReader:stopRSVP()
    if not self.rsvp_enabled then
        return
    end
    
    logger.info("FastReader: Stopping RSVP mode")
    
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
        -- Flash the box region on close to clear ghosting left by the "fast" word refreshes
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

    self.current_word_index = self.current_word_index + 1

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
        self:stopRSVP()
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
        self:stopRSVP()
        return true
    elseif key == "Press" or key == "LPgFwd" then
        self:togglePause()
        return true
    elseif key == "LPgBack" then
        -- Go to previous word
        if self.current_word_index > 1 then
            self.current_word_index = self.current_word_index - 1
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
