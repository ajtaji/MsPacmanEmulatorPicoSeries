; A stand-in for the desktop Z80 core: the API of the Pico core (Z80EmulatorPicoSeries) and no
; CPU at all - Z80Run runs nothing. Used only while the desktop core does not exist, so the
; window, the screen, the sound path and the debug panes can be built and proved first. A build
; with it says so in its title bar and its log; it never plays the game.

EnableExplicit

#Z80_STANDIN = 1
Global Dim Z80Mem.a(65535)
Global Dim Z80PageRd.a(255)
Global Dim Z80PageWr.a(255)
Global Z80PC.i, Z80SP.i, Z80A.i, Z80F.i, Z80BC.i, Z80DE.i, Z80HL.i, Z80IX.i, Z80IY.i
Global Z80AF2.i, Z80BC2.i, Z80DE2.i, Z80HL2.i, Z80I.i, Z80IM.i, Z80IFF1.i, Z80IFF2.i
Global Z80Halted.i, Z80Stopped.i, Z80Error.i, Z80IntLine.i, Z80IntData.i

Procedure Z80Reset()
  Z80PC = 0 : Z80SP = $FFFF : Z80A = $FF : Z80F = $FF : Z80IM = 0 : Z80IFF1 = 0 : Z80IFF2 = 0
  Z80IntLine = 0 : Z80Halted = 0 : Z80Stopped = 0 : Z80Error = 0
EndProcedure
Procedure Z80IntRequest(d.i)
  Z80IntData = d & 255 : Z80IntLine = 1
EndProcedure
Procedure Z80IntClear()
  Z80IntLine = 0
EndProcedure
Procedure.i Z80GetR()
  ProcedureReturn 0
EndProcedure
Procedure.i Z80Run(n.i)
  ProcedureReturn n
EndProcedure
