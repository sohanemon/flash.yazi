local LABEL_KEYS = "asdfghjklqwertyuiopzxcvbnmABCDEFGHIJKLMNOPQRSTUVWXYZ"

-- Valid input keys (letters, digits, and controls)
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

-- Build { on = KEY } list for ya.which
local INPUT_CANDIDATES = {}
for _, k in ipairs(INPUT_KEYS) do
	INPUT_CANDIDATES[#INPUT_CANDIDATES + 1] = { on = k }
end

-- Safely get a highlight group’s fg/bg as hex (nil if unavailable)
local function hl_hex(group, kind)
	if type(vim) ~= "table" or type(vim.api) ~= "table" or type(vim.api.nvim_get_hl_by_name) ~= "function" then
		return nil
	end
	local ok, tbl = pcall(vim.api.nvim_get_hl_by_name, group, true)
	if not ok or type(tbl) ~= "table" or not tbl[kind] then
		return nil
	end
	return string.format("#%06x", tbl[kind])
end

-- Toggle literal vs regex matching
local set_regex = ya.sync(function(s, flag)
	s.use_regex = flag
end)
local get_regex = ya.sync(function(s)
	return s.use_regex
end)

-- Find all positions of `pat` in `name` (both lowercased)
-- Returns two arrays (starts[], ends[]) or nil,nil if none
local function find_positions(name, pat)
	if not pat or pat == "" then
		return nil, nil
	end
	name, pat = name:lower(), pat:lower()
	local starts, ends = {}, {}
	if not get_regex() then
		local i = 1
		while true do
			local s, e = string.find(name, pat, i, true)
			if not s then
				break
			end
			starts[#starts + 1], ends[#ends + 1] = s, e
			i = e + 1
		end
	else
		local i = 1
		while true do
			local s, e = string.find(name, pat, i)
			if not s then
				break
			end
			starts[#starts + 1], ends[#ends + 1] = s, e
			i = e + 1
		end
	end
	return (#starts > 0) and starts or nil, (#ends > 0) and ends or nil
end

-- Return the first label key from state.matches (or nil)
local first_label = ya.sync(function(s)
	if not s.matches then
		return nil
	end
	for _, info in pairs(s.matches) do
		if #info.keys > 0 then
			return info.keys[1]
		end
	end
	return nil
end)

-- Build UI spans: highlight matched substrings + insert labels
local function build_spans(url, name, file, s)
	local info = s.matches[url]
	local starts = info.start_pos
	local ends = info.end_pos
	local keys = info.keys
	local spans = {}

	-- Text before first match
	if file.is_hovered then
		spans[#spans + 1] = ui.Span(name:sub(1, starts[1] - 1))
	else
		spans[#spans + 1] = ui.Span(name:sub(1, starts[1] - 1)):fg(s.color_unmatched)
	end

	for i = 1, #starts do
		-- matched substring
		spans[#spans + 1] = ui.Span(name:sub(starts[i], ends[i])):fg(s.color_match_fg):bg(s.color_match_bg)

		-- label char
		if keys[i] then
			spans[#spans + 1] = ui.Span(keys[i]):fg(s.color_label_fg):bg(s.color_label_bg)
		end

		-- text between this match and next (or rest of name)
		local next_start = (i < #starts) and (starts[i + 1] - 1) or #name
		local seg_start = ends[i] + 1
		if seg_start <= next_start then
			local seg = name:sub(seg_start, next_start)
			if file.is_hovered then
				spans[#spans + 1] = ui.Span(seg)
			else
				spans[#spans + 1] = ui.Span(seg):fg(s.color_unmatched)
			end
		end
	end

	return spans
end

-- Scan one pane/folder for matches of `pat`, fill s.matches[url]
local function scan_folder(pane, folder, pat, s)
	if not folder then
		return
	end
	for idx, file in ipairs(folder.window) do
		local fname = file.name:gsub("\r", "?", 1)
		local url = tostring(file.url)
		local sp, ep = find_positions(fname, pat)
		if sp then
			s.matches[url] = {
				start_pos = sp,
				end_pos = ep,
				keys = {},
				is_dir = file.cha.is_dir,
				pane = pane,
				cursor = idx,
			}
		end
	end
end

-- Record all matches across current/parent/preview, assign labels
local record_matches = ya.sync(function(s, patterns)
	s.matches = {}
	local found = false

	for _, pat in ipairs(patterns) do
		scan_folder("current", cx.active.current, pat, s)
		if not s.only_current then
			scan_folder("parent", cx.active.parent, pat, s)
			scan_folder("preview", cx.active.preview.folder, pat, s)
		end
	end

	-- Build valid label list, skip uppercase if !enable_caps
	local valid = {}
	for i = 1, #LABEL_KEYS do
		local c = LABEL_KEYS:sub(i, i)
		if s.enable_caps or c:byte() > 96 then
			valid[#valid + 1] = c
		end
	end

	-- Assign keys in order to each match entry
	local idx = 1
	for url, info in pairs(s.matches) do
		found = true
		for _ = 1, #info.start_pos do
			info.keys[#info.keys + 1] = valid[idx]
			idx = idx + 1
		end
	end

	if cx.active.preview.folder then
		ya.mgr_emit("peek", { force = true })
	end
	ya.render()
	return found
end)

-- Toggle highlighting on/off
local toggle_ui = ya.sync(function(s)
	if s.ui_on then
		Status:children_remove(s.status_id)
		Entity.highlights = s.saved_hl
		s.ui_on, s.status_id = nil, nil
		if cx.active.preview.folder then
			ya.mgr_emit("peek", { force = true })
		end
		ya.render()
		return
	end

	s.saved_hl = Entity.highlights
	s.ui_on = true

	Entity.highlights = function(self)
		local file = self._file
		local name = file.name:gsub("\r", "?", 1)
		local url = tostring(file.url)
		if s.matches and s.matches[url] then
			return ui.Line(build_spans(url, name, file, s))
		elseif file.is_hovered then
			return ui.Line({ ui.Span(name) })
		else
			return ui.Line({ ui.Span(name):fg(s.color_unmatched) })
		end
	end

	local function status_line()
		local style = Status:style()
		local txt = ""
		if s.search_pat ~= "" and s.show_status then
			txt = ":" .. s.search_pat
		end
		return ui.Line({ ui.Span("[SJ]" .. txt .. " "):style(style.main) })
	end

	s.status_id = Status:children_add(status_line, 1001, Status.LEFT)
	if cx.active.preview.folder then
		ya.mgr_emit("peek", { force = true })
	end
end)

-- If key matches a label, return that URL; else nil
local match_label = ya.sync(function(s, key)
	if s.backsp then
		s.backsp = nil
		return nil
	end
	if not s.matches then
		return nil
	end
	for url, info in pairs(s.matches) do
		for _, lbl in ipairs(info.keys) do
			if lbl == key then
				return url
			end
		end
	end
	return nil
end)

-- Handle one key: jump on label, else re‐scan matches
local handle_input = ya.sync(function(s, patterns, key)
	local url = match_label(key)
	if url then
		local info = s.matches[url]
		if not s.autocd and info.pane == "current" then
			local f = cx.active.current
			local off = info.cursor - f.cursor - 1 + f.offset
			ya.mgr_emit("arrow", { off })
		elseif s.autocd and info.is_dir then
			ya.mgr_emit("cd", { url })
		else
			ya.mgr_emit("reveal", { url })
		end
		return true, true
	end

	s.matches = nil
	local found = record_matches(patterns)
	ya.render()
	if not found and (s.use_regex or patterns[1] ~= "") and s.auto_exit then
		return true, found
	else
		return false, found
	end
end)

-- Clear transient state
local clear_state = ya.sync(function(s)
	s.matches = nil
	s.backsp = nil
	s.search_pat = ""
	ya.render()
end)

-- Initialize defaults + fetch Flash.nvim colors if possible
local set_defaults = ya.sync(function(s)
	s.color_match_fg = hl_hex("FlashMatch", "foreground") or "#000000"
	s.color_match_bg = hl_hex("FlashMatch", "background") or "#FFD700"
	s.color_label_fg = hl_hex("FlashLabel", "foreground") or "#FFFFFF"
	s.color_label_bg = hl_hex("FlashLabel", "background") or "#FF0000"
	s.color_unmatched = hl_hex("FlashBackdrop", "foreground") or "#888888"
	s.only_current = s.only_current or false
	s.search_pat = ""
	s.show_status = s.show_status or false
	s.auto_exit = (s.auto_exit == nil) and true or s.auto_exit
	s.enable_caps = s.enable_caps or false
	return s.search_pat
end)

-- Handle backspace: drop last char, mark backsp = true, return (new_str, dropped_char)
local backspace = ya.sync(function(s, cur)
	local last = cur:sub(-2, -2)
	local nxt = cur:sub(1, -2)
	s.backsp = true
	s.search_pat = nxt
	ya.render()
	return nxt, last
end)

-- Update status bar text with current input
local update_status = ya.sync(function(s, cur)
	if s.use_regex then
		s.search_pat = "[~]"
	else
		s.search_pat = cur
	end
	ya.render()
end)

-- Parse “autocd” argument
local parse_args = ya.sync(function(s, args)
	s.autocd = (args[1] == "autocd")
end)

return {
	setup = function(s, opts)
		-- Allow override of options (colors come from Flash.nvim by default)
		if opts then
			if opts.only_current ~= nil then
				s.only_current = opts.only_current
			end
			if opts.show_status ~= nil then
				s.show_status = opts.show_status
			end
			if opts.auto_exit ~= nil then
				s.auto_exit = opts.auto_exit
			end
			if opts.enable_caps ~= nil then
				s.enable_caps = opts.enable_caps
			end
		end
	end,

	entry = function(_, job)
		set_defaults()
		parse_args(job.args)

		-- Show the UI overlay
		toggle_ui()

		local cur = ""
		local patterns = {}
		local last_key = ""

		while true do
			local cand = ya.which({ cands = INPUT_CANDIDATES, silent = true })
			if not cand then
				goto cont
			end

			local key = INPUT_KEYS[cand]
			if key == "<Esc>" then
				break
			elseif key == "<Enter>" then
				last_key = first_label()
				patterns = { "" }
			elseif key == "<Space>" then
				last_key = ""
				cur = ""
				patterns = { "" }
				set_regex(true)
			elseif key == "<Backspace>" then
				cur, last_key = backspace(cur)
				patterns = { cur }
				set_regex(false)
			else
				last_key = key
				cur = cur .. string.lower(key)
				patterns = { cur }
				set_regex(false)
			end

			::reset::
			update_status(cur)
			local exit_loop, found = handle_input(patterns, last_key)
			if exit_loop then
				break
			end

			if not found and get_regex() then
				break
			elseif not found and cur ~= "" then
				cur, last_key = backspace(cur)
				patterns = { cur }
				goto reset
			end

			::cont::
		end

		clear_state()
		toggle_ui()
	end,
}
