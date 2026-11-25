# Dobby

The iOS build links Dobby statically for one narrowly scoped use: intercepting
Arizona's exported `ui_input_end` text-submit entry so registered Loader
commands can be consumed locally and unknown input can continue to the game.

GitHub Actions downloads the pinned upstream revision
`5dfc8546954ce3b3198132ab13fddb89ee92cdd7` during the build. The upstream
license is included in this directory.

Upstream: https://github.com/jmpews/Dobby
