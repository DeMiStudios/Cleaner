# Cleaner

A cleanup manager for Roblox, filling the same role as Trove, Maid and Janitor. Track connections, Instances,
threads, cleanup functions and objects, then tear them all down with one call.

```lua
const Cleaner = require(ReplicatedStorage.Packages.Cleaner)

const cleaner = Cleaner.new()
const part = cleaner:Add(Instance.new("Part")) -- returns its argument, type preserved
cleaner:Add(part.Touched:Connect(onTouched))
cleaner:Add(TweenOut, frameA, 3) -- runs TweenOut(frameA, 3) on cleanup
cleaner:Add(TweenOut, frameB, 2) -- the same function can be tracked again with other args
cleaner:Clean() -- tears everything down; the Cleaner is empty and reusable
```

## Installation

With [Wally](https://wally.run), add Cleaner to your `wally.toml`:

```toml
[dependencies]
Cleaner = "demistudios/cleaner@0.1.0"
```

## Requirements

Cleaner is written for current Luau and targets the **new type solver**:

- It uses `const` declarations, so it needs a Luau version (and tooling, if you lint or format your `Packages`
  folder) that supports them.
- Its types use `setmetatable<...>` and generic overloads, which the old type solver doesn't understand. The old
  solver is not supported.

## Guarantees

1. **`Clean` never throws and never yields.** Errors raised during teardown are printed to the output, but they
   never stop cleaning or reach the caller. Teardown code that yields runs on its own thread and finishes later.
2. **LIFO order:** entries are torn down in reverse insertion order, with every non-Instance torn down before any
   Instance.
3. **AnimationTracks and Tweens:** they are stopped or cancelled immediately, then destroyed one frame later, so
   their `Stopped`/`Completed` events still fire.
4. **Empty afterwards:** when `Clean` returns, everything that was tracked has been torn down (or started teardown,
   if it yields), and the Cleaner is empty. The one exception is a value added by teardown code during the `Clean`
   (see [Adding during cleaning](#edge-cases)), which is strongly discouraged.
5. **Typed:** `Add` returns exactly the type it was given, and the extra arguments of a tracked function are
   type-checked against that function.

## API

| Method | Description |
|---|---|
| `Cleaner.new()` | Creates an empty Cleaner. |
| `cleaner:Add(value, ...)` | Tracks `value` and returns it unchanged. For a function, any extra arguments are passed to it on cleanup. `nil` is ignored. |
| `cleaner:Remove(value)` | Stops tracking the most recently added matching entry and tears it down now. Returns whether one was found. |
| `cleaner:Unlink(value)` | Stops tracking the most recently added matching entry *without* tearing it down. Returns whether one was found. |
| `cleaner:Clean()` | Tears down everything. The Cleaner can be reused afterwards. |
| `cleaner:Destroy()` | Same as `Clean`, so a Cleaner can be tracked by another Cleaner. |

## How each type is torn down

| Type | Teardown |
|---|---|
| `function` | Called on a new thread with the extra arguments given to `Add`. |
| `thread` | Cancelled. A thread that can't be cancelled (for example, the running thread) is skipped. |
| `RBXScriptConnection` | Disconnected. |
| `table` | The first of `Destroy`, `Disconnect`, `destroy`, `disconnect` that is a function is called as a method, on a new thread. This covers classes, custom signal connections and nested Cleaners. |
| Promise | Cancelled. Any table with `cancel`, `getStatus` and `finally` methods counts, such as [evaera's Promise](https://github.com/evaera/roblox-lua-promise). A Promise that has already settled isn't tracked, and a tracked Promise is untracked automatically when it settles. |
| `Instance` | Destroyed. AnimationTracks and Tweens are stopped first (see guarantee 3). |

Any other value (a plain table, a number, a `Vector3`, ...) has nothing to tear down, so `Add` ignores it and warns.

## Edge cases

- **Duplicates:** the same value can be tracked more than once, and every entry is torn down. A function tracked
  twice keeps separate arguments for each entry. `Remove` and `Unlink` take the most recently added entry, one per
  call.
- **Re-entrancy:** calling `Clean` while the same Cleaner is already cleaning does nothing. A Cleaner can track
  itself, and two Cleaners can track each other.
- **Adding during cleaning:** if teardown code calls `Add` on the Cleaner being cleaned, a warning is printed and the
  value is kept for the next `Clean`. Only synchronous calls are caught: an `Add` made after a yield, or from a
  deferred event handler, simply arrives after `Clean` has returned.
- **Remove or Unlink during cleaning:** the entries being cleaned are detached before teardown starts, so `Remove` and
  `Unlink` return `false` for them, and they are still torn down as normal.
- **Event ordering:** connections are torn down before Instances, so a tracked connection to a tracked Instance's
  own event (such as an AnimationTrack's `Stopped`) does not fire during cleanup. To run something at cleanup time,
  track a function instead.
- **Removed cleanup methods:** a table whose cleanup method was removed after it was added is skipped silently.
- **Optional values:** `Add(maybeInstance)` returns `Instance?`. Optional functions and threads aren't accepted by
  the types; check for `nil` before adding them.
- **`any` values:** a value typed `any` matches more than one of `Add`'s overloads, which the type checker reports
  as ambiguous. Cast it to its real type first, for example `cleaner:Add(value :: Instance)`.

## Development

Tools are managed by [Rokit](https://github.com/rojo-rbx/rokit). Run `rokit install`, then `wally install`.

Formatting is checked with StyLua (`stylua --check src tests`) and types with luau-lsp. The
[CI workflow](.github/workflows/ci.yml) runs both, plus the tests.

### Running the tests in Studio

1. Build the test place with `rojo build test.project.json -o tests.rbxl`, or serve it with
   `rojo serve test.project.json`, and open it in Studio.
2. Run this in the command bar:

   ```lua
   loadstring(game.ReplicatedStorage.Tests.Bootstrap.Source)()
   ```

The suite uses [Jest Roblox](https://github.com/Roblox/jest-roblox). It runs from the command bar because Jest needs
plugin-level access to read module sources; this avoids having to enable `FFlagEnableLoadModule`.

### Running the tests in CI

CI runs the suite on Roblox servers with [Open Cloud Luau Execution](https://create.roblox.com/docs/cloud/reference/LuauExecutionSessionTask):
[`scripts/run-cloud-tests.py`](scripts/run-cloud-tests.py) uploads the built test place as a new version of a test
place, runs `Tests.Runner` in it, and prints the output. The test place has `LoadStringEnabled` turned on so Jest can
load module sources there. To set it up:

1. Create a private experience to run the tests in, and note its universe ID and place ID.
2. Create an Open Cloud API key for that experience with the `universe-places:write` and
   `universe.place.luau-execution-session:write` permissions.
3. In the GitHub repository settings, add the key as the `ROBLOX_API_KEY` secret, and the IDs as the
   `ROBLOX_UNIVERSE_ID` and `ROBLOX_PLACE_ID` variables.

Without the secret (for example, in pull requests from forks), the test job is skipped. The script can also be run
locally with the same three environment variables.

## License

MIT. See [LICENSE](LICENSE).
