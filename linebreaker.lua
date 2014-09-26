local linebreaker = {}

-- max allowed value of tolerance
linebreaker.max_tolerance = 9999
-- line breaking function is customizable
linebreaker.breaker = tex.linebreak -- linebreak function
linebreaker.max_cycles = 30 -- max # of attempts to find best solution
														-- the number is totally arbitrary

linebreaker.boxsize = 65536 -- default box size is 1pt. 
														-- value is in scaled points
linebreaker.vertical_point = tex.baselineskip.width -- vertical matrix
linebreaker.previous_points = linebreaker.vertical_point / linebreaker.boxsize
														-- number of
 														-- points which will be taken into account in 
														-- calculating river value. these points will
														-- be processed in both directions
-- return array with default parameters
function linebreaker.parameters()
	return {}--{emergencystretch=tex.sp(".5em")}
end

-- function linebreaker.make_default_parameters()
-- 				local parameters = {}
-- 				parameters.pardir = tex.pardir 
-- 				parameters.pretolerance= tex.pretolerance
-- 				parameters.tracingparagraphs= tex.tracingparagraphs
-- 				parameters.tolerance= tex.tolerance
-- 				parameters.looseness= tex.looseness
-- 				parameters.hyphenpenalty= tex.hyphenpenalty
-- 				parameters.exhyphenpenalty= tex.exhyphenpenalty
-- 				parameters.pdfadjustspacing= tex.pdfadjustspacing
-- 				parameters.adjdemerits= tex.adjdemerits
-- 				parameters.pdfprotrudechars= tex.pdfprotrudechars
-- 				parameters.linepenalty= tex.linepenalty
-- 				parameters.lastlinefit= tex.lastlinefit
-- 				parameters.doublehyphendemerits = tex.doublehyphendemerits 
-- 				parameters.finalhyphendemerits= tex.finalhyphendemerits
-- 				parameters.hangafter= tex.hangafter
-- 				parameters.interlinepenalty= tex.interlinepenalty
-- 				parameters.clubpenalty= tex.clubpenalty
-- 				parameters.widowpenalty= tex.widowpenalty
-- 				parameters.brokenpenalty= tex.brokenpenalty
-- 				parameters.emergencystretch= tex.emergencystretch
-- 				parameters.hangindent= tex.hangindent
-- 				parameters.hsize= tex.hsize
-- 				parameters.leftskip= tex.leftskip
-- 				parameters.rightskip= tex.rightskip
-- 				parameters.pdfeachlineheight= tex.pdfeachlineheight
-- 				parameters.pdfeachlinedepth= tex.pdfeachlinedepth
-- 				parameters.pdffirstlineheight= tex.pdffirstlineheight
-- 				parameters.pdflastlinedepth= tex.pdflastlinedepth
-- 				parameters.pdfignoreddimen= tex.pdfignoreddimen
-- 				parameters.parshape= tex.parshape
-- 				return parameters
-- end
-- 

-- diagnostic function for traversing nodes returned by linebreaking
-- function. only top level nodes are processed, not sublists
function linebreaker.traverse(head)
	--for n in node.traverse(node.tail(head).head) do
	for n in node.traverse(head) do
		print(n.id, n.subtype)
		if n.id == 10 then
			local x = n.spec or {}
			--x.shrink = 111222
			print("glue", x.shrink,x.stretch)
		end
	end
	print "****************"
	return head
end


local char = unicode.utf8.char
local glyph_id = node.id("glyph")

-- get text content of node list
local function get_text(line)
	local t = {}
	for n in node.traverse(line) do
		if n.id == 10 then t[#t+1] = " "
		elseif n.id == glyph_id then t[#t+1] = char(n.char or "?") 
		end
	end
	return table.concat(t)
end

-- find badness of a line
function linebreaker.par_badness(head)
	local n = 0
	for line in node.traverse_id(0, head) do
		print(get_text(line.head), line.glue_order, line.glue_sign, line.glue_set)
		-- glue_sign: > 0 = normal, 1 = stretch,  2 = shrink
		-- we count only shrink, but stretch may result in overfull box as well
		-- I just don't know, how to detect which value of glue_set means error
		if line.glue_sign == 2 and line.glue_set >= 1 then n = n + 1 end
	end;
	return n
end

-- we have table with guessed param tables. we loop over them and find one with
-- lowest value of badness. this situation shouldn't happen, as at the moment
-- tolerance may be as high as 9999 and this should fix all overfulls
-- this code is remain of older method of guessing right value of tolerance
local function find_best(params)
	local min = 10000 -- arbitrary high value
	local n = params[1] or {}
	for _, p in ipairs(params) do
		local badness = p.badness or min
		if badness <= min then 
			n = p
			min = badness
		end
	end
	print "best solution"
	for k,v in pairs(n) do 
		print(k,v)
	end
	return n
end

-- all glue_spec nodes has .width key, but it is the same all the time. real
-- width depends on line shrink and stretch
-- this will be used in river detection
local function glue_calc(n, sign,set)
 	-- function for calculating glue width
 	if sign ==2 then
 		size=n.spec.width - n.spec.shrink*set
 	else
 		size=n.spec.width + n.spec.stretch*set
 	end
	return size
end


-- calculate new tolerance
-- max_tolerance / max_cycles is added to the current tolerance value
local function calc_tolerance(previous)
  local previous = previous or tex.tolerance
	local max_cycles = linebreaker.max_cycles
	local max_tolerance = linebreaker.max_tolerance 
  local new =  previous + (max_tolerance / max_cycles)-- + math.sqrt(previous * 4)
	return (new < max_tolerance) and new or max_tolerance
end

-- river detection 
-- idea is following:
-- 1. count widths of words and spaces 
-- 2. divide widths to segments of some width (1pt?)
-- 3. assign number to segments: full glyph in the midle of a word:0
-- 						full glue: 1
-- 						edges of words: fraction depending on glyph dimensions
-- 							(it would be nice to incorporate glyph shapes, but it is 
-- 							unrealistic, we don't have access)
-- 4. add numbers from previous line, probably sum of segments in some 
-- 			distance (baselineskip / segments per sp = 45°?)
-- 5. sum segments for a glue / glue width = river ratio?
-- 6. find right threshold for telling which value of river ratio is a real
--    river
-- 7. calculate river ratio for whole paragraph (sum of over threshold 
-- 		river ratios?)
-- I am not a mathematician, so I don't know whether this method is accurate,
-- 		correct, or efficient, 
--
--
function linebreaker.detect_rivers(head)
	local lines = {} -- 
	local boxsize = linebreaker.boxsize
	local vertical_point = linebreaker.vertical_point
	local previous_points = math.ceil(linebreaker.previous_points)
	local calc_river = function(line, lines)
    -- get previous line
		local previous = lines and lines[#lines] or {}
		local get_point = function(i)
			return previous[i] or 0
		end
		for i = 1, #line do
			local v = line[i]
			if v > 0 then
				v = v + get_point(i)
				-- ve add values from previous line
				for c = 1, previous_points do
					v = v + (get_point(i+c)/i) + (get_point(i-c)/i)
					--print("adding",v)
				end
				line[i] = v
			end
			print("Calculate for", i,v)
		end
		return line
	end
	for n in node.traverse_id(0, head) do
		local t = {}
		-- glue parameters
		local set = n.glue_set
		local sign = n.glue_sign
		local order =  n.glue_order
		local first_node = n.head
		local first_glyph = nil
		local first = true
		local last_glyph = nil
		local last_glue = n.head
		local position = 0
		local remain = 0
		local get_glyph_black =  function(glyph)
			-- only calculate blackness for glyphs
			if glyph.id == 37 then
				local w,h,d = node.dimensions(glyph, glyph.next)
				-- 1 is maximal white
				local blackness = 1 - ((h+d) / vertical_point)
				print(char(glyph.char), blackness)
        return w / boxsize or 0, blackness
			end
			return 0,0
		end
		-- get width of nodes
		local get_width = function(start,fin)
			local w = node.dimensions(set,sign,order,start, fin) 
			return w / boxsize -- get width in pt
		end
		local add_word = function(start,fin)
			local width = get_width(start,fin)
			-- first and last glyph are taken into account for blackness calculation
			local w1, f = get_glyph_black(first_glyph) 
			local w2, l = get_glyph_black(last_glyph)
			w1 = math.ceil(w1 + remain)
			w2 = math.ceil(w2)
			width = width + remain
			remain = width - math.floor(width)
			width = width - remain
			for i=1, w1 do
				t[#t+1] = f/i -- add more black at the end of glyph
			end
			-- middle of the word
			for i=1, (width-w1-w2) do
				t[#t+1] = 0
			end
			-- last glyph
			for i=1, w2 do
				t[#t+1] = l/(w2-i+1)
			end
			--print("black", f,l)
		end
		add_glue = function(x)
			local width = get_width(x,x.next) + remain
			remain = width - math.floor(width)
			width = width - remain
			for i=1, width do
				t[#t+1] = 1
			end
		end
		for x in node.traverse(n.head) do
			if x.id == 10 and x.subtype == 0 then
				--print("glue width", get_width(x,x.next))
				add_word(last_glue, x, first_glyph,last_glyph)
				add_glue(x)
				first = true
				last_glue = x.next -- calculate width of next word from here
			elseif x.id == 37 then
				if first then
					first_glyph = x
				end
				first = false
				last_glyph = x
			end
		end
		add_word(last_glue, x, first_glyph, last_glyph)
		table.insert(lines, calc_river(t,lines))
		print(table.concat(lines[#lines],","))
		-- local width, h, d = node.dimensions(set, sign, order, n.head, node.tail(n.head))
		-- print(width,table.concat(t))
	end
	return 0
end



function linebreaker.best_solution(par, parameters)
	-- save current node list, because call to the linebreaker modifies it
	-- and we wouldn't be able to run it multiple times
	local head = node.copy_list(par)
	-- this shouldn't happen
	if #parameters > linebreaker.max_cycles then
		print "max cycles found"
		return linebreaker.breaker(head,find_best(parameters))
	end
	local params = parameters[#parameters]	-- newest parameters are last in the
	-- table
	local newparams =  {}
	-- break paragraph
	local newhead, info = linebreaker.breaker(head, params)
	-- calc badness
	local badness = linebreaker.par_badness(newhead)
	params.badness =  badness
	print("badness", badness, tex.hfuzz, tex.tolerance)
	-- [[
	if badness > 0 then
		-- calc new value of tolerance
		local tolerance = calc_tolerance(params.tolerance) -- or 10000 
		print("tolerance", tolerance)
		-- save tolerance to newparams so this value will be used in next run
		newparams.tolerance = tolerance 
		table.insert(parameters, newparams)
		print("high badness", badness)
		-- run linebreaker again
		return linebreaker.best_solution(par, parameters)
	end
	-- detect rivers only for paragraphs without overflow boxes
	local rivers = linebreaker.detect_rivers(newhead)
	print("rivers", rivers)
	print "normal return"
	--]]
	return newhead, info
end

-- this is just reporting function which print lines with glue widths.
-- this may be useful in river detection
local function glue_width(head)
	for n in node.traverse_id(0, head) do
		local t = {}
		local set = n.glue_set
		local sign = n.glue_sign
		local order =  n.glue_order
		for x in node.traverse(n.head) do
			if x.id == 10 then
				local g = x.spec
				local size = glue_calc(x, sign, set)
				t[#t+1] = ":"..size.."."
			elseif x.id == 37 then
				t[#t+1] = char(x.char)
			end
		end
		local width, h, d = node.dimensions(set, sign, order, n.head, node.tail(n.head))
		print(width,table.concat(t))
	end
end

function linebreaker.linebreak(head,is_display)
	local parameters = linebreaker.parameters()
	local newhead, info = linebreaker.best_solution(head, {parameters}) 
	--print(tex.tolerance,tex.looseness, tex.adjdemerits, info.looseness, info.demerits)
	glue_width(newhead)
	tex.nest[tex.nest.ptr].prevdepth=info.prevdepth
	tex.nest[tex.nest.ptr].prevgraf=info.prevgraf
	--return linebreaker.traverse(add_parskip(newhead))
	return newhead
end


return linebreaker

