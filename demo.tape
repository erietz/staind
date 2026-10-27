Output demo.gif

Set Shell bash
Set FontSize 18
Set Width 800
Set Height 640
Set Padding 20
Set TypingSpeed 40ms

Hide
Type "bind 'set show-mode-in-prompt off'; export PATH=$PWD/zig-out/bin:$PATH PS1='$ '; clear"
Enter
Show

Type "curl -sS httpbin.org/status/418 nope.invalid"
Enter
Sleep 2s

Type "curl -sS httpbin.org/status/418 nope.invalid 2>$(staind)"
Enter
Sleep 3s
