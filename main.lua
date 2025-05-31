local LABEL_KEYS = "asdfghjklqwertyuiopzxcvbnmABCDEFGHIJKLMNOPQRSTUVWXYZ"

local set_use_regex = ya.sync(function(state, flag)
	state.use_regex = flag
end)
local get_use_regex = ya.sync(function(state)
	return state.use_regex
end)

-- INFO: Find all match positions (literal or regex) in lowercase
local function find_positions(filename, pattern)
	if not pattern or pattern == "" then
		return nil, nil
	end
	local name = filename:lower()
	local pat = pattern:lower()
	local starts, ends = {}, {}
	local i = 1
	if not get_use_regex() then
		while true do
			local s, e = string.find(name, pat, i, true)
			if not s then
				break
			end
			starts[#starts + 1] = s
			ends[#ends + 1] = e
			i = e + 1
		end
	else
		while true do
			local s, e = string.find(name, pat, i)
			if not s then
				break
			end
			starts[#starts + 1] = s
			ends[#ends + 1] = e
			i = e + 1
		end
	end
	if #starts == 0 then
		return nil, nil
	end
	return starts, ends
end

-- INFO: Return first label key from state.matches
local get_first_label = ya.sync(function(state)
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

-- INFO: Build UI spans—highlight matches and insert label overlays
local function build_spans(url, name, file, state)
	local info = state.matches[url]
	local starts, ends, keys = info.starts, info.ends, info.keys
	local spans = {}

	-- Text before the first match
	if file.is_hovered then
		spans[#spans + 1] = ui.Span(name:sub(1, starts[1] - 1))
	else
		spans[#spans + 1] = ui.Span(name:sub(1, starts[1] - 1)):fg(state.color_unmatched)
	end

	for i = 1, #starts do
		-- matched substring
		spans[#spans + 1] = ui.Span(name:sub(starts[i], ends[i])):fg(state.color_match_fg):bg(state.color_match_bg)

		-- label after match
		if keys[i] then
			spans[#spans + 1] = ui.Span(keys[i]):fg(state.color_label_fg):bg(state.color_label_bg)
		end

		-- text between this match and the next (or end of name)
		local next_start = (i < #starts and starts[i + 1] - 1) or #name
		local seg_start = ends[i] + 1
		if seg_start <= next_start then
			local segment = name:sub(seg_start, next_start)
			if file.is_hovered then
				spans[#spans + 1] = ui.Span(segment)
			else
				spans[#spans + 1] = ui.Span(segment):fg(state.color_unmatched)
			end
		end
	end

	return spans
end

-- INFO: Scan a folder for matches, populate state.matches
local function scan_folder(pane, folder, pattern, state)
	if not folder then
		return
	end
	for idx, file in ipairs(folder.window) do
		local fname = file.name:gsub("\r", "?", 1)
		local url = tostring(file.url)
		local s, e = find_positions(fname, pattern)
		if s then
			state.matches[url] = {
				starts = s,
				ends = e,
				keys = {},
				is_dir = file.cha.is_dir,
				pane = pane,
				cursor = idx,
			}
		end
	end
end

-- INFO: Record all matches across panes and assign label keys
local record_all_matches = ya.sync(function(state, patterns)
	state.matches = {}
	local found = false

	for _, pat in ipairs(patterns) do
		scan_folder("current", cx.active.current, pat, state)
		if not state.only_current then
			scan_folder("parent", cx.active.parent, pat, state)
			scan_folder("preview", cx.active.preview.folder, pat, state)
		end
	end

	-- build valid label list (skip uppercase if !enable_caps)
	local valid = {}
	for i = 1, #LABEL_KEYS do
		local c = LABEL_KEYS:sub(i, i)
		if state.enable_caps or c:byte() > 96 then
			valid[#valid + 1] = c
		end
	end

	-- assign keys
	local label_idx = 1
	for _, info in pairs(state.matches) do
		found = true
		for _ = 1, #info.starts do
			info.keys[#info.keys + 1] = valid[label_idx]
			label_idx = label_idx + 1
		end
	end

	if cx.active.preview.folder then
		ya.mgr_emit("peek", { force = true })
	end
	ya.render()
	return found
end)

-- INFO: Toggle the overlay UI on/off
local toggle_overlay = ya.sync(function(state)
	if state.overlay_on then
		Status:children_remove(state.status_id)
		Entity.highlights = state.saved_highlights
		state.overlay_on = nil
		state.status_id = nil
		if cx.active.preview.folder then
			ya.mgr_emit("peek", { force = true })
		end
		ya.render()
		return
	end

	state.saved_highlights = Entity.highlights
	state.overlay_on = true

	Entity.highlights = function(self)
		local file = self._file
		local name = file.name:gsub("\r", "?", 1)
		local url = tostring(file.url)
		if state.matches and state.matches[url] then
			return ui.Line(build_spans(url, name, file, state))
		elseif file.is_hovered then
			return ui.Line({ ui.Span(name) })
		else
			return ui.Line({ ui.Span(name):fg(state.color_unmatched) })
		end
	end

	local function render_status()
		local style = Status:style()
		local txt = ""
		if state.search_pattern ~= "" and state.show_status then
			txt = ":" .. state.search_pattern
		end
		return ui.Line({ ui.Span("[SJ]" .. txt .. " "):style(style.main) })
	end

	state.status_id = Status:children_add(render_status, 1001, Status.LEFT)
	if cx.active.preview.folder then
		ya.mgr_emit("peek", { force = true })
	end
end)

-- NOTE: Return matched URL if key matches an assigned label
local match_label_key = ya.sync(function(state, key)
	if state.backspace_flag then
		state.backspace_flag = nil
		return nil
	end
	if not state.matches then
		return nil
	end
	for url, info in pairs(state.matches) do
		for _, lbl in ipairs(info.keys) do
			if lbl == key then
				return url
			end
		end
	end
	return nil
end)

-- INFO: Handle one keypress—jump if label matched, else re‐scan
local handle_input = ya.sync(function(state, patterns, key)
	local url = match_label_key(key)
	if url then
		local info = state.matches[url]
		if not state.autocd and info.pane == "current" then
			local f = cx.active.current
			local offset = info.cursor - f.cursor - 1 + f.offset
			ya.mgr_emit("arrow", { offset })
		elseif state.autocd and info.is_dir then
			ya.mgr_emit("cd", { url })
		else
			ya.mgr_emit("reveal", { url })
		end
		return true, true
	end

	state.matches = nil
	local found = record_all_matches(patterns)
	ya.render()
	if not found and (state.use_regex or patterns[1] ~= "") and state.auto_exit then
		return true, found
	end
	return false, found
end)

-- INFO: Clear transient state and redraw
local clear_state = ya.sync(function(state)
	state.matches = nil
	state.backspace_flag = nil
	state.search_pattern = ""
	ya.render()
end)

-- INFO: Initialize Flash.nvim–style colors
local init_defaults = ya.sync(function(state)
	state.color_match_fg = "#FFFFFF"
	state.color_match_bg = "#3E68D7"
	state.color_label_fg = "#FFFFFF"
	state.color_label_bg = "#FF007C"
	state.color_unmatched = "#515879"
	state.only_current = state.only_current or false
	state.search_pattern = ""
	state.show_status = state.show_status or false
	state.auto_exit = (state.auto_exit == nil) and true or state.auto_exit
	state.enable_caps = state.enable_caps or false
	return state.search_pattern
end)

-- FIX: Backspace handler—remove last char, set flag
local handle_backspace = ya.sync(function(state, cur)
	local last = cur:sub(-2, -2)
	local nxt = cur:sub(1, -2)
	state.backspace_flag = true
	state.search_pattern = nxt
	ya.render()
	return nxt, last
end)

-- INFO: Update status‐bar with current input
local update_statusbar = ya.sync(function(state, cur)
	state.search_pattern = get_use_regex() and "[~]" or cur
	ya.render()
end)

-- INFO: Parse “autocd” argument
local parse_arguments = ya.sync(function(state, args)
	state.autocd = (args[1] == "autocd")
end)

return {
	setup = function(state, opts)
		if opts then
			state.only_current = opts.only_current or state.only_current
			state.show_status = opts.show_status or state.show_status
			state.auto_exit = opts.auto_exit or state.auto_exit
			state.enable_caps = opts.enable_caps or state.enable_caps
		end
	end,

	entry = function(_, job)
		init_defaults()
		parse_arguments(job.args)
		toggle_overlay()

		local cur = ""
		local patterns = {}
		local last_key = ""

		-- Keys to watch
		local KEYS_LIST = {
			"<Esc>",
			"<Enter>",
			"<Space>",
			"<Backspace>",
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
		}
		local CANDS = {}
		for _, k in ipairs(KEYS_LIST) do
			CANDS[#CANDS + 1] = { on = k }
		end

		while true do
			local idx = ya.which({ cands = CANDS, silent = true })
			if not idx then
				goto continue
			end

			local key = KEYS_LIST[idx]
			if key == "<Esc>" then
				break
			elseif key == "<Enter>" then
				last_key = get_first_label()
				patterns = { "" }
			elseif key == "<Space>" then
				last_key = ""
				cur = ""
				patterns = { "" }
				set_use_regex(true)
			elseif key == "<Backspace>" then
				cur, last_key = handle_backspace(cur)
				patterns = { cur }
				set_use_regex(false)
			else
				last_key = key
				cur = cur .. string.lower(key)
				patterns = { cur }
				set_use_regex(false)
			end

			::reset::
			update_statusbar(cur)
			local exit_loop, found = handle_input(patterns, last_key)
			if exit_loop then
				break
			end

			if not found and get_use_regex() then
				break
			elseif not found and cur ~= "" then
				cur, last_key = handle_backspace(cur)
				patterns = { cur }
				goto reset
			end

			::continue::
		end

		clear_state()
		toggle_overlay()
	end,
}
