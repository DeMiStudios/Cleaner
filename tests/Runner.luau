--!strict
-- Runs the Cleaner Jest suite and returns whether every test passed. Used from Studio by Bootstrap, and from CI by
-- scripts/run-cloud-tests.py (through Open Cloud Luau Execution).

--// Services
const ReplicatedStorage = game:GetService("ReplicatedStorage")

--// Imports
const Jest = require(ReplicatedStorage.DevPackages.Jest) :: any

return function(options: { ci: boolean }): boolean
	-- The project root is the Tests folder; jest.config (next to this module) sets which modules are specs.
	const root = ReplicatedStorage.Tests
	const status, result = Jest.runCLI(root, { verbose = true, ci = options.ci }, { root }):awaitStatus()

	if status == "Rejected" then
		warn(`[ Cleaner tests ] Jest failed to run: {result}`)
		return false
	elseif result.results.numFailedTestSuites > 0 or result.results.numFailedTests > 0 then
		warn(`[ Cleaner tests ] {result.results.numFailedTests} test(s) failed`)
		return false
	end
	return true
end
