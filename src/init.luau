--!strict
--!optimize 2

--- Cleaner tracks resources and tears them all down with a single call. It fills the same role as Trove, Maid, and
--- Janitor.
---
--- ```lua
--- const cleaner = Cleaner.new()
--- const part = cleaner:Add(Instance.new("Part"))  -- returns its argument, type preserved
--- cleaner:Add(part.Touched:Connect(onTouched))
--- cleaner:Add(TweenOut, frameA, 3)                -- runs TweenOut(frameA, 3) on cleanup
--- cleaner:Add(TweenOut, frameB, 2)                -- the same function may be tracked again with other args
--- cleaner:Clean()                                 -- tears everything down; the Cleaner is empty and reusable
--- ```
---
--- ## Guarantees
--- 1. Clean never throws and never yields. Errors raised by teardown are reported to the output but never interrupt
---    cleaning or reach the caller. Teardown code that yields runs on its own thread and finishes later.
--- 2. Teardown order is LIFO (reverse insertion order), with all non-Instances torn down before any Instance.
--- 3. AnimationTracks are stopped and Tweens are cancelled immediately, then destroyed one frame later, so their
---    Stopped/Completed events can dispatch.
--- 4. When Clean returns, every entry tracked at the time of the call has been torn down (or its teardown has
---    started, if it yields), and the Cleaner is empty (see "Adding during cleaning" for the one exception).
--- 5. Add returns its argument with the type preserved, and the extra arguments of a tracked function are
---    type-checked against that function.
---
--- ## Teardown by type
--- - `function`: called on a new thread (task.spawn) with the extra arguments given to Add.
--- - `thread`: cancelled with task.cancel. Threads that cannot be cancelled (e.g., the running thread) are skipped.
--- - `RBXScriptConnection`: disconnected.
--- - `table`: the first of `Destroy`, `Disconnect`, `destroy`, `disconnect` that is a function is called as a method
---   on a new thread. This covers custom classes, custom Signal connections, and nested Cleaners.
--- - Promise (any table with `cancel`, `getStatus` and `finally` methods, such as evaera/promise): cancelled, the
---   same way as other tables. A Promise that has already settled is not tracked, and a tracked Promise is untracked
---   automatically when it settles, so long-lived Cleaners don't accumulate finished Promises.
--- - `Instance`: destroyed (AnimationTrack and Tween: see guarantee 3).
--- - `nil` is ignored silently. Anything else (plain tables, numbers, Vector3s, ...) is ignored with a warning.
---
--- ## Edge cases
--- - Duplicates: the same value may be tracked more than once. Every entry is torn down, so a duplicated object's
---   Destroy runs once per entry. Each entry of a duplicated function keeps its own arguments.
---   Remove/Unlink act on the most recently added matching entry, one entry per call.
--- - Re-entrancy: Clean called while the same Cleaner is cleaning is a no-op. A Cleaner may track itself, and
---   Cleaners may track each other in a cycle.
--- - Adding during cleaning: if teardown code calls Add on the Cleaner being cleaned, a warning is emitted and the
---   value is tracked for the *next* Clean. Only synchronous Adds are detected; Adds made after a yield, or from
---   deferred event handlers, simply land after Clean has returned.
--- - Remove/Unlink during cleaning: the batch being cleaned is detached up front, so they return false for its
---   entries, which are still torn down as normal.
--- - Event ordering: non-Instances (including connections) are torn down before Instances, so a tracked connection to
---   a tracked Instance's own event (e.g., an AnimationTrack's Stopped) will NOT fire during cleanup. This is
---   intentional: handlers never run mid-teardown. For a side effect at cleanup time, track a function instead.
--- - A table whose cleanup method was removed after it was added is skipped silently during cleanup.
---
--- @author Matthew (jakedies)
--- @author David (CeaselessQuokka)
const Cleaner = {}
Cleaner.__index = Cleaner

-- Checked in order; the first that is a function is used.
const CLEANUP_METHOD_NAMES = table.freeze({ "Destroy", "Disconnect", "destroy", "disconnect" })

-- A table with all of these methods is treated as a Promise.
const PROMISE_METHOD_NAMES = table.freeze({ "cancel", "getStatus", "finally" })

type PackedArgs = { [number]: unknown, n: number }

-- Invariants:
--  * `_tracked` and `_args` are parallel arrays: `#_tracked == #_args` at all times, and `_args[i]` belongs to
--    `_tracked[i]`. Every insertion and removal must touch both, at the same index.
--  * `_args[i]` is a packed argument list only when `_tracked[i]` is a function that was added with at least one
--    extra argument. Otherwise it is `false` (not `nil`, which would leave a hole and break `#`).
--  * `_isCleaning` is true only while Clean is running. Clean cannot throw, so it is always reset.
type CleanerData = {
	_tracked: { unknown },
	_args: { PackedArgs | false },
	_isCleaning: boolean,
}

export type Cleaner = setmetatable<CleanerData, typeof(Cleaner)>

-- `tbl[key]` as a function, so a lookup that may hit a throwing `__index` can be pcall'd.
local function getField(tbl: { [unknown]: unknown }, key: unknown): unknown
	return tbl[key]
end

-- Returns `tbl[name]` if it is a function, or nil. Never throws: some classes use an `__index` that throws on unknown
-- keys, so each lookup is guarded on its own.
local function getMethod(tbl: { [unknown]: unknown }, name: string): ((any) -> ...any)?
	const success, method = pcall(getField, tbl, name)
	if success and typeof(method) == "function" then
		return method :: (any) -> ...any
	end
	return nil
end

-- Whether `tbl` looks like a Promise. Never throws.
local function isPromise(tbl: { [unknown]: unknown }): boolean
	for _, name in PROMISE_METHOD_NAMES do
		if getMethod(tbl, name) == nil then
			return false
		end
	end
	return true
end

-- Returns the method that tears `tbl` down, or nil. Never throws.
-- A class that only defines `Disconnect` must not be rejected because the earlier `Destroy` lookup threw.
local function getCleanupMethod(tbl: { [unknown]: unknown }): ((any) -> ...any)?
	for _, name in CLEANUP_METHOD_NAMES do
		const method = getMethod(tbl, name)
		if method then
			return method
		end
	end
	if isPromise(tbl) then
		return getMethod(tbl, "cancel")
	end
	return nil
end

-- Whether a value has a teardown path (see `cleanTrackable`).
local function isCleanable(trackable: unknown): boolean
	const kind = typeof(trackable)
	if kind == "table" then
		return getCleanupMethod(trackable :: { [unknown]: unknown }) ~= nil
	end
	return kind == "function" or kind == "thread" or kind == "Instance" or kind == "RBXScriptConnection"
end

-- Calls the table's cleanup method. Runs on its own thread (see `cleanTrackable`).
local function cleanupTable(tbl: { [unknown]: unknown })
	const method = getCleanupMethod(tbl)
	if method then
		method(tbl)
	end
end

local function cleanInstance(instance: Instance)
	if instance:IsA("AnimationTrack") then
		instance:Stop()
	elseif instance:IsA("Tween") then
		instance:Cancel()
	else
		instance:Destroy()
		return
	end

	-- Defer one cycle so the AnimationTrack's Stopped and Tween's Completed events can dispatch before the handle is
	-- destroyed. It is not the Cleaner's job to ensure "fully finished" events such as AnimationTrack.Ended or
	-- VideoFrame.Ended are invoked.
	task.delay(0, pcall, instance.Destroy, instance)
end

-- Tears down a single entry. Must never throw or yield (Clean relies on this to reset `_isCleaning`); anything that
-- could do either runs on its own thread or under pcall.
local function cleanTrackable(trackable: unknown, args: PackedArgs | false)
	if typeof(trackable) == "function" then
		if args then
			task.spawn(trackable, table.unpack(args, 1, args.n))
		else
			task.spawn(trackable)
		end
	elseif typeof(trackable) == "thread" then
		-- task.cancel throws for threads that can't be cancelled, such as the running thread or one that is currently
		-- resuming another. Those are skipped.
		const _ = pcall(task.cancel, trackable)
	elseif typeof(trackable) == "RBXScriptConnection" then
		trackable:Disconnect()
	elseif typeof(trackable) == "table" then
		-- Its own thread: the cleanup method may throw or yield.
		task.spawn(cleanupTable, trackable :: { [unknown]: unknown })
	elseif typeof(trackable) == "Instance" then
		-- Destroy can throw (e.g., on locked or capability-restricted instances).
		const _ = pcall(cleanInstance, trackable)
	end
end

-- Removes the most recently added entry matching `trackable` from both parallel arrays.
-- Returns whether an entry was found, and that entry's args.
-- Searches from the end so that duplicates are removed in LIFO order, matching teardown order.
local function detach(self: CleanerData, trackable: unknown): (boolean, PackedArgs | false)
	const tracked = self._tracked
	for index = #tracked, 1, -1 do
		if tracked[index] == trackable then
			const args = self._args[index]
			table.remove(tracked, index)
			table.remove(self._args, index)
			return true, args
		end
	end
	return false, false
end

--- @static
function Cleaner.new(): Cleaner
	const self: CleanerData = {
		_tracked = {},
		_args = {},
		_isCleaning = false,
	}
	return setmetatable(self, Cleaner)
end

-- Three overloads:
--  1. A typed function overload, so `Add(obj.Method, a, b)` type-checks its args.
--  2. A catch-all for table-like values: connections, nested Cleaners, Instances, custom objects. `T & ({}?)` also
--     admits optional values and `nil`, while returning exactly what was passed: `Part` -> `Part`,
--     `Instance?` -> `Instance?`, `nil` -> `nil`. (A separate optional overload doesn't work: the new solver reports
--     calls that match more than one overload as ambiguous.)
--  3. An explicit thread overload (threads aren't table-like, so they need their own).
-- Optional functions and threads are not covered; refine them before calling Add.
type AddFunction =
	& (<Ps..., Rs...>(self: Cleaner, trackable: (Ps...) -> Rs..., Ps...) -> (Ps...) -> Rs...)
	& (<T>(self: Cleaner, trackable: T & ({}?)) -> T)
	& ((self: Cleaner, trackable: thread) -> thread)

--- Tracks a value and returns it unchanged (type preserved).
--- If the value is a function, any extra arguments are stored and passed to it on teardown.
--- Extra arguments for anything other than a function are ignored.
Cleaner.Add = function(self: Cleaner, trackable: unknown, ...: unknown): unknown
	if trackable == nil then
		return trackable
	end

	if not isCleanable(trackable) then
		warn(
			debug.traceback(
				`[ Cleaner ] Ignoring untrackable value of type '{typeof(trackable)}' (no Destroy/Disconnect)`,
				2
			)
		)
		return trackable
	end

	if self._isCleaning then
		warn(
			debug.traceback(
				`[ Cleaner ] Add called during cleaning; '{typeof(trackable)}' will not be cleaned until the next Clean`,
				2
			)
		)
	end

	-- A Promise is untracked once it settles. One that has already settled has nothing left to cancel.
	if typeof(trackable) == "table" and isPromise(trackable :: { [unknown]: unknown }) then
		const promise = trackable :: any
		if promise:getStatus() ~= "Started" then
			return trackable
		end
		promise:finally(function()
			detach(self, trackable)
		end)
	end

	const args: PackedArgs | false = if typeof(trackable) == "function" and select("#", ...) > 0
		then table.pack(...)
		else false

	table.insert(self._tracked, trackable)
	table.insert(self._args, args)
	return trackable
end :: AddFunction

--- Stops tracking the most recently added entry matching `trackable`, then tears it down.
--- Returns true if an entry was found, false otherwise.
function Cleaner.Remove(self: Cleaner, trackable: unknown): boolean
	const found, args = detach(self, trackable)
	if found then
		cleanTrackable(trackable, args)
	end
	return found
end

--- Stops tracking the most recently added entry matching `trackable`, without tearing it down.
--- Returns true if an entry was found, false otherwise.
function Cleaner.Unlink(self: Cleaner, trackable: unknown): boolean
	const found = detach(self, trackable)
	return found
end

--- Tears down every tracked entry (see the module docs for order and guarantees) and leaves the Cleaner empty.
--- The Cleaner remains usable afterwards.
function Cleaner.Clean(self: Cleaner)
	-- Re-entrant call (self-tracking, a cycle, or teardown code calling Clean): the outer call owns this batch.
	if self._isCleaning then
		return
	end

	const tracked = self._tracked
	if #tracked == 0 then
		return
	end

	-- Detach the batch before running any teardown. Teardown code may call Add/Remove/Unlink on this Cleaner; those
	-- operate on the fresh arrays and can't shift indices in the batch being iterated.
	const args = self._args
	self._tracked = {}
	self._args = {}
	self._isCleaning = true

	for index = #tracked, 1, -1 do
		const trackable = tracked[index]
		if typeof(trackable) ~= "Instance" then
			cleanTrackable(trackable, args[index])
		end
	end

	for index = #tracked, 1, -1 do
		const trackable = tracked[index]
		if typeof(trackable) == "Instance" then
			cleanTrackable(trackable, false)
		end
	end

	self._isCleaning = false
end

Cleaner.Destroy = Cleaner.Clean

return Cleaner
