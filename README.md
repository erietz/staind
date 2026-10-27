# staind

It's been awhile since you could tell your stdout from your stderr.

```sh
curl -sS httpbin.org/status/418 nope.invalid 2>$(staind)
```

![demo](demo.gif)

## Usage

```sh
cmd 2>$(staind)              # red (default)
cmd 2>$(staind yellow)       # any of the 8 colors, bright-<name>, or gray
cmd 2>$(staind 208)          # xterm 256-color index
cmd 2>$(staind '#ff0080')    # truecolor
cmd 2>$(staind -b -d cyan)   # -b bold, -d dim
```

Set `NO_COLOR` to pass stderr through uncolored. See `staind -h` for more.
