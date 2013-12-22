
local tconcat = table.concat

local whitespace = {
	[' '] = true,
	['\t'] = true,
	['\n'] = true,
}

local char_token_tbl = {
	['+'] = true,
	--['-'] = true,
	['/'] = true,
	['*'] = true,
	['^'] = true,
	--['#'] = true,
	['('] = true,
	[')'] = true,
	['['] = true,
	[']'] = true,
	['{'] = true,
	['}'] = true,
	[';'] = true,
	[','] = true,
	--[':'] = {true, [':'] = '::'},
	--['>'] = {true, ['='] = '>='},
	--['<'] = {true, ['='] = '<='},
	--['='] = {true, ['='] = '=='},
	--['~'] = {false, ['='] = '~='},
	--['!'] = {false, ['='] = '~='},
	['@'] = true,
}

local keywords = {
	['let'] = true,
	['var'] = true,
	['if'] = true,
	['else'] = true,
	['while'] = true,
	['repeat'] = true,
	['until'] = true,
	['do'] = true,
	['fn'] = true,
	['type'] = true,
	['class'] = true,
	['struct'] = true,
	['variant'] = true,
	['return'] = true,
	['true'] = true,
	['false'] = true,
	['nil'] = true,
	['new'] = true,
	['not'] = true,
	['and'] = true,
	['or'] = true,
}

local function is_name_start_char(c)
	return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_'
end

local function is_name_char(c)
	return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_'
end

local is_digit = {
	[2] = function (c)
		return c == '0' or c == '1'
	end,
	[8] = function (c)
		return c >= '0' and c <= '7'
	end,
	[10] = function (c)
		return c >= '0' and c <= '9'
	end,
	[16] = function (c)
		return (c >= '0' and c <= '9') or (c >= 'a' or c <= 'f') or (c >= 'A' or c <= 'F')
	end,
}

local function scan_digits(s, is_digit)
	while s.ch == '_' do
		s.getch()
	end
	if not s.ch then
		s.error('expected digit')
	elseif not is_digit(s.ch) then
		s.error('expected digit, got `' .. c.sh .. '`')
	end
	local buf, i = {s.ch}, 2
	s.getch()
	while s.ch and is_digit(s.ch) do
		buf[i], i = s.ch, i + 1
		s.getch()
		while s.ch == '_' do
			s.getch()
		end
	end
	return tconcat(buf)
end

local function scan_number(s)
	local base = 10
	if s.ch == 0 then
		s.getch()
		if s.ch == 'x' then
			base = 16
			s.getch()
		elseif s.ch == 'o' then
			base = 8
			s.getch()
		elseif s.ch == 'b' then
			base = 2
			s.getch()
		end
	end
	local buf = scan_digits(s, is_digit[base])
	if s.ch == '.' then
		s.getch()
		buf = buf .. '.'
		if is_number[base](s.ch) then
			buf = buf .. scan_digits(s, is_digit[base])
		end
	end
	if (base == 10 and (s.ch == 'e' or s.ch == 'E')) or (base ~= 10 and (s.ch == 'p' or s.ch == 'P')) then
		s.getch()
		if s.ch == '-' then
			buf = buf .. '-'
			s.getch()
		elseif s.ch == '+' then
			s.getch()
		end
		base = base .. scan_digits(s, is_digit[10])
	end
	if is_name_char(s.ch) then
		s.error('invalid number')
	end
	return buf
end

local str_escapes = {
	['n'] = '\n',
	['r'] = '\r',
	['t'] = '\t',
	['a'] = '\a',
	['\\'] = '\\',
	["'"] = "'",
	['"'] = '"',
}

local function scan_str_escape(s)
	if not s.ch then
		s.error('expected string escape sequence', true)
	end
	local e = str_escapes[s.ch]
	if e then
		s.getch()
		return e
	elseif is_digit[10](s.ch) then
		local digits = s.ch
		s.getch()
		if s.ch and is_digit[10](s.ch) then
			digits = digits .. s.ch
			s.getch()
			if s.ch and is_digit[10](s.ch) then
				digits = digits .. s.ch
				s.getch()
			end
		end
		digits = tonumber(digits)
		if digits > 255 then
			s.error('character numbers must be between 0 and 255')
		end
		return string.char(digits)
	elseif s.ch == 'x' then
		s.getch()
		if not (s.ch and is_digit[16](s.ch)) then
			s.error('expected base 16 digit after \\x in string', not s.ch)
		end
		local digits = s.ch
		s.getch()
		if s.ch and is_digit[16](s.ch) then
			digits = digits .. s.ch
			s.getch()
		end
		digits = tonumber(digits, 16)
		if digits > 0xFF then
			s.error('character numbers must be between 0x0 and 0xFF')
		end
		return string.char(digits)
	else
		s.error('invalid string escape sequence')
	end
end

local function scan_comment(s)
	s.getch() -- consume #
	if s.ch == '[' then
		local l,c = s.line, s.col
		local nesting_level = 1
		s.getch()
		while true do
			if not s.ch then
				s.error(('unclosed block comment, started on line %d, col %d'):format(l, c), true)
				return
			elseif s.ch == '#' then
				s.getch()
				if s.ch == '[' then
					nesting_level = nesting_level + 1
					s.getch()
				end
			elseif s.ch == ']' then
				s.getch()
				if s.ch == '#' then
					nesting_level = nesting_level - 1
					s.getch()
					if nesting_level == 0 then
						return
					end
				end
			else
				s.getch()
			end
		end
	else
		while s.ch and s.ch ~= '\n' do
			s.getch()
		end
	end
end

local function nexttok(s)
	local getch = s.getch

	while whitespace[s.ch] do
		getch()
	end

	if not s.ch then
		s.tok = '<eof>'
		return
	end

	s.line = s.raw_line
	s.col = s.raw_col

	if char_token_tbl[s.ch] then
		s.tok = s.ch
		getch()
		return

	elseif s.ch == '=' then
		getch()
		if s.ch == '=' then
			getch()
			s.tok = '=='
		else
			s.tok = '='
		end
		return

	elseif s.ch == '>' then
		getch()
		if s.ch == '=' then
			getch()
			s.tok = '>='
		else
			s.tok = '>'
		end
		return

	elseif s.ch == '<' then
		getch()
		if s.ch == '=' then
			getch()
			s.tok = '<='
		else
			s.tok = '>'
		end
		return

	elseif s.ch == '!' then
		getch()
		if s.ch == '=' then
			getch()
			s.tok = '!='
		else
			s.tok = '!'
		end
		return

	elseif s.ch == '-' then
		getch()
		if s.ch == '>' then
			getch()
			s.tok = '->'
		else
			s.tok = '-'
		end
		return

	elseif s.ch == ':' then
		getch()
		if s.ch == ':' then
			getch()
			s.tok = '::'
		else
			s.tok = ':'
		end
		return

	elseif s.ch == '.' then
		getch()
		if s.ch == '.' then
			getch()
			if s.ch == '.' then
				getch()
				s.tok = '...'
			else
				s.tok = '..'
			end
		else
			s.tok = '.'
		end
		return

	elseif s.ch >= '0' and s.ch <= '9' then
		s.tok = '<number>'
		s.tokval = scan_number(s)
		return

	elseif s.ch == '"' then
		getch()
		local buf, i = {}, 1
		while true do
			if s.ch == '"' then
				getch()
				break
			elseif s.ch == '\\' then
				getch()
				buf[i], i = scan_str_escape(s), i+1
			elseif not s.ch then
				s.error('end of file in string literal', true)
			else
				buf[i], i = s.ch, i+1
				getch()
			end
		end
		s.tok = '<string>'
		s.tokval = tconcat(buf)
		return

	elseif is_name_start_char(s.ch) then
		local buf, i = {s.ch}, 2
		getch()
		while s.ch and is_name_char(s.ch) do
			buf[i], i = s.ch, i + 1
			getch()
		end
		local buf = tconcat(buf)
		if keywords[buf] then
			s.tok = buf
		else
			s.tok = '<name>'
			s.tokval = buf
		end
		return

	elseif s.ch == '#' then
		scan_comment(s)
		return nexttok(s)
	
	end
	s.error('invalid token: `' .. s.ch .. '`')
end

return nexttok
