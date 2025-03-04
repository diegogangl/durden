--
-- wrapper for _input_event that tracks device states for repeat-rate control
-- and for "uncommon" devices that fall outside the normal keyboard/mouse
-- setup, that require separate lookup and translation, including state-
-- toggle on a per window (save/restore) basis etc.
--

local iostatem_evlog, iostatem_fmt = suppl_add_logfn("idevice");
local idle_threshold = gconfig_get("idle_threshold");
gconfig_listen("idle_threshold", "iostatem",
function(key, val)
	idle_threshold = val;
end);

local devstate = {
	counter = 0,
	delay = 0,
	period = 0
};
local devices = {};
local def_period = 0;
local def_delay = 0;
local DEVMAP_DOMAIN = APPL_RESOURCE;
local rol_avg = 1;
local evc = 1;
local slot_grab = nil;

-- specially for game devices, note that like with the other input platforms,
-- the actual mapping for a device may vary with underlying input platform and,
-- even worse, not guaranteed consistent between OSes even with 'the same'
-- platform.
local label_lookup = {};
local function default_lh(sub)
	return "BUTTON" .. tostring(sub + 1);
end

local function default_ah(sub)
	return "AXIS" .. tostring(sub + 1), 1;
end

local device_listeners = {};
function iostatem_listen_events(callback)
	table.insert(device_listeners, callback);
end

-- slotted grab is used to reroute all PLAYERn_*** translated inputs to
-- be routed to a specific window, ignoring active focus
function iostatem_slotgrab(new)
	slot_grab = new;
end

-- returns a table that can be used to restore the input state, used
-- for context switching between different windows or input targets.
local odst;

function iostatem_save()
	odst = devstate;
	if (not devstate.locked) then
		iostatem_reset_repeat();
	end
	return odst;
end

-- this takes over responsibility for input processing of a particular
-- device, [func] is expected to return a valid iotable for forwarding
-- or null to stop the chain.
function iostatem_register_handler(devid, name, func)
	if (not devices[devid]) then
		iostatem_evlog(iostatem_fmt(
			"register:status=einval:devid=%d:name=%s", devid, name));
		return;
	end

	iostatem_evlog(iostatem_fmt("register:device=%d:name=%s", devid, name));
	devices[devid].handler = func;
end

function iostatem_debug()
	local res =
		string.format("st: %d, ctr: %d, dly: %d, rate: %d, inavg: %.2f, cin: %.2f",
		devstate.iotbl and "1" or "0",
		devstate.counter, devstate.delay, 0, rol_avg, evc);
	return res;
end

function iostatem_lock(state)
	devstate.locked = state;
end

function iostatem_restore(tbl)
	if (devstate.locked) then
		return;
	end

	if (tbl == nil) then
		tbl = odst;
	end
	devstate = tbl;
	devstate.iotbl = nil;
	devstate.counter = tbl.delay and tbl.delay or def_delay;
	devstate.period = tbl.period and tbl.period or def_period;
-- FIXME: toggle proper analog axes and filtering
end

-- just feed this function, will cache state as necessary
local badseq = 1;
function iostatem_input(iotbl)
	local dev = devices[iotbl.devid];
	evc = evc + 1;

-- !dev shouldn't happen but may be an input platform bug
-- add a placeholder device so that we will at least 'work' normally
	if (not dev) then
		local lbl = "unkn_bad_" .. badseq;
		dev = iostatem_added(iotbl);
	end

-- some devices have triggers on return from idle, either for reconfiguration,
-- querying the user for an action and so on. This is processed here.
	if (dev.in_idle) then
		dev.in_idle = false;
		iostatem_evlog(iostatem_fmt(
			"return=idle:device=%d:name=%s", iotbl.devid, dev.name));
		if (dev.idle_out_command) then
			dispatch_symbol(dev.idle_out_command);
		end
	end
	dev.idle_clock = 0;

-- some input types (touch, game) can hook into the processing chain and either
-- consume and foward by itself, consume and translate to something else, or
-- revert to default behavior for the type.
	if (dev.handler) then
		local consumed, repl
		consumed, repl = dev.handler(iotbl);
		if consumed then
			return iotbl;
		end
		if repl then
			iotbl = repl;
		end
	end

-- currently mouse state management is handled elsewhere (durden+tiler.lua)
-- but we simulate a fake 'joystick' device here to allow meta + mouse to be
-- bound while retaining normal mouse behavior, but if it is not bound,
-- forward as normal.
	if (iotbl.mouse) then
		local m1, m2 = dispatch_meta();

-- don't want bindings or normal input to trigger while the bar is active
		if (tiler_lbar_isactive()) then
			return;
		end

-- need to check if it has been bound, which means resolving the full table,
-- we join all mouse- tagged devices into one here and the .digital check
-- further below, will need some changes to account for virtual devices that
-- are built out of multiple individual ones
		if (iotbl.digital and (m1 or m2)) then
			if (gconfig_get("mouse_coalesce")) then
				iotbl.dsym = "mouse1_" .. tostring(iotbl.subid);
			end

			local _, _, _, bound = dispatch_translate(iotbl, true);
-- if it was in an actual 'bound' state, drop the mouse device tag so that
-- it won't get forwarded to the mouse event handler, yet return false so
-- it gets reinjected into the bound event dispatch
			if (bound) then
				iotbl.mouse = nil;
				return false;
			end

		else
		end
	end

-- keyboard devices we need to distinguish modifiers (don't affect repeat)
-- and normal ones, we don't consider latched as that falls into (led+state)
-- that is up to the user to bind to custom keymaps should those be needed
	if (iotbl.translated) then
		if (not iotbl.active or SYMTABLE:is_modifier(iotbl)
			or dispatch_repeatblock(iotbl)) then
			devstate.counter = devstate.delay ~= nil and devstate.delay or def_delay;
			devstate.iotbl = nil;
			return;
		end

		devstate.iotbl = iotbl;

-- digital devices continue the abstract mouse labeling used above in early
-- dispatch resolve, but also checking for 'global slots' where single windows
-- can be assigned an input device slot and get an automated 'game device'
-- label.
	elseif (iotbl.digital) then
		if (iotbl.mouse and gconfig_get("mouse_coalesce")) then
			iotbl.dsym = "mouse1_" .. tostring(iotbl.subid);
		else
			iotbl.dsym = tostring(iotbl.devid) .. "_" .. tostring(iotbl.subid);
		end

		if (dev.slot > 0 and dev.lookup) then
			iotbl.label = "PLAYER" .. tostring(dev.slot) .. "_" ..
				dev.lookup[1](iotbl.subid);

-- forward to the dedicated slot recipient and return that the event has been
-- consumed by the iostate manager and should short-circuit
			if (slot_grab and valid_vid(slot_grab.external, TYPE_FRAMESERVER)) then
				target_input(slot_grab.external, iotbl);
				return true;
			end
		end

-- and the same process for slotted analog devices, it might be that there
-- should be a different hooking mechanism for these as it is a high-rate
-- path, but not until benchmarked.
	elseif (iotbl.analog and dev and dev.slot > 0) then
		local ah, af = dev.lookup[2](iotbl.subid);
		if (ah) then
			iotbl.label = "PLAYER" .. tostring(dev.slot) .. "_" .. ah;
			if (af ~= 1) then
				for i=1,#iotbl.samples do
					iotbl.samples[i] = iotbl.samples[i] * af;
				end
			end
			if (slot_grab and slot_grab.external) then
				target_input(slot_grab.external, iotbl);
				return true;
			end
		end

-- only forward if absolutely necessary (i.e. selected window explicitly
-- accepts analog) as the input storms can saturate most event queues
		return true;

-- touch is "deferred" registration because the event layer won't tell us
-- if we have a touch device or not, so we react to the first sample and the
-- touch subsystem then redirects routing for the specific device
	elseif (iotbl.touch and not dev.masked) then
		touch_register_device(iotbl);
	end
end

local function set_period(id, val)
	if (val == nil) then
		return;
	end
	def_period = val < 0 and 0 or val;
end

local function set_delay(id, val)
	if (val == nil) then
		return;
	end

	def_delay = val < 0 and 1 or math.ceil(val / 1000 * CLOCKRATE);
end

function iostatem_reset_repeat()
	devstate = {
		iotbl = nil,
		delay = def_delay,
		period = def_period,
		counter = def_delay
	};
end

-- for the _current_ context, set delay in ms, period in ticks/ch
function iostatem_repeat(period, delay)
	if (period == nil and delay == nil) then
		return devstate.period, devstate.delay;
	end

	if (period ~= nil) then
		devstate.period = period;
	end

	if (delay ~= nil) then
		devstate.delay = math.ceil(delay  / 1000 * CLOCKRATE);
		devstate.counter = devstate.delay;
	end
end

-- returns a table of iotbls, process with ipairs and forward to
-- normal input dispatch
function iostatem_tick()
	rol_avg = rol_avg * (CLOCK - 1) / CLOCK + evc / CLOCK;
	evc = 0;

-- this counter is reset on each sample, so that we can set actions
-- when a device returns from idle or when it enters into an idle state
	for k,v in pairs(devices) do
		v.idle_clock = v.idle_clock + 1;
		if idle_clock == idle_threshold then
			v.in_idle = true;
			iostatem_evlog(iostatem_fmt("kind=idle:device=%d:name=%s", k, v.name));
			if v.idle_command then
				dispatch_symbol(v.idle_command);
			end
		end
	end

	if (not devstate.counter or devstate.counter == 0) then
		return;
	end

	if (devstate.iotbl and devstate.period) then
		devstate.counter = devstate.counter - 1;

-- undocumented quirk, ARKMOD_REPEAT is provided by some platforms but not
-- exposed in modifiers - set it here

		if (devstate.counter == 0) then
			devstate.counter = devstate.period;
			devstate.iotbl.modifiers = bit.bor(devstate.iotbl.modifiers, 0x8000)
			if not devstate.iotbl.repeat_count then
				devstate.iotbl.repeat_count = 0
			else
				devstate.iotbl.repeat_count = devstate.iotbl.repeat_count + 1
			end

-- copy and add a release so the press is duplicated
			local a = {};
			for k,v in pairs(devstate.iotbl) do
				a[k] = v;
			end

			a.active = false;
			return {a, devstate.iotbl};
		end
	end

-- scan devstate.devices and emitt similar events for the auto-
-- repeat toggles there
end

function iostatem_shutdown()
end

-- find the lowest -not-in-used- slot ID by alive devices
local function assign_slot(dev)
	local vls = {};
	for k,v in pairs(devices) do
		if (not v.lost and v.slot) then
			vls[v.slot] = true;
		end
	end

	local ind = 1;
	while true do
		if (vls[ind]) then
			ind = ind + 1;
		else
			break;
		end
	end

	dev.slot = ind;
end

function iostatem_reset_flag()
	for i,v in pairs(devices) do
		v.lost = true;
	end

-- force aw platform input rescan
	iostatem_reset_repeat();
	inputanalog_query(nil, nil, true);
end

function iostatem_added(iotbl)
	local dev = devices[iotbl.devid];

	if (not dev) then
-- locate last saved device settings:
-- axis state, analog force, special bindings
		local loglbl = "kind=added:device=" .. tostring(iotbl.devid);
		local dev = {
			devid = iotbl.devid,
			label = iotbl.extlabel,
-- we only switch analog sampling on / off
			lookup = label_lookup[iotbl.label]
				and label_lookup[iotbl.label] or {default_lh, default_ah},
			force_analog = false,
			keyboard = (iotbl.keyboard and true or false),
			idle_clock = 0
		};
		devices[iotbl.devid] = dev;

-- safeguard against missing label field
		if not dev.label or #dev.label == 0 then
			if iotbl.label and #iotbl.label > 0 then
				dev.label = iotbl.label;
			else
				dev.label = "unknown_" .. tostring(iotbl.devid);
			end
		end

-- notification may need an initial cutoff due to the startup storm,
-- though it should really be binned / rate-limited in the notification
-- system based on CLOCK
		local cutoff = gconfig_get("device_notification");
		if cutoff >= 0 and CLOCK > cutoff then
			notification_add("Device",
				nil, "Discovered", devices[iotbl.devid].label, 1);
		end

-- used for game devices to tag with PLAYERn and BUTTONm, this is
-- a somewhat old interface and might be better just going for normal
-- labelhints these days
		if (label_lookup[iotbl.label]) then
			assign_slot(dev);
		else
			dev.slot = 0;
		end
		iostatem_evlog(iostatem_fmt("%s:label=%s:slot=%d",
			loglbl, iotbl.label and iotbl.label or "missing", dev.slot));

-- Send to any registered listeners so they can grab the device.
-- This is more complex than 'one device_listener takes one device' as
-- some are aggregates that can be a keyboard, mouse, touch etc. on the
-- same logical device. In some cases those should be forwarded to other
-- handlers, in some cases we might need to create synthetic devices.
		local masked = false;
		for i=1,#device_listeners do
			if device_listeners[i](devices[iotbl.devid]) then
				iostatem_evlog(iostatem_fmt("handler_mask:device=%d", iotbl.devid));
				devices[iotbl.devid].masked = true;
			end
		end

-- touch handling should be reworked to match the interface above,
-- note that devices with no profile won't be assigned default touch
-- until it provides a sample that was not previously registered to a
-- touch device
		if not devices[iotbl.devid].masked then
			touch_register_device(iotbl, true);
		end
	else
-- keeping this around for devices and platforms that generate a new
-- ID for each insert/removal will slooowly leak (unlikely though)
		if (dev.lost) then
			iostatem_evlog("added:lost=yes:name=" .. dev.label);
			dev.lost = false;
-- reset analog settings and possible load slot again
			assign_slot(dev);

-- this should practically not happen, i.e. a device we have an entry for,
-- is marked as added yet has not been marked as lost
		else
			iostatem_evlog(iostatem_fmt(
				"added:lost=no:device=%d:status=warning:name=%s",
				iotbl.devid, dev.label));
		end
	end

	return devices[iotbl.devid];
end

function iostatem_lookup(devid)
	return devices[devid];
end

function iostatem_removed(iotbl)
	local dev = devices[iotbl.devid];

	if (dev) then
		notification_add("Device", nil, "Lost", dev.label, 1);
		dev.lost = true;
		iostatem_evlog("removed:name=" .. dev.label);
-- protection against keyboard behaving differently when lost/found
		if (iotbl.devkind == "keyboard") then
			meta_guard_reset();
		end
	else
		notification_add("Device", nil, "Removed", "unknown device (bug)", 1);
		iostatem_evlog("warning:removed:known=false:id=" .. tostring(iotbl.devid));
	end
end

local function get_devlist(eval)
	local res = {};
	for k,v in pairs(devices) do
		if (eval(v)) then
			table.insert(res, v);
		end
	end
	return res;
end

function iostatem_devices(slotted)
	local lst;
	if (slotted) then
		lst = get_devlist(function(a) return not a.lost and a.slot > 0; end);
		table.sort(lst, function(a, b) return a.slot < b.slot; end);
	else
		lst = get_devlist(function(a) return not a.lost; end);
		table.sort(lst, function(a,b) return a.devid < b.devid; end);
	end
		return ipairs(lst);
end

function iostatem_devcount()
	local i = 0;
	for k,v in pairs(devices) do
		if (not v.lost) then
			i = i + 1;
		end
	end
	return i;
end

local function tryload(map)
	local res = system_load("devmaps/" .. map, 0);
	if (not res) then
		warning(string.format("iostatem, system_load on map %s failed", map));
		return;
	end

	local okstate, id, flt, handler, ahandler = pcall(res);
	if (not okstate) then
		warning(string.format("iostatem, couldn't get handlers for %s", map));
		return;
	end

	if (type(id) ~= "string" or type(flt) ~=
		"string" or type(handler) ~= "function") then
		warning(string.format("iostatem, map %s returned wrong types", map));
		return;
	end

	if (label_lookup[id] ~= nil) then
		warning("iostatem, identifier collision for %s", map);
		return;
	end

-- there is no real way around not being able to apply every device profile
	if (string.match(API_ENGINE_BUILD, flt)) then
		label_lookup[id] = {handler, (ahandler and type(ahandler) == "function")
			and ahandler or default_ah};
	end
end

function iostatem_init()
	devstate.devices = {};
	set_period(nil, gconfig_get("kbd_period"));
	set_delay(nil, gconfig_get("kbd_delay"));
	iostatem_repeat(gconfig_get("kbd_period"), gconfig_get("kbd_delay"));

	gconfig_listen("kbd_period", "iostatem", set_period);
	gconfig_listen("kbd_delay", "iostatem", set_delay);
	local list = glob_resource("devmaps/game/*.lua", DEVMAP_DOMAIN);

-- glob for all devmaps, make sure they match the platform and return
-- correct types and non-colliding identifiers
	for k,v in ipairs(list) do
		tryload("game/" .. v);
	end

-- all analog sampling on by default, then we manage on a per-window
-- and per-device level
	inputanalog_toggle(true);
	iostatem_save();
end

system_load("input/rotary.lua")(); -- rotary device controls
system_load("input/touch.lua")(); -- touch device controls
