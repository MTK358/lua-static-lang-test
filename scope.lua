
local scope_mt = {}
scope_mt.__index = scope_mt

--[[
class Variable (
	type: Type;
	parts: [String];
);

class VariableScope (
	info: Varaible;
	initialized: Bool;
);

class Scope (
	parent: Scope;
	vars: {String: VariableScope};

	fn new(parent: Scope) (
		@parent = parent;
		@vars = {};
	)

	fn declare_var(name: String, type: Type, init: Bool) (
		@vars[name] = new VariableScope(new Variable(type), init);
	)

	fn get_var(name: String) (
		@vars[name]
	)

	fn initialize_var(name: String, v: Variable) (
		@vars[name] = new VariableScope(v, true);
	)

	fn declare_type(name: String, ty: Type) (
		@parent:add_typedef(name, ty);
	)

	fn 
);

class BlockScope : Scope (
   types: {String: Type};

	fn new(parent: Scope) (
		super(parent);
		@types = {};
	)

	fn add_typedef(name: Stringm ty: Type) -> () ( @types[name] = ty; )
);
--]]

local function new_scope(parent, block)
	local self = setmetatable({
		parent = parent,
		vars = {},
		children = {},
		block = block,
	}, scope_mt)
	if block then
		self.types = {}
	end
	if parent then
		parent.children[self] = true
	end
	return self
end

function scope_mt:declare_var(name, ty, is_init)
	self.vars[name] = {
		v = {ty = ty},
		init = init,
	}
end

function scope_mt:get_var(name)
	local v = self.vars[name]
	if (not v) and self.parent then
		return self.parent:get_var(name)
	end
	return v
end

function scope_mt:initialize_var(name, v)
	self.vars[name] = {v = v, init = true}
end

function scope_mt:add_typedef(name, ty)
	local p = self
	repeat
		local types = p.types
		p = p.parent
	until types
	types[name] = ty
end

function scope_mt:get_named_type(name)
	local ty = self.types[name]
	if (not ty) and self.parent then
		return self.parent:get_named_type(name)
	end
	return ty
end

function scope_mt:merge(s, list)
	-- TODO handle conflicting var names
	for i, sub in ipairs(list) do
		for name, v in pairs(sub.vars) do
			self.vars[name] = v
		end
		for name, v in pairs(sub.types) do
			self.types[name] = v
		end
	end
end

return new_scope

