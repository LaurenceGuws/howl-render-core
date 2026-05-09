# Special Glyph Audit

`covered` means Howl routes and rasterizes the glyph through generated-special handling. `exact math` means Howl copied Kitty's actual geometry/math closely enough to call it exact, not just visually similar.

| Kitty Glyphs | Family | Covered | Exact Math |
|---|---:|---:|---:|
| `█` | full block | true | true |
| `─━│┃` | basic box lines | true | false |
| `╌╍┄┅┈┉╎╏┆┇┊┋` | dashed/dotted box lines | true | false |
| `╴╵╶╷╸╹╺╻╾╼╿╽` | half/mixed half box lines | true | false |
| `┌┍┎┏┐┑┒┓└┕┖┗┘┙┚┛` | box corners | true | false |
| `├...┫`, `┬...┻`, `┼...╋` | tees/crosses | true | false |
| `═║╒╓╔╕╖╗╘╙╚╛╜╝╞╟╠╡╢╣╤╥╦╧╨╩╪╫╬` | double/mixed box lines | true | false |
| `╭╮╰╯` | rounded box corners | true | false |
| `╱╲╳` | diagonals | true | false |
| `` | powerline triangles | true | false |
| `` | inverted powerline triangles | false | false |
| `` | powerline half separators | true | false |
| `` | filled powerline D | true | false |
| `◗◖` | filled D aliases | false | false |
| `` | rounded powerline separators | true | false |
| `` | powerline cross-line aliases | true | false |
| `` | powerline corner triangles | true | false |
| `◣◢◤◥` | corner triangle aliases | false | false |
| `` | progress bars | false | false |
| `` | private-use spinners | false | false |
| `○◜◝◞◟◠◡●◉` | circle/spinner symbols | false | false |
| `▔▀▁▂▃▄▅▆▇▉▊▋▌▍▎▏▕▐` | eighth blocks | true | true |
| `░▒▓` | shades | true | false |
| `🮌🮍🮎🮏🮐🮑🮒🮓🮔🮕🮖🮗` | legacy shade variants | false | false |
| `🮜🮝🮞🮟` | masked shaded corner triangles | false | false |
| `🮘🮙` | cross shade | false | false |
| `▖▗▘▝▙▚▛▜▞▟` | quadrants | true | true |
| `🬼...🭧` | smooth mosaics | false | false |
| `🭨🭩🭪🭫🭬🮛🭭🭮🭯🮚` | half triangles | false | false |
| `🭼🭽🭾🭿🮀🮁` | combined eight-bars | false | false |
| `🮂🮃🮄🮅🮆🮇🮈🮉🮊🮋` | extra eighth blocks | false | false |
| `🮠...🮮` | mid-lines | false | false |
| `` | private-use straight/fading lines | false | false |
| `` | private-use rounded corners | false | false |
| `...` | private-use rounded line composites | false | false |
| `...` | private-use commit glyphs | false | false |
| `⠀...⣿` (`U+2800..U+28FF`) | braille | true | false |
| `🬀...🬓`, `🬔...🬧`, `🬨...🬻` | sextants | true | true |
| `🭰...🭵`, `🭶...🭻` | eight-bars ranges | false | false |
| `U+1CD00..U+1CDE5`, `🯦🯧` | octants | true | true |

## Key Findings

- Howl covers the common terminal families: box drawing, block elements, braille, sextants, octants, and main Powerline glyphs.
- Howl does not cover a large Kitty-only surface area: progress bars, spinners, smooth mosaics, half triangles, shade variants, eight-bars, mid-lines, and private-use UI glyphs.
- Howl routes `U+1FB00..U+1FBAE` as legacy computing, but the rasterizer only actually handles sextants `U+1FB00..U+1FB3B`; other routed glyphs can still fall through as unsupported.
- Box drawing is not exact Kitty math. It is closer after the connector fix, but still uses Howl/Ghostty-style generic composition rather than Kitty's full helper dispatch.
- Shades are intentionally not Kitty exact: `░▒▓` are uniform alpha masks for btop TTY graph quality.
- Braille is not Kitty exact: it follows Ghostty-style robust dot placement and anti-aliasing.
- The strongest exact ports are sextants, octant mask mapping, quadrants, and eighth-block distribution.

## References

- Kitty source: `/home/home/personal/zide/dev_references/terminals/kitty/kitty/decorations.c`
- Howl rasterizer: `src/text/rasterizer.zig`
- Howl built-in route map: `src/text/symbol_map.zig`
