# staind

It's been awhile since you could tell your stdout from your stderr.

```sh
curl -sS httpbin.org/status/418 nope.invalid 2>$(staind)
```

![demo](demo.gif)
