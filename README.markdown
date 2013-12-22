
Attempt to make a statically typed language that compiles to Lua. It's still
messy, missing important features, and likely to have bugs.

In addition to static types, it also has syntax that treats everything as an
expression, and supports pass-by-value structures that are stored with multiple
local variables to avoid allocating/collecting tables.

Some features that are missing (and i'm not sure how to implement) include
class/struct methods (including operators), modules and multiple file support,
access to standard library, and allowing recursive functions.

To use it, run `main.lua` with the path a source code file as a command-line
arg.

Example code:

    # tuple
    var t = (1, 2);
    
    # define a structure stored with a table
    class MyObj (a: (float, string), b: bool);
    
    var o = new MyObj {a = (123, "test"), b = false};
    
    o.b = true;
    
    o.a._1 = 321;
    
    t._2 = o.a._1;
    
    t._1 = if (o.b) (
       456
    ) else (
       789
    );
    
    # similar to class, but stored with multiple locals instead of a table
    struct Vec2 (x: float, y: float);
    
    # function (return type inferred)
    var vec2_new = fn (x: float, y: float) (
	    new Vec2 {x = x, y = y} # missing ; causes the value to be returned
    );
    
    # function (explicit return type)
    var vec2_add = fn (a: Vec2, b: Vec2 -> Vec2) (
	    new Vec2 {x=0,y=0}  # operators not supported, should be {x = a.x + b.x, y = a.y + b.y}
    );
    
    var a = vec2_new(1, 2);
    
    var b = vec2_new(5, 6);
    
    var c = vec2_add(a, b);
    
    var d = vec2_add(vec2_add(b, c), vec2_new(3, 4));
	 
    variant V (
    	a (string, string),
    	b (float, string),
    	c,
    	d bool
    );
    
    let f = fn(v: V) ();
    
    let x = new V.b((5, "asdf"));
    
    f(x);
    f(new V.d(true));
    f(new V.c());
    
Example output (reformatted for readability):

    local ____tmp_0,____tmp_1=(1),(2);
  
    local o=({(123),"test",(false),});
 
    o[3]=(true);
   
    o[1]=(321);
 
    ____tmp_1=o[1]; 
 
    do
      local ____tmp_14;
      if o[3] then ____tmp_14=(456) else ____tmp_14=(789) end ;
      ____tmp_0=____tmp_14
    end ;
    
    local vec2_new=(function(x,y) return x,y end);
    
    local vec2_add=(function(____tmp_2,____tmp_3,____tmp_4,____tmp_5) return (0),(0) end);
    
    local ____tmp_6,____tmp_7=vec2_new((1),(2));
        
    local ____tmp_8,____tmp_9=vec2_new((5),(6));
    
    local ____tmp_10,____tmp_11=vec2_add(____tmp_6,____tmp_7,____tmp_8,____tmp_9);

    local ____tmp_12,____tmp_13;
    do
      local ____tmp_15,____tmp_16=vec2_add(____tmp_8,____tmp_9,____tmp_10,____tmp_11);
      ____tmp_12,____tmp_13=vec2_add(____tmp_15,____tmp_16,vec2_new((3),(4)))
    end ;

    local f=(function(____tmp_0,____tmp_1,____tmp_2) end);                                      
                                                                                                 
    local ____tmp_3,____tmp_4,____tmp_5=(2),(5),"asdf";                                           
                                                                                                   
    f(____tmp_3,____tmp_4,____tmp_5);                                                               
    f((4),(true),(nil));                                                                            
    f((3),(nil),(nil))
    
