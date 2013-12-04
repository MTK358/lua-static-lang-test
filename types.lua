
local types = {}

local type_mt = {}
type_mt.__index = type_mt

function type_mt:to_str()
	if self.str then
		return self.str

	elseif self.valstruct and self.valstruct.kind == 'tuple' then
		local s = '('
		for i, v in ipairs(self.valstruct.members) do
			if i ~= 1 then s = s .. ',' end
			s = s .. v:to_str()
		end
		return s..')'

	elseif self.valstruct and self.valstruct.kind == 'struct' then
		local s = 'struct('
		for i, v in ipairs(self.valstruct.members) do
			if i ~= 1 then s = s .. ',' end
			s = s .. self.valstruct.member_names[i] .. ':' .. v:to_str()
		end
		return s..')'

	elseif self.cls then
		local s = 'class('
		for i, v in ipairs(self.cls.members) do
			if i ~= 1 then s = s .. ',' end
			s = s .. self.cls.member_names[i] .. ':' .. v:to_str()
		end
		return s..')'

	elseif self.is_function then
		local s = 'fn('
		for i, v in ipairs(self.call.params) do
			if i ~= 1 then s = s .. ',' end
			s = s .. v.ty:to_str()
		end
		return s..'->'..self.call.ret:to_str()..')'

	end
	return '?'
end

function type_mt:resolve_named(s, visited)
	if visited and visited[self] then
		s.error('pass-by-value structures cannot be recursive', false, self.line, self.col)
	end
	if self.names_resolved then return self end

	if self.named then
		local t = self.scope:get_type_from_name(self.named)
		if not t then
			s.error(('no type named `%s` in current scope'):format(self.named), false, self.line, self.col)
		end
		return t:resolve_named(s)

	elseif self.valstruct then
		visited = visited or {}
		visited[self] = true
		for i, v in ipairs(self.valstruct.members) do
			self.valstruct.members[i] = v:resolve_named(s, visited)
		end
		self.names_resolved = true

	elseif self.cls then
		for i, v in ipairs(self.cls.members) do
			self.cls.members[i] = v:resolve_named(s)
		end
		self.names_resolved = true

	end
	return self
end

function type_mt:num_vars()
	if self.valstruct then
		return self.valstruct.num_vars
	else
		return 1
	end
end

function type_mt:equal(other)
	if self.valstruct and other.valstruct and self.valstruct.kind == 'tuple' and other.valstruct.kind == 'tuple' then
		for i, v in ipairs(self.valstruct.members) do
			if not v:equal(other.valstruct.members[i]) then return false end
		end
		return true
	elseif self.is_function and other.is_function then
		if #self.call.params ~= #other.call.params then return false end
		if self.call.vararg ~= other.call.vararg then return false end
		if not self.call.ret:equal(other.call.ret) then return false end
		for i, v in ipairs(self.call.params) do
			if not v.ty:equal(other.call.params[i].ty) then return false end
		end
		return true
	else
		return self == other
	end
end

function type_mt:is_acceptable(other)
	if self.is_acceptable_fn then
		return self:is_acceptable_fn(other)
	else
		return self:equal(other)
	end
end

function types.new_named(name, scope)
	return setmetatable({
		named = name,
		scope = scope,
	}, type_mt)
end

function types.new_function(params, ret, vararg)
	return setmetatable({
		is_function = true,
		call = {
			params = params,
			ret = ret,
			vararg = vararg,
		},
	}, type_mt)
end

function types.new_tuple(members)
	local t = setmetatable({
		valstruct = {
			kind = 'tuple',
			members = members,
			num_members = #members,
			member_offsets = {},
		},
	}, type_mt)
	local prev_offset = 0
	for i, v in ipairs(members) do
		t.valstruct.member_offsets[i] = prev_offset
		prev_offset = prev_offset + t.valstruct.members[i]:num_vars()
	end
	t.valstruct.num_vars = prev_offset
	return t
end

function types.new_struct(members)
	local member_types, member_names, name_to_index = {}, {}, {}
	for i, v in ipairs(members) do
		member_types[i] = members[i].ty
		member_names[i] = members[i].name
		name_to_index[members[i].name] = i
	end
	local t = setmetatable({
		valstruct = {
			kind = 'struct',
			members = member_types,
			num_members = #members,
			member_offsets = {},
			member_names = member_names,
			name_to_index = name_to_index,
		},
	}, type_mt)
	local prev_offset = 0
	for i, v in ipairs(member_types) do
		t.valstruct.member_offsets[i] = prev_offset
		prev_offset = prev_offset + t.valstruct.members[i]:num_vars()
	end
	t.valstruct.num_vars = prev_offset
	return t
end

function types.new_class(members)
	local member_types, member_names, name_to_index = {}, {}, {}
	for i, v in ipairs(members) do
		member_types[i] = members[i].ty
		member_names[i] = members[i].name
		name_to_index[members[i].name] = i
	end
	local t = setmetatable({
		cls = {
			packed = true,
			members = member_types,
			num_members = #members,
			member_offsets = {},
			member_names = member_names,
			name_to_index = name_to_index,
		},
	}, type_mt)
	local prev_offset = 0
	for i, v in ipairs(member_types) do
		t.cls.member_offsets[i] = prev_offset
		prev_offset = prev_offset + t.cls.members[i]:num_vars()
	end
	t.cls.num_vars = prev_offset
	return t
end

types.builtin_bool = setmetatable({
	str = 'bool',
}, type_mt)

types.builtin_int = setmetatable({
	str = 'int',
}, type_mt)

types.builtin_float = setmetatable({
	str = 'float',
}, type_mt)

types.builtin_string = setmetatable({
	str = 'string',
}, type_mt)

types.builtin_void = setmetatable({
	str = '()',
	--valstruct = {kind = 'tuple', num_vars = 0},
	noval = true,
}, type_mt)

types.builtin_noret = setmetatable({
	str = '!',
	noval = true,
}, type_mt)

types.builtin_vararg = setmetatable({
	str = '...',
	is_acceptable_fn = function (self, t)
		return t ~= types.builtin_noret
	end,
}, type_mt)

types.builtin_dynamic = setmetatable({
	str = 'dyn',
	is_acceptable_fn = function (self, t)
		return not (t.valstruct or t.noval)
	end,
}, type_mt)

return types
