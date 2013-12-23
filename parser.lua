
local nexttok = require 'lexer'
local ast_node = require 'ast_node'.new_node

local function expect(s, t, msg)
	if s.tok ~= t then
		s.error(msg or ('expected `%s`, got `%s`'):format(t, s.tok), s.tok == '<eof>')
	end
	nexttok(s)
end

local expr_start_tokens = {
	['<number>'] = true,
	['<name>'] = true,
	['<string>'] = true,
	['('] = true,
	['-'] = true,
	['not'] = true,
	['fn'] = true,
	['true'] = true,
	['false'] = true,
	['nil'] = true,
	['if'] = true,
	['while'] = true,
	['repeat'] = true,
	['do'] = true,
	['type'] = true,
	['class'] = true,
	['struct'] = true,
	['variant'] = true,
	['return'] = true,
	['new'] = true,
	['let'] = true,
	['var'] = true,
	['...'] = true,
}

local typedecl_start_tokens = {
	['type'] = true,
	['class']= true,
	['struct'] = true,
}

local nt = {}

function nt.base_expr(s)
	if s.tok == '<number>' then
		local text = s.tokval
		nexttok(s)
		return ast_node(s, 'float', text)

	elseif s.tok == '<name>' then
		local text = s.tokval
		nexttok(s)
		return ast_node(s, 'name', text)

	elseif s.tok == '<string>' then
		local text = s.tokval
		nexttok(s)
		return ast_node(s, 'string', text)

	elseif s.tok == 'true' then
		nexttok(s)
		return ast_node(s, 'boolean', true)

	elseif s.tok == 'false' then
		nexttok(s)
		return ast_node(s, 'boolean', false)

	elseif s.tok == 'nil' then
		nexttok(s)
		return ast_node(s, 'nil')

	elseif s.tok == '(' then
		local l,c = s.line, s.col
		nexttok(s)
		if s.tok == ')' then
			nexttok(s)
			return ast_node(s, 'void')
		end
		local e = nt.seq(s)
		if s.tok == ',' then
			nexttok(s)
			e = ast_node(s, 'tuple', e)
			nt.comma_separated_seq(s, e)
		else
			e = ast_node(s, 'parens', e)
		end
		if s.tok ~= ')' then
			s.error(('expected `)` to close `(` on line %d, col %d'):format(l, c), s.tok=='<eof>')
		end
		nexttok(s)
		return e

	elseif s.tok == 'if' then
		nexttok(s)
		expect(s, '(')
		local cond = nt.seq(s)
		expect(s, ')')
		local true_branch = nt.expr(s)
		local false_branch
		if s.tok == 'else' then
			nexttok(s)
			false_branch = nt.expr(s)
		else
			fale_branch = ast_node(s, 'void')
		end
		return ast_node(s, 'if', cond, true_branch, false_branch)

	elseif s.tok == 'while' then
		nexttok(s)
		expect(s, '(')
		local cond = nt.seq(s)
		expect(s, ')')
		local body = nt.expr(s)
		return ast_node(s, 'while', cond, body)

	elseif s.tok == 'repeat' then
		nexttok(s)
		local body = nt.expr(s)
		expect(s, 'until')
		--expect(s, '(')
		local cond = nt.expr(s)
		--expect(s, ')')
		return ast_node(s, 'repeat', body, cond)

	elseif s.tok == 'do' then
		nexttok(s)
		return ast_node(s, 'do', nt.expr(s))

	elseif s.tok == 'fn' then
		nexttok(s)
		local name = nil
		if s.tok == '<name>' then
			name = s.tokval
			nexttok(s)
		end
		expect(s, '(')
		local params = {}
		local first = true
		while (first and (s.tok == '<name>' or s.tok == '...')) or ((not first) and s.tok == ',') do
			if first then
				first = false
			else
				expect(s, ',')
			end
			if s.tok == '<name>' then
				local param = {name = s.tokval}
				nexttok(s)
				if s.tok == ':' then
					nexttok(s)
					param.ty = nt.tyexpr(s)
				end
				params[#params + 1] = param
			elseif s.tok == '...' then
				nexttok(s)
				params.vararg = true
				break
			else
				s.error('expected parameter name or `...`')
			end
		end
		local rettype = nil
		if s.tok == '->' then
			nexttok(s)
			rettype = nt.tyexpr(s)
		end
		expect(s, ')')
		local body = nt.expr(s)
		local e = ast_node(s, 'function', params, rettype, body)
		if name then
			ast_node(s, 'let', {'name', name}, nil, e, true)
		end
		return e

	elseif s.tok == 'return' then
		nexttok(s)
		return ast_node(s, 'return', nt.expr(s))

	elseif s.tok == 'new' then
		nexttok(s)
		local ty = nt.tyexpr(s)
		if s.tok == '.' then
			nexttok(s)
			local name = s.tokval
			expect(s, '<name>')
			expect(s, '(')
			local val
			if s.tok ~= ')' then
				val = nt.expr(s)
			else
				val = ast_node(s, 'void')
			end
			expect(s, ')')
			return ast_node(s, 'new_variant', ty, name, val)
		end
		expect(s, '{')
		local e = ast_node(s, 'new_kv', ty, {})
		local first = true
		while s.tok ~= '}' do
			if first then
				first = false
			else
				expect(s, ',')
			end
			local name = s.tokval
			expect(s, '<name>')
			expect(s, '=')
			local val = nt.expr(s)
			table.insert(e[3], {name=name, val=val})
		end
		nexttok(s)
		return e

	elseif s.tok == 'type' then
		nexttok(s)
		local name = s.tokval
		nexttok(s)
		expect(s, '=')
		return ast_node(s, 'typedef', name, nt.tyexpr(s))

	elseif s.tok == 'class' then
		nexttok(s)
		local name = s.tokval
		expect(s, '<name>')
		local t = nt.class_tyexpr(s)
		return ast_node(s, 'typedef', name, t)

	elseif s.tok == 'struct' then
		nexttok(s)
		local name = s.tokval
		expect(s, '<name>')
		local t = nt.struct_tyexpr(s)
		return ast_node(s, 'typedef', name, t)

	elseif s.tok == 'variant' then
		nexttok(s)
		local name = s.tokval
		expect(s, '<name>')
		local t = nt.variant_tyexpr(s)
		return ast_node(s, 'typedef', name, t)

	elseif s.tok == '-' then
		nexttok(s)
		return ast_node(s, 'unop', '-', nt.expr(s))

	elseif s.tok == 'not' then
		nexttok(s)
		return ast_node(s, 'unop', 'not', nt.expr(s))

	elseif s.tok == '...' then
		nexttok(s)
		return ast_node(s, 'vararg')

	elseif s.tok == '[' then
		nexttok(s)
		local t
		if s.tok == '>' then
			t = 'quote'
		elseif s.tok == '<' then
			t = 'unquote'
		else
			s.error('expected `>` or `<`')
		end
		nexttok(s)
		local e = nt.seq(s)
		expect(s, ']')
		return ast_node(s, t, e)

	end
	s.error('expected expression, got `' .. s.tok .. '`')
end

function nt.suffix_expr(s)
	local e = nt.base_expr(s)
	while true do
		if s.tok == '.' then
			nexttok(s)
			local text = s.tokval
			expect(s, '<name>')
			e = ast_node(s, 'field', e, text)

		elseif s.tok == '[' then
			nexttok(s)
			local key = nt.expr(s)
			expect(s, ']')
			e = ast_node(s, 'index', e, key)

		elseif s.tok == '(' then
			e = ast_node(s, 'call', e)
			nexttok(s)
			nt.comma_separated_seq(s, e)
			expect(s, ')')

		else
			return e
		end
	end
end

local binops = {
	['or'] = {prec = 10, rassoc = false},
	['and'] = {prec = 20, rassoc = false},
	['=='] = {prec = 25, rassoc = false},
	['!='] = {prec = 25, rassoc = false},
	['>='] = {prec = 25, rassoc = false},
	['<='] = {prec = 25, rassoc = false},
	['>'] = {prec = 25, rassoc = false},
	['<'] = {prec = 25, rassoc = false},
	['..'] = {prec = 30, rassoc = false},
	['+'] = {prec = 40, rassoc = false},
	['-'] = {prec = 40, rassoc = false},
	['*'] = {prec = 50, rassoc = false},
	['/'] = {prec = 50, rassoc = false},
	['^'] = {prec = 60, rassoc = true},
}

function nt.binop_expr(s, min_prec)
	min_prec = min_prec or 0
	local result = nt.suffix_expr(s)
	while true do
		local op_info = binops[s.tok]
		if not (op_info and op_info.prec >= min_prec) then break end
		local op = s.tok
		nexttok(s)
		local next_min_prec = op_info.prec
		if not op_info.rassoc then
			next_min_prec = next_min_prec + 1
		end
		result = ast_node(s, 'binop', op, result, nt.binop_expr(s, next_min_prec))
	end
	return result
end

function nt.assign_expr(s)
	if s.tok == 'let' then
		local node_type = s.tok
		nexttok(s)
		local lval = nt.binop_expr(s)
		local explicit_type = nil
		if s.tok == ':' then
			nexttok(s)
			explicit_type = nt.tyexpr(s)
		end
		expect(s, '=')
		return ast_node(s, 'let', lval, explicit_type, nt.assign_expr(s))
	elseif s.tok == 'var' then
		nexttok(s)
		local lval = nt.binop_expr(s)
		local explicit_type = nil
		if s.tok == ':' then
			nexttok(s)
			explicit_type = nt.tyexpr(s)
		end
		if s.tok == '=' then
			nexttok(s)
			return ast_node(s, 'var', lval, explicit_type, nt.assign_expr(s))
		else
			return ast_node(s, 'var', lval, explicit_type)
		end
	else
		local e = nt.binop_expr(s)
		if s.tok == '=' then
			nexttok(s)
			return ast_node(s, 'assign', e, nil, nt.assign_expr(s))
		end
		return e
	end
end

nt.expr = nt.assign_expr

function nt.seq(s)
	local e = nt.expr(s)
	if s.tok == ';' then
		e = ast_node(s, 'seq', e)
		repeat
			nexttok(s)
			if expr_start_tokens[s.tok] then
				e[#e + 1] = nt.expr(s)
			else
				e[#e + 1] = ast_node(s, 'void')
				break
			end
		until s.tok ~= ';'
	end
	return e
end

function nt.comma_separated_seq(s, e)
	while expr_start_tokens[s.tok] do
		e[#e + 1] = nt.seq(s)
		if s.tok ~= ',' then
			break
		end
		nexttok(s)
	end
end

function nt.comma_separated_tyexpr(s, e)
	while expr_start_tokens[s.tok] do
		e[#e + 1] = nt.tyexpr(s)
		if s.tok ~= ',' then
			break
		end
		nexttok(s)
	end
end

function nt.struct_tyexpr(s)
	local l,c = s.line, s.col
	expect(s, '(')
	local t = {'ty_struct', {}}
	local first = true
	while s.tok ~= ')' do
		if first then
			first = false
		else
			expect(s, ',')
		end
		if s.tok == '<name>' then
			local name = s.tokval
			nexttok(s)
			expect(s, ':')
			local ty = nt.tyexpr(s)
			table.insert(t[2], {name=name, ty=ty})
		else
			expect(s, ')')
		end
	end
	nexttok(s)
	return t;
end

function nt.class_tyexpr(s)
	local l,c = s.line, s.col
	local base = nil
	if s.tok == ':' then
		nexttok(s)
		base = nt.tyexpr(s)
	end
	expect(s, '(')
	local t = {'ty_class', {}, base}
	local first = true
	while s.tok ~= ')' do
		if first then
			first = false
		else
			expect(s, ',')
		end
		if s.tok == '<name>' then
			local name = s.tokval
			nexttok(s)
			expect(s, ':')
			local ty = nt.tyexpr(s)
			table.insert(t[2], {name=name, ty=ty})
		else
			expect(s, ')')
		end
	end
	nexttok(s)
	return t;
end

function nt.variant_tyexpr(s)
	local l,c = s.line, s.col
	expect(s, '(')
	local t = ast_node(s, 'ty_variant', {})
	local first = true
	while s.tok ~= ')' do
		if first then
			first = false
		else
			expect(s, ',')
		end
		if s.tok == '<name>' then
			local name = s.tokval
			nexttok(s)
			local ty
			if s.tok ~= ',' and s.tok ~= ')' then
				ty = nt.tyexpr(s)
			else
				ty = ast_node(s, 'ty_tuple')
			end
			table.insert(t[2], {name=name, ty=ty})
		else
			expect(s, ')')
		end
	end
	nexttok(s)
	return t;
end

function nt.tyexpr(s)
	if s.tok == '<name>' then
		local text = s.tokval
		nexttok(s)
		return ast_node(s, 'ty_name', text)

	elseif s.tok == '(' then
		nexttok(s)
		local t = ast_node(s, 'ty_tuple')
		nt.comma_separated_tyexpr(s, t)
		expect(s, ')')
		return t

	elseif s.tok == 'struct' then
		nexttok(s)
		return nt.struct_tyexpr(s)

	elseif s.tok == 'class' then
		nexttok(s)
		return nt.class_tyexpr(s)

	elseif s.tok == 'variant' then
		nexttok(s)
		return nt.variant_tyexpr(s)

	elseif s.tok == '...' then
		nexttok(s)
		return ast_node(s, 'ty_vararg')

	elseif s.tok == '!' then
		nexttok(s)
		return ast_node(s, 'ty_noret')

	end
	s.error('expected type expression, got `' .. s.tok .. '`')
end

local function parse(s)
	nexttok(s)
	local root = nt.seq(s)
	expect(s, '<eof>')
	return root
end

return parse

