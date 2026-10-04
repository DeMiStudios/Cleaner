--!strict
-- Runs the Cleaner Jest suite. Invoke from the command bar (it needs plugin-level access to read module sources):
--     loadstring(game.ReplicatedStorage.Tests.Bootstrap.Source)()
-- This project doesn't set `emitLegacyScripts = false`, so this is a legacy Script, which never runs on its own from
-- ReplicatedStorage.

--// Services
const ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Imports
const runTests = require(ReplicatedStorage.Tests.Runner)

runTests({ ci = false })
