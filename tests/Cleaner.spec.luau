--!strict
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const LogService = game:GetService("LogService")
const TweenService = game:GetService("TweenService")

const JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
const Promise = require(ReplicatedStorage.DevPackages.Promise)
const describe = JestGlobals.describe
const it = JestGlobals.it
const expect = JestGlobals.expect

const Cleaner = require(ReplicatedStorage.Cleaner)

-- Destroy locks an Instance's Parent, so a destroyed Instance can't be reparented.
local function isDestroyed(instance: Instance): boolean
	const originalParent = instance.Parent
	const probe = Instance.new("Folder")
	const reparented = pcall(function()
		instance.Parent = probe
	end)
	if reparented then
		instance.Parent = originalParent
	end
	probe:Destroy()
	return not reparented
end

-- Runs `callback` and returns the Cleaner warnings it emitted. Waits a frame since MessageOut may be deferred.
local function captureWarnings(callback: () -> ()): { string }
	const warnings = {}
	const connection = LogService.MessageOut:Connect(function(message, messageType)
		if messageType == Enum.MessageType.MessageWarning and string.find(message, "[ Cleaner ]", 1, true) then
			table.insert(warnings, message)
		end
	end)
	callback()
	task.wait()
	connection:Disconnect()
	return warnings
end

-- A table with a Destroy method that counts its calls.
local function counter()
	const object = { calls = 0 }
	function object.Destroy(self: typeof(object))
		self.calls += 1
	end
	return object
end

describe("Add", function()
	it("returns its argument unchanged", function()
		const cleaner = Cleaner.new()
		const part = Instance.new("Part")
		const fn = function() end
		const thread = task.delay(60, fn)
		const object = counter()

		expect(cleaner:Add(part)).toBe(part)
		expect(cleaner:Add(fn)).toBe(fn)
		expect(cleaner:Add(thread)).toBe(thread)
		expect(cleaner:Add(object)).toBe(object)

		cleaner:Clean()
	end)

	it("ignores nil silently", function()
		const cleaner = Cleaner.new()
		const warnings = captureWarnings(function()
			expect(cleaner:Add(nil)).toBeNil()
		end)
		expect(#warnings).toBe(0)
		expect(#cleaner._tracked).toBe(0)
	end)

	it("ignores untrackable values with a warning", function()
		const cleaner = Cleaner.new()
		const plain = {}
		const warnings = captureWarnings(function()
			expect(cleaner:Add(plain)).toBe(plain)
			expect(cleaner:Add((5 :: any) :: nil)).toBe(5)
			expect(cleaner:Add(Vector3.zero)).toBe(Vector3.zero)
		end)
		expect(#warnings).toBe(3)
		expect(#cleaner._tracked).toBe(0)
	end)

	it("rejects tables whose cleanup field is not a function", function()
		const cleaner = Cleaner.new()
		captureWarnings(function()
			cleaner:Add({ Destroy = true })
		end)
		expect(#cleaner._tracked).toBe(0)
	end)

	it("does not run anything until cleaned", function()
		const cleaner = Cleaner.new()
		local ran = false
		cleaner:Add(function()
			ran = true
		end)
		expect(ran).toBe(false)
		cleaner:Clean()
		expect(ran).toBe(true)
	end)
end)

describe("Teardown by type", function()
	it("calls functions with their stored arguments, preserving nils", function()
		const cleaner = Cleaner.new()
		local received: { n: number, [number]: any }
		cleaner:Add(function(...)
			received = table.pack(...)
		end, 1, nil, 3)
		cleaner:Clean()

		expect(received.n).toBe(3)
		expect(received[1]).toBe(1)
		expect(received[2]).toBeNil()
		expect(received[3]).toBe(3)
	end)

	it("calls functions added without arguments with none", function()
		const cleaner = Cleaner.new()
		local count
		cleaner:Add(function(...)
			count = select("#", ...)
		end)
		cleaner:Clean()
		expect(count).toBe(0)
	end)

	it("cancels threads", function()
		const cleaner = Cleaner.new()
		local resumed = false
		const thread = cleaner:Add(task.delay(0, function()
			resumed = true
		end))
		cleaner:Clean()
		task.wait()

		expect(resumed).toBe(false)
		expect(coroutine.status(thread)).toBe("dead")
	end)

	it("disconnects RBXScriptConnections", function()
		const cleaner = Cleaner.new()
		const event = Instance.new("BindableEvent")
		const connection = cleaner:Add(event.Event:Connect(function() end))
		cleaner:Clean()

		expect(connection.Connected).toBe(false)
		event:Destroy()
	end)

	it("destroys Instances immediately", function()
		const cleaner = Cleaner.new()
		const part = cleaner:Add(Instance.new("Part"))
		cleaner:Clean()
		expect(isDestroyed(part)).toBe(true)
	end)

	it("cancels Tweens immediately and destroys them a frame later", function()
		const cleaner = Cleaner.new()
		const part = Instance.new("Part")
		const tween = TweenService:Create(part, TweenInfo.new(10), { Transparency = 1 })
		tween:Play()

		cleaner:Add(tween)
		cleaner:Clean()

		expect(tween.PlaybackState).toBe(Enum.PlaybackState.Cancelled)
		expect(isDestroyed(tween)).toBe(false)

		task.wait()
		expect(isDestroyed(tween)).toBe(true)
		part:Destroy()
	end)

	for _, name in { "Destroy", "Disconnect", "destroy", "disconnect" } do
		it(`calls a table's {name} method with the table as self`, function()
			const cleaner = Cleaner.new()
			const object = {}
			local receivedSelf
			object[name] = function(self)
				receivedSelf = self
			end

			cleaner:Add(object)
			cleaner:Clean()
			expect(receivedSelf).toBe(object)
		end)
	end

	it("prefers Destroy over Disconnect when both exist", function()
		const cleaner = Cleaner.new()
		local called
		cleaner:Add({
			Destroy = function()
				called = "Destroy"
			end,
			Disconnect = function()
				called = "Disconnect"
			end,
		})
		cleaner:Clean()
		expect(called).toBe("Destroy")
	end)

	it("skips a non-function Destroy field and uses the next method", function()
		const cleaner = Cleaner.new()
		local called = false
		cleaner:Add({
			Destroy = true,
			Disconnect = function()
				called = true
			end,
		})
		cleaner:Clean()
		expect(called).toBe(true)
	end)

	it("finds methods through metatables (class instances)", function()
		const Class = {}
		Class.__index = Class
		function Class:Destroy()
			self.destroyed = true
		end

		const cleaner = Cleaner.new()
		const object = cleaner:Add(setmetatable({ destroyed = false }, Class))
		cleaner:Clean()
		expect(object.destroyed).toBe(true)
	end)

	it("accepts a class whose __index throws on unknown keys", function()
		const Class = {}
		function Class:Disconnect()
			self.disconnected = true
		end
		const strictMeta = {
			__index = function(_, key)
				const value = Class[key]
				if value == nil then
					error(`strict: unknown key '{key}'`)
				end
				return value
			end,
		}

		const cleaner = Cleaner.new()
		const object = setmetatable({ disconnected = false }, strictMeta)
		cleaner:Add(object)
		expect(#cleaner._tracked).toBe(1)

		cleaner:Clean()
		expect(rawget(object, "disconnected")).toBe(true)
	end)

	it("cleans nested Cleaners", function()
		const outer = Cleaner.new()
		const inner = outer:Add(Cleaner.new())
		const object = inner:Add(counter())

		outer:Clean()
		expect(object.calls).toBe(1)
		expect(#inner._tracked).toBe(0)
	end)
end)

describe("Promises", function()
	it("cancels a pending Promise", function()
		const cleaner = Cleaner.new()
		const promise = cleaner:Add(Promise.new(function() end))
		cleaner:Clean()
		expect(promise:getStatus()).toBe("Cancelled")
	end)

	it("untracks a Promise when it settles", function()
		const cleaner = Cleaner.new()
		local resolve: (() -> ())?
		cleaner:Add(Promise.new(function(innerResolve)
			resolve = innerResolve
		end))
		expect(#cleaner._tracked).toBe(1)

		assert(resolve, "the Promise executor should have run")()
		task.wait()
		expect(#cleaner._tracked).toBe(0)
		expect(#cleaner._args).toBe(0)
	end)

	it("does not track a Promise that has already settled", function()
		const cleaner = Cleaner.new()
		const promise = Promise.resolve()
		const warnings = captureWarnings(function()
			expect(cleaner:Add(promise)).toBe(promise)
		end)
		expect(#warnings).toBe(0)
		expect(#cleaner._tracked).toBe(0)
	end)

	it("Remove cancels a pending Promise", function()
		const cleaner = Cleaner.new()
		const promise = cleaner:Add(Promise.new(function() end))
		expect(cleaner:Remove(promise)).toBe(true)
		expect(promise:getStatus()).toBe("Cancelled")
	end)

	it("Unlink leaves a pending Promise running", function()
		const cleaner = Cleaner.new()
		const promise = cleaner:Add(Promise.new(function() end))
		expect(cleaner:Unlink(promise)).toBe(true)
		cleaner:Clean()
		expect(promise:getStatus()).toBe("Started")
		-- Cast: the untyped Promise library's inferred method types don't check under strict mode.
		const untypedPromise: any = promise
		untypedPromise:cancel()
	end)
end)

describe("Order", function()
	it("tears down in LIFO order", function()
		const cleaner = Cleaner.new()
		const order = {}
		for i = 1, 5 do
			cleaner:Add(function()
				table.insert(order, i)
			end)
		end
		cleaner:Clean()
		expect(table.concat(order, ",")).toBe("5,4,3,2,1")
	end)

	it("tears down all non-Instances before any Instance", function()
		const cleaner = Cleaner.new()
		const part = Instance.new("Part")
		local partAliveWhenFunctionRan

		-- Added before the part, so plain LIFO would destroy the part first.
		cleaner:Add(function()
			partAliveWhenFunctionRan = not isDestroyed(part)
		end)
		cleaner:Add(part)
		cleaner:Clean()

		expect(partAliveWhenFunctionRan).toBe(true)
		expect(isDestroyed(part)).toBe(true)
	end)
end)

describe("Remove and Unlink", function()
	it("Remove tears down immediately and stops tracking", function()
		const cleaner = Cleaner.new()
		const object = cleaner:Add(counter())

		expect(cleaner:Remove(object)).toBe(true)
		expect(object.calls).toBe(1)

		cleaner:Clean()
		expect(object.calls).toBe(1)
	end)

	it("Unlink stops tracking without tearing down", function()
		const cleaner = Cleaner.new()
		const object = cleaner:Add(counter())

		expect(cleaner:Unlink(object)).toBe(true)
		cleaner:Clean()
		expect(object.calls).toBe(0)
	end)

	it("return false for values that are not tracked", function()
		const cleaner = Cleaner.new()
		expect(cleaner:Remove(counter())).toBe(false)
		expect(cleaner:Unlink(counter())).toBe(false)
	end)

	it("Remove passes the stored arguments", function()
		const cleaner = Cleaner.new()
		local received
		const fn = cleaner:Add(function(value)
			received = value
		end, "arg")

		cleaner:Remove(fn)
		expect(received).toBe("arg")
	end)

	it("keep the parallel arrays aligned after removing from the middle", function()
		const cleaner = Cleaner.new()
		const calls = {}
		const record = function(label)
			table.insert(calls, label)
		end
		const middle = function() end

		cleaner:Add(record, "a")
		cleaner:Add(middle)
		cleaner:Add(record, "c")
		cleaner:Unlink(middle)

		expect(#cleaner._tracked).toBe(#cleaner._args)
		cleaner:Clean()
		expect(table.concat(calls, ",")).toBe("c,a")
	end)
end)

describe("Duplicates", function()
	it("tears down a duplicated object once per entry", function()
		const cleaner = Cleaner.new()
		const object = counter()
		cleaner:Add(object)
		cleaner:Add(object)
		cleaner:Clean()
		expect(object.calls).toBe(2)
	end)

	it("keeps separate arguments for each entry of a duplicated function", function()
		const cleaner = Cleaner.new()
		const calls = {}
		const tweenOut = function(target, duration)
			table.insert(calls, `{target}:{duration}`)
		end

		cleaner:Add(tweenOut, "frameA", 3)
		cleaner:Add(tweenOut, "frameB", 2)
		cleaner:Clean()
		expect(table.concat(calls, ",")).toBe("frameB:2,frameA:3")
	end)

	it("keeps arguments separate when only one entry has arguments", function()
		const cleaner = Cleaner.new()
		const calls = {}
		const fn = function(...)
			table.insert(calls, select("#", ...))
		end

		cleaner:Add(fn)
		cleaner:Add(fn, "x")
		cleaner:Clean()
		expect(table.concat(calls, ",")).toBe("1,0")
	end)

	it("Unlink removes the most recently added entry", function()
		const cleaner = Cleaner.new()
		const calls = {}
		const fn = function(label)
			table.insert(calls, label)
		end

		cleaner:Add(fn, "first")
		cleaner:Add(fn, "second")
		cleaner:Unlink(fn)
		cleaner:Clean()
		expect(table.concat(calls, ",")).toBe("first")
	end)

	it("Remove takes one entry per call, most recent first", function()
		const cleaner = Cleaner.new()
		const calls = {}
		const fn = function(label)
			table.insert(calls, label)
		end

		cleaner:Add(fn, "first")
		cleaner:Add(fn, "second")
		expect(cleaner:Remove(fn)).toBe(true)
		expect(cleaner:Remove(fn)).toBe(true)
		expect(cleaner:Remove(fn)).toBe(false)
		expect(table.concat(calls, ",")).toBe("second,first")
	end)
end)

describe("Clean", function()
	it("leaves the Cleaner empty and reusable", function()
		const cleaner = Cleaner.new()
		cleaner:Add(counter())
		cleaner:Clean()
		expect(#cleaner._tracked).toBe(0)
		expect(#cleaner._args).toBe(0)

		const object = cleaner:Add(counter())
		cleaner:Clean()
		expect(object.calls).toBe(1)
	end)

	it("does nothing on an empty Cleaner", function()
		const cleaner = Cleaner.new()
		expect(function()
			cleaner:Clean()
			cleaner:Clean()
		end).never.toThrow()
	end)

	it("does not tear down an entry twice across repeated Cleans", function()
		const cleaner = Cleaner.new()
		const object = cleaner:Add(counter())
		cleaner:Clean()
		cleaner:Clean()
		expect(object.calls).toBe(1)
	end)

	it("is aliased as Destroy", function()
		expect(Cleaner.Destroy).toBe(Cleaner.Clean)
	end)
end)

describe("Errors", function()
	-- These tests intentionally print errors to the output from the spawned teardown threads.

	it("does not throw or stop when a function errors", function()
		const cleaner = Cleaner.new()
		const object = cleaner:Add(counter())
		cleaner:Add(function()
			error("intentional test error (function)")
		end)

		expect(function()
			cleaner:Clean()
		end).never.toThrow()
		expect(object.calls).toBe(1)
	end)

	it("does not throw or stop when a table's cleanup method errors", function()
		const cleaner = Cleaner.new()
		const object = cleaner:Add(counter())
		cleaner:Add({
			Destroy = function()
				error("intentional test error (table)")
			end,
		})

		expect(function()
			cleaner:Clean()
		end).never.toThrow()
		expect(object.calls).toBe(1)
	end)

	it("is still usable after a teardown error", function()
		const cleaner = Cleaner.new()
		cleaner:Add(function()
			error("intentional test error (reuse)")
		end)
		cleaner:Clean()

		const object = cleaner:Add(counter())
		cleaner:Clean()
		expect(object.calls).toBe(1)
	end)

	it("skips a thread that cannot be cancelled (the running thread)", function()
		const cleaner = Cleaner.new()
		local cleanSucceeded
		task.spawn(function()
			cleaner:Add(coroutine.running())
			cleanSucceeded = pcall(cleaner.Clean, cleaner)
		end)
		expect(cleanSucceeded).toBe(true)

		const object = cleaner:Add(counter())
		cleaner:Clean()
		expect(object.calls).toBe(1)
	end)
end)

describe("Timing", function()
	it("never yields, even when teardown yields", function()
		const cleaner = Cleaner.new()
		local beforeYield, afterYield = false, false
		cleaner:Add(function()
			beforeYield = true
			task.wait(0.1)
			afterYield = true
		end)
		cleaner:Add({
			Destroy = function()
				task.wait(0.1)
			end,
		})

		const start = os.clock()
		cleaner:Clean()
		expect(os.clock() - start).toBeLessThan(0.05)

		-- Teardown runs synchronously up to its first yield, then finishes on its own.
		expect(beforeYield).toBe(true)
		expect(afterYield).toBe(false)
		task.wait(0.2)
		expect(afterYield).toBe(true)
	end)

	it("runs non-yielding teardown before Clean returns", function()
		const cleaner = Cleaner.new()
		const object = cleaner:Add(counter())
		local ran = false
		cleaner:Add(function()
			ran = true
		end)
		cleaner:Clean()
		expect(ran).toBe(true)
		expect(object.calls).toBe(1)
	end)
end)

describe("Re-entrancy", function()
	it("handles a Cleaner that tracks itself", function()
		const cleaner = Cleaner.new()
		const object = cleaner:Add(counter())
		cleaner:Add(cleaner)

		expect(function()
			cleaner:Clean()
		end).never.toThrow()
		expect(object.calls).toBe(1)
		expect(#cleaner._tracked).toBe(0)
	end)

	it("handles two Cleaners that track each other", function()
		const a = Cleaner.new()
		const b = Cleaner.new()
		const objectA = a:Add(counter())
		const objectB = b:Add(counter())
		a:Add(b)
		b:Add(a)

		a:Clean()
		expect(objectA.calls).toBe(1)
		expect(objectB.calls).toBe(1)
		expect(#a._tracked).toBe(0)
		expect(#b._tracked).toBe(0)
	end)

	it("treats Clean called from teardown as a no-op", function()
		const cleaner = Cleaner.new()
		const object = cleaner:Add(counter())
		cleaner:Add(function()
			cleaner:Clean()
		end)
		cleaner:Clean()
		expect(object.calls).toBe(1)
	end)

	it("warns on Add during cleaning and keeps the value for the next Clean", function()
		const cleaner = Cleaner.new()
		local lateRuns = 0
		const late = function()
			lateRuns += 1
		end
		cleaner:Add(function()
			cleaner:Add(late)
		end)

		const warnings = captureWarnings(function()
			cleaner:Clean()
		end)
		expect(#warnings).toBe(1)
		expect(lateRuns).toBe(0)
		expect(#cleaner._tracked).toBe(1)

		cleaner:Clean()
		expect(lateRuns).toBe(1)
	end)

	it("returns false from Remove/Unlink for entries in the batch being cleaned, which are still cleaned", function()
		const cleaner = Cleaner.new()
		const object = cleaner:Add(counter())
		local removeResult, unlinkResult
		cleaner:Add(function()
			removeResult = cleaner:Remove(object)
			unlinkResult = cleaner:Unlink(object)
		end)

		cleaner:Clean()
		expect(removeResult).toBe(false)
		expect(unlinkResult).toBe(false)
		expect(object.calls).toBe(1)
	end)

	it("does not skip or repeat entries when teardown Removes from the Cleaner", function()
		const cleaner = Cleaner.new()
		const objects = {}
		for i = 1, 3 do
			objects[i] = cleaner:Add(counter())
		end
		cleaner:Add(function()
			cleaner:Remove(objects[1])
		end)

		cleaner:Clean()
		for i = 1, 3 do
			expect(objects[i].calls).toBe(1)
		end
	end)
end)
