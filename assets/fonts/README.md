# Desktop typography

Inter is Copyright 2020 The Inter Project Authors and is distributed under
the [SIL Open Font License 1.1](OFL-Inter.txt). The font and its generated
coverage atlas are font assets, not original OrangeOS kernel/toolkit code.

Source: [Inter on Google Fonts](https://github.com/google/fonts/tree/main/ofl/inter).
`Inter.ttf` is the upstream `Inter[opsz,wght].ttf`, downloaded 2026-09-06.

`python3 tools/fontconv/desktop_font.py` regenerates the checked-in ASCII
coverage atlas from this source using Pillow. It bakes 13px multiples through
104px for native 1x/2x drawing, weight 550, optical size 14. Normal builds need neither Pillow nor
network access. The disk image includes the font license under
`/share/licenses/OFL-Inter.txt`.

Terminal text uses JetBrains Mono, Copyright 2020 The JetBrains Mono Project
Authors, under [SIL OFL 1.1](OFL-JetBrainsMono.txt). Source:
[Google Fonts](https://github.com/google/fonts/tree/main/ofl/jetbrainsmono),
`JetBrainsMono[wght].ttf`, downloaded September 6, 2026. The generator bakes
13/26px at weight 450; its license is also included in the guest disk.
