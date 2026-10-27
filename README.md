# staind

It's been awhile since you could tell your stdout from your stderr.

```sh
curl -sS httpbin.org/status/418 nope.invalid 2>$(staind)
```

![demo](demo.gif)

## Installation

### Homebrew

```sh
brew tap erietz/tap
brew install staind
```

### Debian / Ubuntu

Download the `.deb` package for your architecture from the
[latest release](https://github.com/erietz/staind/releases/latest) and install
it with `apt`:

```sh
# x86_64 (amd64)
sudo apt install ./staind_<version>_amd64.deb

# aarch64 (arm64)
sudo apt install ./staind_<version>_arm64.deb
```

### Arch Linux

Download the `.pkg.tar.zst` package for your architecture from the
[latest release](https://github.com/erietz/staind/releases/latest) and install
it with `pacman`:

```sh
# x86_64
sudo pacman -U staind-<version>-1-x86_64.pkg.tar.zst

# aarch64
sudo pacman -U staind-<version>-1-aarch64.pkg.tar.zst
```

### From source

To build and install from source (into `~/.local`):

```sh
git clone https://github.com/erietz/staind.git
cd staind
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

Or using [mise](https://mise.jdx.dev/):

```sh
mise run install
```

## Usage

```sh
cmd 2>$(staind)              # red (default)
cmd 2>$(staind yellow)       # any of the 8 colors, bright-<name>, or gray
cmd 2>$(staind 208)          # xterm 256-color index
cmd 2>$(staind '#ff0080')    # truecolor
cmd 2>$(staind -b -d cyan)   # -b bold, -d dim
```

Set `NO_COLOR` to pass stderr through uncolored. See `staind -h` for more.

## License

[GPL-3.0](./LICENSE)
