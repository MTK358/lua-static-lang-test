
local types = require 'types'

------------------------------------------------------------------------------
-- An object containing an association of names to type objects
------------------------------------------------------------------------------

local typescope_mt = {}
typescope_mt.__index = typescope_mt

function typescope_mt:get_type_from_name(name)
	local t = self.typedefs[name]
	if (not t) and self.parent then
		return self.parent:get_type_from_name(name)
	end
	return t
end

function typescope_mt:add_typedef(name, ty)
	self.typedefs[name] = ty
end

local function typescope(parent)
	return setmetatable({
		parent = parent,
		typedefs = {},
	}, typescope_mt)
end

------------------------------------------------------------------------------
-- Convert type nodes to type objects
------------------------------------------------------------------------------

local builtin_type_names = {
	['int'] = types.builtin_int,
	['float'] = types.builtin_float,
	['string'] = types.builtin_string,
	['bool'] = types.builtin_bool,
	['nil'] = types.builtin_nil,
	['dyn'] = types.builtin_dynamic,
}

local function parse_type_node(s, node)
	if node[1] == 'ty_name' then
		local builtin = builtin_type_names[node[2]]
		if builtin then
			return builtin
		else
			return types.new_named(node[2], s.current_typescope)
		end

	elseif node[1] == 'ty_tuple' then
		if node[2] then
			local tbl = {}
			for i = 2, #node do
				tbl[i - 1] = parse_type_node(s, node[i])
			end
			return types.new_tuple(tbl)
		else
			return types.builtin_void
		end

	elseif node[1] == 'ty_struct' then
		for i, member in ipairs(node[2]) do
			member.ty = parse_type_node(s, member.ty)
		end
		return types.new_struct(node[2])

	elseif node[1] == 'ty_class' then
		for i, member in ipairs(node[2]) do
			member.ty = parse_type_node(s, member.ty)
		end
		return types.new_class(node[2])

	elseif node[1] == 'ty_variant' then
		for i, member in ipairs(node[2]) do
			member.ty = parse_type_node(s, member.ty)
		end
		return types.new_variant(node[2])

	elseif node[1] == 'ty_vararg' then
		return types.builtin_vararg

	elseif node[1] == 'ty_noret' then
		return types.builtin_noret

	end
	error('this should be unreachable')
end

------------------------------------------------------------------------------
-- Find all type nodes and replace them with type objects
------------------------------------------------------------------------------

local read_types_vardecl, read_types_lhs

local read_types_tbl

local function read_types(s, node)
	local f = read_types_tbl[node[1]]
	if f then return f(s, node) end
end

read_types_tbl = {
	['let'] = function (s, node)
		--read_types_vardecl(s, node[2])
		if node[3] then
			node[3] = parse_type_node(s, node[3])
		end
		if node[4] then
			read_types(s, node[4])
		end
	end;

	['var'] = function (s, node)
		--read_types_vardecl(s, node[2])
		if node[3] then
			node[3] = parse_type_node(s, node[3])
		end
		if node[4] then
			read_types(s, node[4])
		end
	end;

	['assign'] = function (s, node)
		read_types_lhs(s, node[2])
		if node[4] then
			read_types(s, node[4])
		end
	end;

	['if'] = function (s, node)
		read_types(s, node[2])
		read_types(s, node[3])
		if node[4] then
			read_types(s, node[4])
		end
	end;

	['repeat'] = function (s, node)
		read_types(s, node[2])
		return read_types(s, node[3])
	end;

	['while'] = function (s, node)
		read_types(s, node[2])
		return read_types(s, node[3])
	end;

	['do'] = function (s, node)
		return read_types(s, node[2])
	end;

	['call'] = function (s, node)
		for i = 2, #node do
			read_types(s, node[i])
		end
	end;

	['function'] = function (s, node)
		-- explicit return type 
		if node[3] then
			node[3] = parse_type_node(s, node[3])
		end
		-- functions contain sub-scopes for type names
		local old = s.current_typescope
		s.current_typescope = typescope(old)
		-- parameters
		local implicit_found, explicit_found = false, false
		for i, v in ipairs(node[2]) do
			if v.ty then
				v.ty = parse_type_node(s, v.ty)
				explicit_found = true
			else
				implicit_found = true
			end
		end
		if explicit_found and implicit_found then
			s.error('either all or none of a function\'s parameters should have explicit types', false, node:get_location())
		end
		node[2].implicit_types = implicit_found
		-- process function body
		read_types(s, node[4])
		-- restore outer scope
		s.current_typescope = old
	end;
	
	['seq'] = function (s, node)
		for i = 2, #node do
			read_types(s, node[i])
		end
	end;

	['binop'] = function (s, node)
		read_types(s, node[2])
		return read_types(s, node[3])
	end;

	['unop'] = function (s, node)
		return read_types(s, node[2])
	end;

	['return'] = function (s, node)
		return read_types(s, node[2])
	end;

	['typedef'] = function (s, node)
		if builtin_type_names[node[2]] then
			s.error(('attempt to redefine built-in type name `%s`'):format(node[2]), false, node:get_location())
		end
		s.current_typescope:add_typedef(node[2], parse_type_node(s, node[3]))
		-- typedefs do not translate to any code, treat it as a `()`
		node[1] = 'void'
	end;

	['new_kv'] = function (s, node)
		node[2] = parse_type_node(s, node[2])
		for i, v in ipairs(node[3]) do
			read_types(s, v.val)
		end
	end;

	['new_variant'] = function (s, node)
		node[2] = parse_type_node(s, node[2])
		if node[4] then
			read_types(s, node[4])
		end
	end;

	['tuple'] = function (s, node)
		for i = 2, #node do
			read_types(s, node[i])
		end
	end;

	['parens'] = function (s, node)
		return read_types(s, node[2])
	end;
}

------------------------------------------------------------------------------
-- Same as above, but for expressions that are used as lvalues
------------------------------------------------------------------------------

local read_types_lhs_tbl

read_types_lhs = function (s, node)
	local f = read_types_lhs_tbl[node[1]]
	if f then
		return f(s, node)
	else
		s.error('invalid lvalue', false, node:get_location())
	end
end

read_types_lhs_tbl = {
	['name'] = function (s, node)
	end;

	['tuple'] = function (s, node)
		for i = 2, #node do
			read_types_lhs(s, node[i])
		end
	end;

	['field'] = function (s, node)
		return read_types_lhs(s, node[2])
	end;
}

------------------------------------------------------------------------------
-- Main function for this pass
------------------------------------------------------------------------------

local function read_types_start(s, root)
	s.current_typescope = typescope()
	read_types(s, root)
	s.current_typescope = nil
	return root
end

return read_types_start

