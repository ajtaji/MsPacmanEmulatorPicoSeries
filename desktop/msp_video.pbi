; Ms. Pac-Man video for the desktop: the tile layer and eight sprites into a 224 x 288 RGBA frame,
; in the player's (portrait) orientation - the arcade monitor is turned on its side (MAME ROT90).
; The same decode and rules as rp2040/video.pico (which tools/grab.py checks against an
; independent MAME-style drawing):
;   tile cell (x 0..27, y 0..35)  <- video RAM offset TileAddr(y*28+x)  (pacman_scan_rows, turned)
;   tile pixel (lx, ly)           <- native pixel (px = ly, py = 7 - lx)
;   sprite pixel (lx, ly)         <- native pixel (px = ly, py = 15 - lx)
; Sprites in MAME's order (7..3, then 2..0 one pixel over), each also 256 lines up (wraparound),
; clipped to the picture's lines 16..271; a pen whose colour-PROM entry is 0 is transparent.

EnableExplicit

#VID_W = 224
#VID_H = 288

Global Dim VidTile.a(255, 63)           ; [tile][ly*8+lx] -> 0..3
Global Dim VidSprite.a(63, 255)         ; [sprite][ly*16+lx] -> 0..3
Global Dim VidPalette.l(31)             ; RGBA (bytes R, G, B, A in memory)
Global Dim VidTileRgba.l(31, 3)         ; [colour set][pen]
Global Dim VidSprRgba.l(31, 3)          ; 0 = transparent
Global Dim VidTileAddr.i(1007)
Global Dim VidFrame.l(#VID_W * #VID_H - 1)

Procedure.i VidBit(*base, offset.i)
  ProcedureReturn (PeekA(*base + (offset >> 3)) >> (7 - (offset & 7))) & 1
EndProcedure

Procedure.i VidTilePixel(*rom, tile.i, px.i, py.i)
  Protected offset.i = py * 8 + (px & 3)
  If px < 4 : offset + 64 : EndIf
  ProcedureReturn (VidBit(*rom + tile * 16, offset) << 1) | VidBit(*rom + tile * 16, offset + 4)
EndProcedure

Procedure.i VidSpritePixel(*rom, sprite.i, px.i, py.i)
  Protected offset.i
  Select px >> 2
    Case 0 : offset = 64
    Case 1 : offset = 128
    Case 2 : offset = 192
    Default : offset = 0
  EndSelect
  offset + (px & 3) + (py & 7) * 8
  If py >= 8 : offset + 256 : EndIf
  ProcedureReturn (VidBit(*rom + sprite * 64, offset) << 1) | VidBit(*rom + sprite * 64, offset + 4)
EndProcedure

Procedure.l VidRgba(prom.i)
  Protected r.i, g.i, b.i
  r = (prom & 1) * $21 + ((prom >> 1) & 1) * $47 + ((prom >> 2) & 1) * $97
  g = ((prom >> 3) & 1) * $21 + ((prom >> 4) & 1) * $47 + ((prom >> 5) & 1) * $97
  b = ((prom >> 6) & 1) * $51 + ((prom >> 7) & 1) * $AE
  ProcedureReturn r | (g << 8) | (b << 16) | ($FF << 24)
EndProcedure

; The same RGB565 the Pico draws (for comparing a frame with tools/grab.py's reference).
Procedure.i VidRgb565(rgba.l)
  Protected r.i = rgba & 255, g.i = (rgba >> 8) & 255, b.i = (rgba >> 16) & 255
  ProcedureReturn ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
EndProcedure

Procedure VideoDecode(*tiles, *sprites, *colours, *lookup)
  Protected t.i, lx.i, ly.i, x.i, y.i, set.i, v.i, k.i, row.i
  For t = 0 To 255
    For ly = 0 To 7 : For lx = 0 To 7
      VidTile(t, ly * 8 + lx) = VidTilePixel(*tiles, t, ly, 7 - lx)
    Next : Next
  Next
  For t = 0 To 63
    For ly = 0 To 15 : For lx = 0 To 15
      VidSprite(t, ly * 16 + lx) = VidSpritePixel(*sprites, t, ly, 15 - lx)
    Next : Next
  Next
  For k = 0 To 31 : VidPalette(k) = VidRgba(PeekA(*colours + k)) : Next
  For set = 0 To 31
    For v = 0 To 3
      k = PeekA(*lookup + set * 4 + v) & 15
      VidTileRgba(set, v) = VidPalette(k)
      If k = 0 : VidSprRgba(set, v) = 0 : Else : VidSprRgba(set, v) = VidPalette(k) : EndIf
    Next
  Next
  For y = 0 To 35
    For x = 0 To 27
      row = 29 - x
      If y < 2
        VidTileAddr(y * 28 + x) = row + ((30 + y) << 5)
      ElseIf y > 33
        VidTileAddr(y * 28 + x) = row + ((y - 34) << 5)
      Else
        VidTileAddr(y * 28 + x) = (y - 2) + (row << 5)
      EndIf
    Next
  Next
EndProcedure

Procedure VidDrawSprite(code.i, set.i, fx.i, fy.i, x0.i, y0.i)
  Protected lx.i, ly.i, x.i, y.i, sy.i, sx.i, c.l
  For ly = 0 To 15
    y = y0 + ly
    If y < 16 Or y > 271 : Continue : EndIf
    sy = ly : If fx : sy = 15 - ly : EndIf
    For lx = 0 To 15
      x = x0 + lx
      If x < 0 Or x > 223 : Continue : EndIf
      sx = lx : If fy : sx = 15 - lx : EndIf
      c = VidSprRgba(set, VidSprite(code, sy * 16 + sx))
      If c : VidFrame(y * #VID_W + x) = c : EndIf
    Next
  Next
EndProcedure

; The frame from the machine's state: video RAM, colour RAM, $4FF0 sprites, $5060 positions.
Procedure VideoRender()
  Protected ty.i, tx.i, a.i, code.i, set.i, ly.i, lx.i, base.i, i.i, attr.i, sx.i, sy.i, copy.i
  For ty = 0 To 35
    For tx = 0 To 27
      a = VidTileAddr(ty * 28 + tx)
      code = Z80Mem($4000 + a) : set = Z80Mem($4400 + a) & 31
      For ly = 0 To 7
        base = (ty * 8 + ly) * #VID_W + tx * 8
        For lx = 0 To 7
          VidFrame(base + lx) = VidTileRgba(set, VidTile(code, ly * 8 + lx))
        Next
      Next
    Next
  Next
  For i = 7 To 0 Step -1
    attr = Z80Mem($4FF0 + i * 2)
    sx = 272 - MspSprPos(i * 2 + 1)
    sy = MspSprPos(i * 2) - 31
    If i <= 2 : sy + 1 : EndIf
    For copy = 0 To 1
      VidDrawSprite(attr >> 2, Z80Mem($4FF0 + i * 2 + 1) & 31, attr & 1, (attr >> 1) & 1, 208 - sy, sx - copy * 256)
    Next
  Next
EndProcedure
