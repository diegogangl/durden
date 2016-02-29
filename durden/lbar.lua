-- Copyright: 2015, Björn Ståhl
-- License: 3-Clause BSD
-- Reference: http://durden.arcan-fe.com
-- Description: lbar- is an input dialog- style bar intended for durden that
-- supports some completion as well. It is somewhat messy as it grew without a
-- real idea of what it was useful for then turned out to become really
-- important. Missing support for using the vast regions of empty space for
-- showing preview- information and other selection structures (graphs etc.)
-- then a good cleanup...
--

local function inp_str(ictx, valid)
	return {
		valid and gconfig_get("lbar_textstr") or gconfig_get("lbar_alertstr"),
		ictx.inp.view_str()
	};
end

local pending = {};

local function update_caret(ictx)
	local pos = ictx.inp.caretpos - ictx.inp.chofs;
	if (pos == 0) then
		move_image(ictx.caret, ictx.textofs, ictx.caret_y);
	else
		local msg = ictx.inp:caret_str();
		local w, h = text_dimensions({gconfig_get("lbar_textstr"),  msg});
		move_image(ictx.caret, ictx.textofs+w, ictx.caret_y);
	end
end

local function accept_cancel(wm, accept)
	for i,v in ipairs(pending) do mouse_droplistener(v); end
	pending = {};

	local ictx = wm.input_ctx;
	local time = gconfig_get("lbar_transition");
	blend_image(ictx.text_anchor, 0.0, time, INTERP_EXPOUT);
	blend_image(ictx.anchor, 0.0, time, INTERP_EXPOUT);
	if (time > 0) then
		PENDING_FADE = ictx.anchor;
		expire_image(ictx.anchor, time + 1);
		tag_image_transform(ictx.anchor, MASK_OPACITY, function()
			PENDING_FADE = nil;
		end);
	else
		for k,v in ipairs(pending) do
			mouse_droplistener(v);
		end
		pending = {};
		delete_image(ictx.anchor);
	end
	if (wm.debug_console) then
		wm.debug_console:system_event(string.format(
			"lbar(%s) returned %s", sym, ictx.inp.msg));
	end
	wm.input_ctx = nil;
	wm:set_input_lock();
	if (accept) then
		local base = ictx.inp.msg;
		if (ictx.force_completion or string.len(base) == 0) then
			if (ictx.set and ictx.set[ictx.csel]) then
				base = type(ictx.set[ictx.csel]) == "table" and
					ictx.set[ictx.csel][3] or ictx.set[ictx.csel];
			end
		end
		ictx.get_cb(ictx.cb_ctx, base, true, ictx.set, ictx.inp.msg);
	else
		if (ictx.on_cancel) then
			ictx:on_cancel();
		end
	end
end

-- Build chain of single selectable strings, move and resize the marker to each
-- of them, chain their positions to an anchor so they are easy to delete, and
-- track an offset for drawing. We rebuild / redraw each cursor modification to
-- ignore scrolling and tracking details.
--
-- Set can contain the set of strings or a table of [colstr, selcolstr, text]
local function update_completion_set(wm, ctx, set)
	if (not set) then
		return;
	end

	if (ctx.canchor) then
		delete_image(ctx.canchor);
		for i,v in ipairs(pending) do
			mouse_droplistener(v);
		end
		pending = {};
		ctx.canchor = nil;
		ctx.citems = nil;
	end

-- track if set changes as we will need to reset
	if (not ctx.set or #set ~= #ctx.set) then
		ctx.cofs = 1;
		ctx.csel = 1;
	end
	ctx.set = set;

-- clamp and account for paging
	if (ctx.clastc ~= nil and ctx.csel < ctx.cofs) then
		ctx.cofs = ctx.cofs - ctx.clastc;
		ctx.cofs = ctx.cofs <= 0 and 1 or ctx.cofs;
	end

-- limitation with this solution is that we can't wrap around negative
-- without forward stepping through due to variability in text length
	ctx.csel = ctx.csel <= 0 and ctx.clim or ctx.csel;

-- wrap around if needed
	if (ctx.csel > #set) then
		ctx.csel = 1;
		ctx.cofs = 1;
	end

-- very very messy positioning, relinking etc
	local regw = image_surface_properties(ctx.text_anchor).width;
	local step = math.ceil(0.5 + regw / 3);
	local ctxw = 2 * step;
	local textw = valid_vid(ctx.text) and (
		image_surface_properties(ctx.text).width) or ctxw;
	local lbarsz = gconfig_get("lbar_sz") * wm.scalef;

	ctx.canchor = null_surface(wm.width, lbarsz);
	image_tracetag(ctx.canchor, "lbar_anchor");

	move_image(ctx.canchor, step, 0);
	if (not valid_vid(ctx.ccursor)) then
		ctx.ccursor = color_surface(1, 1, unpack(gconfig_get("lbar_seltextbg")));
		image_tracetag(ctx.ccursor, "lbar_cursor");
	end

	local ofs = 0;
	local maxi = #set;

	ctx.clim = #set;

	for i=ctx.cofs,#set do
		local msgs = {};
		local str;
		if (type(set[i]) == "table") then
			table.insert(msgs, wm.font_delta ..
				(i == ctx.sel and set[i][2] or set[i][1]));
			table.insert(msgs, set[i][3]);
		else
			table.insert(msgs, wm.font_delta .. (i == ctx.sel
				and gconfig_get("lbar_seltextstr") or gconfig_get("lbar_textstr")));
			table.insert(msgs, set[i]);
		end

		local w, h = text_dimensions(msgs);
		local exit = false;
		local crop = false;

-- special case, w is too large to fit, just crop to acceptable length
		if (w > 0.3 * ctxw) then
			w = math.floor(0.3 * ctxw);
			crop = true;
		end

-- outside display? show ..., if that's our index, slide page
		if (i ~= ctx.cofs and ofs + w > ctxw - 10) then
			str = "...";
			if (i == ctx.csel) then
				ctx.clastc = i - ctx.cofs;
				ctx.cofs = ctx.csel;
				return update_completion_set(wm, ctx, set);
			end
			exit = true;
		end

		local txt, lines, txt_w, txt_h = render_text(
			str and str or (#msgs > 0 and msgs or ""));

		image_tracetag(txt, "lbar_text" ..tostring(i));
		link_image(ctx.canchor, ctx.text_anchor);
		link_image(txt, ctx.canchor);
		link_image(ctx.ccursor, ctx.canchor);
		image_inherit_order(ctx.canchor, true);
		image_inherit_order(ctx.ccursor, true);
		image_inherit_order(txt, true);
		order_image(txt, 2);
		order_image(ctx.ccursor, 1);
		image_clip_on(txt, CLIP_SHALLOW);

-- try to avoid very long items from overflowing their slot,
-- should "pop up" a copy when selected instead where the full
-- name is shown
		if (crop) then
			crop_image(txt, w, h);
		end

-- allow (but sneer!) mouse for selection and activation
		local mh = {
			name = "lbar_labelsel",
			own = function(ctx, vid) return vid == txt; end,
			motion = function(mctx)
				ctx.csel = i;
				resize_image(ctx.ccursor, txt_w, lbarsz);
				move_image(ctx.ccursor, mctx.mofs, 0);
			end,
			click = function()
				accept_cancel(wm, true);
			end,
-- need copies of these into returned context for motion handler
			mofs = ofs
		};

		mouse_addlistener(mh, {"motion", "click"});
		table.insert(pending, mh);
		show_image({txt, ctx.ccursor, ctx.canchor});

		if (i == ctx.csel) then
			move_image(ctx.ccursor, ofs, 0);
			resize_image(ctx.ccursor, txt_w, lbarsz);
		end

		move_image(txt, ofs, 0.5 * (lbarsz - active_display().font_sf * txt_h));
		ofs = ofs + (crop and w or txt_w) + gconfig_get("lbar_itemspace");
-- can't fit more entries, give up
		if (exit) then
			ctx.clim = i-1;
			break;
		end
	end
end

local function setup_string(wm, ictx, str)
	local tvid, heights, textw, texth = render_text(str);
	if (not valid_vid(tvid)) then
		return ictx;
	end

	local lbarh = math.ceil(gconfig_get("lbar_sz") * wm.scalef);
	ictx.text = tvid;
	image_tracetag(ictx.text, "lbar_inpstr");
	show_image(ictx.text);
	link_image(ictx.text, ictx.text_anchor);
	image_inherit_order(ictx.text, true);
	local texth = texth * active_display().font_sf;
	move_image(ictx.text, ictx.textofs, math.ceil(0.5 * (lbarh - texth)));

	return tvid;
end

local function lbar_ih(wm, ictx, inp, sym, caret)
	if (caret ~= nil) then
		update_caret(ictx);
		return;
	end

	local res = ictx.get_cb(ictx.cb_ctx, ictx.inp.msg, false, ictx.set);

-- special case, we have a strict set to chose from
	if (type(res) == "table" and res.set) then
		update_completion_set(wm, ictx, res.set);
	end

-- other option would be to run ictx.inp:undo, which was the approach earlier,
-- but that prevented the input of more complex values that could go between
-- valid and invalid. Now we just visually indicate.
	local str = inp_str(ictx, not (res == false or res == nil));

	if (valid_vid(ictx.text)) then
		ictx.text = render_text(ictx.text, str);
	else
		ictx.text = setup_string(wm, ictx, str);
	end

	update_caret(ictx);
end

-- used on spawn to get rid of crossfade effect
PENDING_FADE = nil;
local function lbar_input(wm, sym, iotbl, lutsym, meta)
	local ictx = wm.input_ctx;

	if (meta) then
		return;
	end

	if (not iotbl.active) then
		return;
	end

	if (sym == ictx.cancel or sym == ictx.accept) then
		return accept_cancel(wm, sym == ictx.accept);
	end

	if ((sym == ictx.step_n or sym == ictx.step_p)) then
		ictx.csel = (sym == ictx.step_n) and (ictx.csel+1) or (ictx.csel-1);
		update_completion_set(wm, ictx, ictx.set);
		return;
	end

-- special handling, if the user hasn't typed anything, map caret manipulation
-- to completion navigation as well)
	if (ictx.inp) then
		local upd = false;
		if (string.len(ictx.inp.msg) < ictx.inp.caretpos and
			sym == ictx.inp.caret_right) then
			ictx.csel = ictx.csel + 1;
			upd = true;
		elseif (ictx.inp.caretpos == 1 and ictx.inp.chofs == 1 and
			sym == ictx.inp.caret_left) then
			ictx.csel = ictx.csel - 1;
			upd = true;
		end

		if (upd) then
			update_completion_set(wm, ictx, ictx.set);
			return;
		end
	end

-- note, inp ulim can be used to force a sliding view window, not
-- useful here but still implemented.
	ictx.inp = text_input(ictx.inp, iotbl, sym, function(inp, sym, caret)
		lbar_ih(wm, ictx, inp, sym, caret);
	end);

	ictx.ulim = 10;

-- unfortunately the haphazard lbar design makes filtering / forced reverting
-- to a previous state a bit clunky, get_cb -> nil? nothing, -> false? don't
-- permit, -> tbl with set? change completion view
	local res = ictx.get_cb(ictx.cb_ctx, ictx.inp.msg, false, ictx.set);
	if (res == false) then
--		ictx.inp:undo();
	elseif (res == true) then
	elseif (res ~= nil and res.set) then
		update_completion_set(wm, ictx, res.set);
	end
end

local function lbar_label(lbar, lbl)
	if (valid_vid(lbar.labelid)) then
		delete_image(lbar.labelid);
		if (lbl == nil) then
			lbar.textofs = 0;

			return;
		end
	end

	local wm = active_display();
	local sf = wm.font_sf;

	local id, lines, w, h = render_text({wm.font_delta ..
		gconfig_get("lbar_labelstr"), lbl});

	lbar.labelid = id;
	if (not valid_vid(lbar.labelid)) then
		return;
	end

	image_tracetag(id, "lbar_labelstr");
	show_image(id);
	link_image(id, lbar.text_anchor);
	image_inherit_order(id, true);
	order_image(id, 1);

	local pad = gconfig_get("lbar_pad");
	local sz = math.ceil(gconfig_get("lbar_sz") * wm.scalef);
-- relinking / delinking on changes every time
	move_image(lbar.labelid, pad, math.ceil(0.5 * (sz - sf * h)));
	lbar.textofs = w + sz + pad;
	update_caret(lbar);
end

-- construct a default lbar callback that triggers cb on an exact
-- content match of the tbl- table
function tiler_lbarforce(tbl, cb)
	return function(ctx, instr, done, last)
		if (done) then
			cb(instr);
			return;
		end

		if (instr == nil or string.len(instr) == 0) then
			return {set = tbl, valid = true};
		end

		local res = {};
		for i,v in ipairs(tbl) do
			if (string.sub(v,1,string.len(instr)) == instr) then
				table.insert(res, v);
			end
		end

-- want to return last result table so cursor isn't reset
		if (last and #res == #last) then
			return {set = last};
		end

		return {set = res, valid = true};
	end
end

local function lbar_destroy(bar)
	accept_cancel(active_display(), false);
end

function tiler_lbar(wm, completion, comp_ctx, opts)
	opts = opts == nil and {} or opts;
	local time = gconfig_get("lbar_transition");
	if (valid_vid(PENDING_FADE)) then
		delete_image(PENDING_FADE);
		time = 0;
	end
	PENDING_FADE = nil;

	local bg = fill_surface(wm.width, wm.height, 255, 0, 0);
	shader_setup(bg, "ui", "lbarbg");
	local ph = {
		name = "bg_cancel",
		own = function(ctx, vid) return vid == bg; end,
		click = function() accept_cancel(wm, false); end
		};
	mouse_addlistener(ph, {"click"});
	table.insert(pending, ph);

	local barh = math.ceil(gconfig_get("lbar_sz") * wm.scalef);
	local bar = fill_surface(wm.width, barh, 255, 0, 0);
	shader_setup(bar, "ui", "lbar");

	link_image(bg, wm.order_anchor);
	link_image(bar, bg);
	image_inherit_order(bar, true);
	image_inherit_order(bg, true);
	image_mask_clear(bar, MASK_OPACITY);

	blend_image(bar, 1.0, time, INTERP_EXPOUT);
	blend_image(bg, gconfig_get("lbar_dim"), time, INTERP_EXPOUT);
	order_image(bg, 1);

	local car = color_surface(wm.scalef * gconfig_get("lbar_caret_w"),
		wm.scalef * gconfig_get("lbar_caret_h"),
		unpack(gconfig_get("lbar_caret_col"))
	);
	show_image(car);
	image_inherit_order(car, true);
	link_image(car, bar);
	local carety = gconfig_get("lbar_pad");

	local pos = gconfig_get("lbar_position");
	if (pos == "bottom") then
		move_image(bar, 0, wm.height - barh);
	elseif (pos == "center") then
		move_image(bar, 0, math.floor(0.5*(wm.height-barh)));
	elseif (pos == "top") then
		move_image(bar, 0, 0);
	end
	wm:set_input_lock(lbar_input);
	wm.input_ctx = {
		anchor = bg,
		text_anchor = bar,
-- we cache these per context as we don't want them changing mid- use
		accept = SYSTEM_KEYS["accept"],
		cancel = SYSTEM_KEYS["cancel"],
		step_n = SYSTEM_KEYS["next"],
		step_p = SYSTEM_KEYS["previous"],
		textstr = gconfig_get("lbar_textstr"),
		set_label = lbar_label,
		get_cb = completion,
		cb_ctx = comp_ctx,
		destroy = lbar_destroy,
		cofs = 1,
		csel = 1,
		textofs = 0,
		caret = car,
		caret_y = carety,
		cleanup = opts.cleanup,
-- if not set, default to true
		force_completion = opts.force_completion == false and false or true
	};
	lbar_input(wm, "", {active = true,
		kind = "digital", translated = true, devid = 0, subid = 0});

	if (opts.label) then
		wm.input_ctx:set_label(opts.label);
	end

	if (wm.debug_console) then
		wm.debug_console:system_event("lbar activated");
	end
	return wm.input_ctx;
end
