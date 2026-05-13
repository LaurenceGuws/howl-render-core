# Special Glyphs

Owner: `howl-render`

Purpose: generated special-glyph coverage table.

`covered` means `howl-render` produces a generated special sprite today. `exact math` means the generated geometry matches the local Kitty reference closely enough to treat it as the same construction.

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

## Notes

- Common terminal families are covered: box drawing, block elements, braille, sextants, octants, and the main Powerline separators.
- The larger Kitty-only generated surface is not covered: progress bars, spinners, smooth mosaics, half triangles, shade variants, eight-bars, mid-lines, and private-use UI glyphs.
- `U+1FB00..U+1FBAE` still routes through the legacy-computing classifier, but the rasterizer only handles sextants `U+1FB00..U+1FB3B` today. The rest remain unsupported.
- Box drawing is functional but not a full Kitty math port.
- `░▒▓` remain intentional uniform alpha masks.
- Braille remains an owner-local raster path, not a Kitty geometry port.
- The strongest exact ports are sextants, octant mask mapping, quadrants, and eighth-block distribution.

## References

- Kitty source: `/home/home/personal/zide/dev_references/terminals/kitty/kitty/decorations.c`
- `howl-render` rasterizer: `src/text/rasterizer.zig`
- `howl-render` symbol routing: `src/text/symbol_map.zig`
