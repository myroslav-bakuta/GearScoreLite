"""Run the GearScoreLite test suite under a genuine Lua 5.1 runtime."""
import sys, os
from lupa import lua51

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

rt = lua51.LuaRuntime(unpack_returned_tuples=True)
print("Runtime:", rt.lua_implementation, rt.eval("_VERSION"))
print("-" * 60)

# os.exit() would tear down the host process before output is flushed; capture
# the intended exit code instead. The suite replaces `print` with the mock's
# capturing version, so test output goes through io.write, not print.
code = {"v": 0}
rt.globals().os.exit = lambda c=0, *a: code.__setitem__("v", 0 if c is True else (1 if c is False else int(c)))

try:
    rt.execute(open(".luatest/run_tests.lua", encoding="utf-8").read())
except Exception as e:
    print("LUA ERROR:", e)
    sys.exit(2)

sys.exit(code["v"])
