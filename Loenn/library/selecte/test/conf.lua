-- conf.lua - headless LOVE config so `love Loenn/library/selecte/test` just runs the tests
-- and exits, no window/audio/graphics (see the conversation this test
-- harness was built in: `love.exe --console` doesn't reliably attach to a
-- calling process's stdout on Windows, so main.lua writes results to
-- test_report.txt instead of relying on console output).
function love.conf(t)
	t.window = false
	t.console = false
	t.modules.audio = false
	t.modules.graphics = false
	t.modules.window = false
	t.modules.joystick = false
	t.modules.touch = false
	t.modules.video = false
end
