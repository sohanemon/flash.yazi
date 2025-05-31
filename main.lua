-- Keys used for labeling matches
local LABEL_KEYS = {
	"j",
	"f",
	"d",
	"k",
	"l",
	"h",
	"g",
	"a",
	"s",
	"o",
	"i",
	"e",
	"u",
	"n",
	"c",
	"m",
	"r",
	"p",
	"b",
	"t",
	"w",
	"v",
	"x",
	"y",
	"q",
	"z",
	"I",
	"J",
	"L",
	"H",
	"A",
	"B",
	"Y",
	"D",
	"E",
	"F",
	"G",
	"Q",
	"R",
	"T",
	"U",
	"V",
	"W",
	"X",
	"Z",
	"C",
	"K",
	"M",
	"N",
	"O",
	"P",
	"S",
}

-- All valid input keys (letters, digits, and control keys)
local INPUT_KEYS = {
	"A",
	"B",
	"C",
	"D",
	"E",
	"F",
	"G",
	"H",
	"I",
	"J",
	"K",
	"L",
	"M",
	"N",
	"O",
	"P",
	"Q",
	"R",
	"S",
	"T",
	"U",
	"V",
	"W",
	"X",
	"Y",
	"Z",
	"a",
	"b",
	"c",
	"d",
	"e",
	"f",
	"g",
	"h",
	"i",
	"j",
	"k",
	"l",
	"m",
	"n",
	"o",
	"p",
	"q",
	"r",
	"s",
	"t",
	"u",
	"v",
	"w",
	"x",
	"y",
	"z",
	"0",
	"1",
	"2",
	"3",
	"4",
	"5",
	"6",
	"7",
	"8",
	"9",
	"-",
	"_",
	".",
	"<Esc>",
	"<Space>",
	"<Enter>",
	"<Backspace>",
}

-- Candidate definitions for ya.which
local INPUT_CANDIDATES = {}
for _, key in ipairs(INPUT_KEYS) do
	table.insert(INPUT_CANDIDATES, { on = key })
end

-- Enable or disable “regex” matching mode
local setRegexMatch = ya.sync(function(state, use_regex)
	state.use_regex = use_regex
end)

-- Return current “regex” mode (true = regex, false = literal)
local getRegexMatch = ya.sync(function(state)
	return state.use_regex
end)

-- Find all positions where ‘pattern’ occurs in ‘name’, both lowercased.
-- Returns two arrays: start_positions[] and end_positions[] (byte indices),
-- or nil, nil if no matches at all.
local function findMatchPositions(name, pattern)
	if not pattern or pattern == "" then
		return nil, nil
	end

	name = string.lower(name)
	pattern = string.lower(pattern)

	local starts, ends = {}, {}
	local use_regex = getRegexMatch()

	if not use_regex then
		-- Plain substring matching
		local search_start = 1
		while true do
			-- true → plain (no pattern) search
			local s, e = string.find(name, pattern, search_start, true)
			if not s then
				break
			end
			table.insert(starts, s)
			table.insert(ends, e)
			search_start = e + 1
		end
	else
		-- Regex search
		local search_start = 1
		while true do
			local s, e = string.find(name, pattern, search_start)
			if not s then
				break
			end
			table.insert(starts, s)
			table.insert(ends, e)
			search_start = e + 1
		end
	end

	if #starts > 0 then
		return starts, ends
	else
		return nil, nil
	end
end

-- Return the first label key from state.matches (or nil)
local getFirstMatchLabel = ya.sync(function(state)
	if not state.matches then
		return nil
	end
	for _, info in pairs(state.matches) do
		if #info.keys > 0 then
			return info.keys[1]
		end
	end
	return nil
end)

-- Build UI spans for a single filename (highlights the matched regions,
-- and inserts a label letter after each match).
local function buildSpans(url, name, file, state)
	local info = state.matches[url]
	local starts = info.start_positions
	local ends = info.end_positions
	local keys = info.keys or {}

	local spans = {}

	-- Text before first match
	if file.is_hovered then
		table.insert(spans, ui.Span(name:sub(1, starts[1] - 1)))
	else
		table.insert(spans, ui.Span(name:sub(1, starts[1] - 1)):fg(state.color_unmatched))
	end

	for i = 1, #starts do
		-- The matched substring
		table.insert(spans, ui.Span(name:sub(starts[i], ends[i])):fg(state.color_match_text):bg(state.color_match_bg))

		-- Insert the label key immediately after the match
		if keys[i] then
			table.insert(spans, ui.Span(keys[i]):fg(state.color_label_text):bg(state.color_label_bg))
		end

		-- Text between this match and the next (or after the last match)
		if i + 1 <= #starts then
			if file.is_hovered then
				table.insert(spans, ui.Span(name:sub(ends[i] + 1, starts[i + 1] - 1)))
			else
				table.insert(spans, ui.Span(name:sub(ends[i] + 1, starts[i + 1] - 1)):fg(state.color_unmatched))
			end
		else
			if file.is_hovered then
				table.insert(spans, ui.Span(name:sub(ends[i] + 1)))
			else
				table.insert(spans, ui.Span(name:sub(ends[i] + 1)):fg(state.color_unmatched))
			end
		end
	end

	return spans
end

-- Scan one folder’s file list and populate state.matches[url] if ‘pattern’ matches that filename.
local function updateMatchesInFolder(pane_name, folder, pattern, state)
	if not folder then
		return
	end

	for idx, file in ipairs(folder.window) do
		local filename = file.name:gsub("\r", "?", 1)
		local url = tostring(file.url)
		local s_pos, e_pos = findMatchPositions(filename, pattern)
		if s_pos then
			state.matches[url] = {
				keys = {},
				start_positions = s_pos,
				end_positions = e_pos,
				is_dir = file.cha.is_dir,
				pane = pane_name,
				cursor_index = idx,
			}
		end
	end
end

-- Populate state.matches with *all* matches across current, parent, and preview panes.
-- Returns true if any match was found.
local recordMatchedFiles = ya.sync(function(state, patterns)
	state.matches = {}
	local found_any = false

	for _, pat in ipairs(patterns) do
		-- Current pane
		updateMatchesInFolder("current", cx.active.current, pat, state)

		if not state.option_only_current then
			-- Parent pane
			updateMatchesInFolder("parent", cx.active.parent, pat, state)
			-- Preview pane
			updateMatchesInFolder("preview", cx.active.preview.folder, pat, state)
		end
	end

	-- Build a list of valid label keys (skip uppercase if caps‐disabled)
	local valid_labels = {}
	for _, key in ipairs(LABEL_KEYS) do
		if not state.option_enable_caps and key:byte() >= 65 and key:byte() <= 90 then
			-- Skip uppercase if option_enable_caps == false
		else
			table.insert(valid_labels, key)
		end
	end

	-- Assign label keys (in order) to each match entry
	local counter = 1
	for url, info in pairs(state.matches) do
		found_any = true
		for _ = 1, #info.start_positions do
			info.keys[#info.keys + 1] = valid_labels[counter]
			counter = counter + 1
		end
	end

	-- Force‐refresh the preview pane if present
	if cx.active.preview.folder then
		ya.mgr_emit("peek", { force = true })
	end
	ya.render()

	return found_any
end)

-- Show or hide the custom highlighting + status‐bar line
local toggleUI = ya.sync(function(state)
	if state.highlights_active or state.status_id then
		-- Turn it off: restore the original highlight function & remove status bar
		Status:children_remove(state.status_id)
		Entity.highlights = state.saved_highlights
		state.highlights_active = nil
		state.status_id = nil

		if cx.active.preview.folder then
			ya.mgr_emit("peek", { force = true })
		end
		ya.render()
		return
	end

	-- Turn it on: override the highlight function
	state.saved_highlights = Entity.highlights
	state.highlights_active = true

	Entity.highlights = function(self)
		local file = self._file
		local filename = file.name:gsub("\r", "?", 1)
		local url = tostring(file.url)

		if state.matches and state.matches[url] then
			return ui.Line(buildSpans(url, filename, file, state))
		elseif file.is_hovered then
			return ui.Line({ ui.Span(filename) })
		else
			return ui.Line({ ui.Span(filename):fg(state.color_unmatched) })
		end
	end

	-- Add a status‐bar widget showing “:[current_pattern]” if enabled
	local function renderStatus(self)
		local style = self:style()
		local pat_text = ""
		if state.search_pattern and state.option_show_status then
			pat_text = ":" .. state.search_pattern
		end
		return ui.Line({ ui.Span("[SJ]" .. pat_text .. " "):style(style.main) })
	end

	state.status_id = Status:children_add(renderStatus, 1001, Status.LEFT)

	if cx.active.preview.folder then
		ya.mgr_emit("peek", { force = true })
	end
end)

-- If the user just pressed a label‐key, return that URL; otherwise nil.
local findLabelMatch = ya.sync(function(state, key_pressed)
	if state.backspacing then
		state.backspacing = false
		return nil
	end
	if not state.matches then
		return nil
	end
	for url, info in pairs(state.matches) do
		for _, lbl in ipairs(info.keys) do
			if lbl == key_pressed then
				return url
			end
		end
	end
	return nil
end)

-- Handle a finalized key press:
-- • If it matches a label → jump/reveal/cd accordingly, then return (true, true).
-- • Otherwise → re‐compute matches and return (should_exit, found_any).
local handleInput = ya.sync(function(state, patterns, key_pressed)
	local matched_url = findLabelMatch(key_pressed)
	if matched_url then
		local info = state.matches[matched_url]
		if not state.args_autocd and info.pane == "current" then
			-- Move cursor in current pane (supports “select” mode)
			local folder = cx.active.current
			local offset = info.cursor_index - folder.cursor - 1 + folder.offset
			ya.mgr_emit("arrow", { offset })
		elseif state.args_autocd and info.is_dir then
			-- If “autocd” mode is on and it’s a directory → cd into it
			ya.mgr_emit("cd", { matched_url })
		else
			-- Otherwise highlight/reveal that file
			ya.mgr_emit("reveal", { matched_url })
		end
		return true, true
	end

	-- No label match → clear old matches and recompute
	state.matches = nil
	local found_any = recordMatchedFiles(patterns)

	ya.render()
	if not found_any and (state.use_regex or patterns[1] ~= "") and state.option_auto_exit then
		return true, found_any
	else
		return false, found_any
	end
end)

-- Clear all transient search state and redraw
local clearState = ya.sync(function(state)
	state.matches = nil
	state.backspacing = nil
	state.search_pattern = nil
	ya.render()
end)

-- Initialize default colors/options if not set yet
local setDefaultOptions = ya.sync(function(state)
	state.color_unmatched = state.color_unmatched or "#b2a496"
	state.color_match_text = state.color_match_text or "#000000"
	state.color_match_bg = state.color_match_bg or "#73AC3A"
	state.color_label_text = state.color_label_text or "#EADFC8"
	state.color_label_bg = state.color_label_bg or "#BA603D"
	state.option_only_current = state.option_only_current or false
	state.search_pattern = state.search_pattern or ""
	state.option_show_status = state.option_show_status or false
	state.option_auto_exit = (state.option_auto_exit == nil) and true or state.option_auto_exit
	state.option_enable_caps = state.option_enable_caps or false
	return state.search_pattern
end)

-- Backspace: remove the last character of `current_input`, set backspacing=true, and return (new_string, last_char_removed)
local backspaceInput = ya.sync(function(state, current_input)
	local last_char = current_input:sub(-2, -2)
	local new_input = current_input:sub(1, -2)
	state.backspacing = true
	state.search_pattern = new_input
	ya.render()
	return new_input, last_char
end)

-- Update the status‐bar text with the current input
local updateStatusBarInput = ya.sync(function(state, current_input)
	if state.use_regex then
		state.search_pattern = "[~]"
	else
		state.search_pattern = current_input
	end
	ya.render()
end)

-- Parse command‐line args for “autocd”
local setDefaultArgs = ya.sync(function(state, args)
	state.args_autocd = (args[1] == "autocd")
end)

return {
	setup = function(state, opts)
		-- Apply any user‐supplied colors or mode flags
		if opts then
			if opts.color_unmatched then
				state.color_unmatched = opts.color_unmatched
			end
			if opts.color_match_text then
				state.color_match_text = opts.color_match_text
			end
			if opts.color_match_bg then
				state.color_match_bg = opts.color_match_bg
			end
			if opts.color_label_text then
				state.color_label_text = opts.color_label_text
			end
			if opts.color_label_bg then
				state.color_label_bg = opts.color_label_bg
			end
			if opts.only_current ~= nil then
				state.option_only_current = opts.only_current
			end
			if opts.show_status ~= nil then
				state.option_show_status = opts.show_status
			end
			if opts.auto_exit ~= nil then
				state.option_auto_exit = opts.auto_exit
			end
			if opts.enable_caps ~= nil then
				state.option_enable_caps = opts.enable_caps
			end
		end
	end,

	entry = function(_, job)
		-- Initialize defaults & arguments
		setDefaultOptions()
		setDefaultArgs(job.args)

		-- Show the overlay (highlight + status bar)
		toggleUI()

		local input_str = ""
		local patterns = {}
		local last_key = ""

		while true do
			-- Wait for one of the INPUT_CANDIDATES
			local cand = ya.which({ cands = INPUT_CANDIDATES, silent = true })
			if not cand then
				goto continue
			end

			local key = INPUT_KEYS[cand]
			if key == "<Esc>" then
				break
			elseif key == "<Enter>" then
				last_key = getFirstMatchLabel()
				patterns = { "" }
			elseif key == "<Space>" then
				last_key = ""
				input_str = ""
				patterns = { "" }
				setRegexMatch(true)
			elseif key == "<Backspace>" then
				input_str, last_key = backspaceInput(input_str)
				patterns = { input_str }
				setRegexMatch(false)
			else
				last_key = key
				input_str = input_str .. string.lower(key)
				patterns = { input_str }
				setRegexMatch(false)
			end

			::reset::
			updateStatusBarInput(input_str)

			local should_exit, has_match = handleInput(patterns, last_key)
			if should_exit then
				break
			end

			-- If no matches in regex‐mode, exit immediately
			if not has_match and getRegexMatch() then
				break
			elseif not has_match and input_str ~= "" then
				-- If typing yielded zero results, backspace one char automatically
				input_str, last_key = backspaceInput(input_str)
				patterns = { input_str }
				goto reset
			end

			::continue::
		end

		-- Tear down: clear highlights & state
		clearState()
		toggleUI()
	end,
}
