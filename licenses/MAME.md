The machine's behaviour was taken from MAME's documentation of the hardware, in its sources
`src/mame/pacman/pacman.cpp`, `src/mame/pacman/pacman_v.cpp` (the Pac-Man and Ms. Pac-Man drivers) and
`src/devices/sound/namco.cpp` (the WSG), which are licensed BSD-3-Clause
(copyright-holders: Nicola Salmoria and the MAME contributors): https://github.com/mamedev/mame

What was taken is hardware fact, written again in PureMetal, Python and PureBasic - no MAME code is
included:

- the memory map and its mirrors, the I/O ports and the watchdog (`mspacman_map`);
- the auxiliary board's decryption (the bit swaps of u5, u6 and u7) and its patch addresses
  (`init_mspacman`, `mspacman_install_patches`), and the decode latch's trap addresses;
- the tile and sprite layouts, the tile scan order, the sprite clip and offsets, and the colour
  PROM's resistor weights (`pacman_palette`, `tilelayout`, `spritelayout`, `pacman_scan_rows`,
  `draw_sprites`);
- the WSG's voice registers, its 96 kHz step and the waveform PROM's use (`namco_audio_device`).

No ROM data is included: the program reads the user's own ROM set (see the README).
