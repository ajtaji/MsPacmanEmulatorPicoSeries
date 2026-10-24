; Ms. Pac-Man machine for the desktop (PureBasic): the same machine as rp2040/machine.pico, around
; a Z80 core with the Pico core's API (Z80Mem, Z80PageRd/Z80PageWr hooks calling Z80MemRead /
; Z80MemWrite, Z80PortIn / Z80PortOut, Z80IntRequest / Z80IntClear, Z80Run in T-states).
;
; MAME's mspacman_map (src/mame/pacman/pacman.cpp), with its mirrors:
;   $0000-$3FFF, $8000-$BFFF  ROM: the auxiliary board's decoded bank, or the Pac-Man ROMs
;   $4000-$43FF video RAM  $4400-$47FF colour RAM  $4800-$4BFF nothing (reads $BF)
;   $4C00-$4FEF RAM  $4FF0-$4FFF sprite codes/flips/colours
;   $5000-$5FFF I/O: writes $00-$3F latch (bit = address & 7), $40-$5F sound, $60-$6F sprite
;     positions, $C0-$FF watchdog; reads by address bits 6-7: IN0, IN1, DSW1, DSW2
;   $6000-$7FFF, $C000-$FFFF mirrors of $4000-$5FFF
;   I/O port 0 (write): the interrupt's data byte (IM 2 vector)
; The decode latch: an access to $0038-$003F, $03B0-$03B7, $1600-$1607, $2120-$2127,
; $3FF0-$3FF7, $8000-$8007 or $97F0-$97F7 puts the Pac-Man ROMs in; $3FF8-$3FFF the decoded bank.
; Timing: 3.072 MHz, 50,688 T-states a frame, 60.606 frames a second.

EnableExplicit

#MSP_FRAME_TSTATES = 50688
#MSP_FRAME_SAMPLES = 792              ; 48 kHz x 16.5 ms

; ---- the ROM set (MAME "mspacman"), found by CRC-32 ----
Enumeration
  #ROM_6E : #ROM_6F : #ROM_6H : #ROM_6J : #ROM_U5 : #ROM_U6 : #ROM_U7
  #ROM_5E : #ROM_5F : #ROM_7F : #ROM_4A : #ROM_1M : #ROM_COUNT
EndEnumeration
Global Dim RomName.s(#ROM_COUNT - 1)
Global Dim RomSize.i(#ROM_COUNT - 1)
Global Dim RomCrc.l(#ROM_COUNT - 1)
Global Dim *RomData(#ROM_COUNT - 1)
Global RomError.s, RomPlain.i         ; RomPlain: a plain Pac-Man hardware set (no auxiliary board)

Procedure RomTable()
  Protected i.i, n.s, sz.i, c.s
  Restore RomSetData
  For i = 0 To #ROM_COUNT - 1
    Read.s n : Read.i sz : Read.s c
    RomName(i) = n : RomSize(i) = sz : RomCrc(i) = Val("$" + c)
  Next
EndProcedure

Procedure.l Crc32Of(*mem, size.i)
  ProcedureReturn Val("$" + Fingerprint(*mem, size, #PB_Cipher_CRC32))
EndProcedure

; Every file of the set from a folder (by CRC-32, any names). 1 = all there; else RomError says.
; A folder without u5/u6/u7 that holds the nine plain Pac-Man hardware files BY NAME (a program
; built for the compiler's Pac-Man board, tools/pacman_assets.py) is taken as a plain set.
Procedure.i RomLoadFolder(folder.s)
  Protected dir.i, path.s, f.i, size.i, *buf, crc.l, i.i, missing.s
  RomTable()
  For i = 0 To #ROM_COUNT - 1
    If *RomData(i) : FreeMemory(*RomData(i)) : *RomData(i) = 0 : EndIf
  Next
  If Right(folder, 1) <> "\" And Right(folder, 1) <> "/" : folder + "\" : EndIf
  dir = ExamineDirectory(#PB_Any, folder, "*.*")
  If dir = 0
    RomError = "the ROM folder " + folder + " cannot be read"
    ProcedureReturn 0
  EndIf
  While NextDirectoryEntry(dir)
    If DirectoryEntryType(dir) = #PB_DirectoryEntry_File And DirectoryEntrySize(dir) <= 65536
      path = folder + DirectoryEntryName(dir)
      f = ReadFile(#PB_Any, path)
      If f
        size = Lof(f)
        If size > 0
          *buf = AllocateMemory(size)
          ReadData(f, *buf, size)
          crc = Crc32Of(*buf, size)
          For i = 0 To #ROM_COUNT - 1
            If *RomData(i) = 0 And size = RomSize(i) And crc = RomCrc(i)
              *RomData(i) = *buf : *buf = 0 : Break
            EndIf
          Next
          If *buf : FreeMemory(*buf) : EndIf
        EndIf
        CloseFile(f)
      EndIf
    EndIf
  Wend
  FinishDirectory(dir)
  RomPlain = 0
  If *RomData(#ROM_U5) = 0 And *RomData(#ROM_U6) = 0 And *RomData(#ROM_U7) = 0 And FileSize(folder + "pacman.6e") = $1000
    RomPlain = 1
    For i = 0 To #ROM_COUNT - 1
      If i = #ROM_U5 Or i = #ROM_U6 Or i = #ROM_U7 : Continue : EndIf
      If *RomData(i) : FreeMemory(*RomData(i)) : *RomData(i) = 0 : EndIf
      If FileSize(folder + RomName(i)) = RomSize(i)
        f = ReadFile(#PB_Any, folder + RomName(i))
        If f
          *RomData(i) = AllocateMemory(RomSize(i))
          ReadData(f, *RomData(i), RomSize(i))
          CloseFile(f)
        EndIf
      EndIf
    Next
  EndIf
  For i = 0 To #ROM_COUNT - 1
    If RomPlain And (i = #ROM_U5 Or i = #ROM_U6 Or i = #ROM_U7) : Continue : EndIf
    If *RomData(i) = 0 : missing + " " + RomName(i) : EndIf
  Next
  If missing <> ""
    RomError = "these files of the Ms. Pac-Man set are not in " + folder + " (or not whole):" + missing
    ProcedureReturn 0
  EndIf
  ProcedureReturn 1
EndProcedure

; MAME's bitswaps (init_mspacman).
Procedure.i RomDataSwap(b.i)            ; bitswap<8>(b, 0,4,5,7,6,3,2,1)
  ProcedureReturn ((b & 1) << 7) | (((b >> 4) & 1) << 6) | (((b >> 5) & 1) << 5) | (((b >> 7) & 1) << 4) | (((b >> 6) & 1) << 3) | (((b >> 3) & 1) << 2) | (((b >> 2) & 1) << 1) | ((b >> 1) & 1)
EndProcedure
Procedure.i RomSwap12(i.i)              ; bitswap<12>(i, 11,3,7,9,10,8,6,5,4,2,1,0)
  ProcedureReturn (i & $800) | (((i >> 3) & 1) << 10) | (((i >> 7) & 1) << 9) | (((i >> 9) & 1) << 8) | (((i >> 10) & 1) << 7) | (((i >> 8) & 1) << 6) | (((i >> 6) & 1) << 5) | (((i >> 5) & 1) << 4) | (((i >> 4) & 1) << 3) | (i & 7)
EndProcedure
Procedure.i RomSwapU5(i.i)              ; bitswap<11>(i, 8,7,5,9,10,6,3,4,2,1,0)
  ProcedureReturn (((i >> 8) & 1) << 10) | (((i >> 7) & 1) << 9) | (((i >> 5) & 1) << 8) | (((i >> 9) & 1) << 7) | (((i >> 10) & 1) << 6) | (((i >> 6) & 1) << 5) | (((i >> 3) & 1) << 4) | (((i >> 4) & 1) << 3) | (i & 7)
EndProcedure
Procedure.i RomSwapU6(i.i)              ; bitswap<11>(i, 3,7,9,10,8,6,5,4,2,1,0)
  ProcedureReturn (((i >> 3) & 1) << 10) | (((i >> 7) & 1) << 9) | (((i >> 9) & 1) << 8) | (((i >> 10) & 1) << 7) | (((i >> 8) & 1) << 6) | (((i >> 6) & 1) << 5) | (((i >> 5) & 1) << 4) | (((i >> 4) & 1) << 3) | (i & 7)
EndProcedure

; The two ROM halves of the address space, built once: 0 = Pac-Man ROMs, 1 = decoded bank.
Global Dim BankRom.a(1, 32767)          ; [bank][addr & $3FFF | (addr >= $8000) << 14]

Procedure.i RomByte(role.i, i.i)
  ProcedureReturn PeekA(*RomData(role) + i)
EndProcedure

Procedure RomBuildBanks()
  Protected i.i, p.i, dst.i, src.i
  Dim d.a($FFFF)
  If RomPlain
    ; plain Pac-Man hardware: the four ROMs at $0000-$3FFF and again at $8000 (A15 not decoded),
    ; the same in both "banks" - there is no auxiliary board to switch
    For i = 0 To $FFF
      BankRom(0, i) = RomByte(#ROM_6E, i) : BankRom(0, $1000 + i) = RomByte(#ROM_6F, i)
      BankRom(0, $2000 + i) = RomByte(#ROM_6H, i) : BankRom(0, $3000 + i) = RomByte(#ROM_6J, i)
    Next
    For i = 0 To $3FFF : BankRom(0, $4000 + i) = BankRom(0, i) : Next
    For i = 0 To $7FFF : BankRom(1, i) = BankRom(0, i) : Next
    ProcedureReturn
  EndIf
  For i = 0 To $FFF
    d(i) = RomByte(#ROM_6E, i) : d($1000 + i) = RomByte(#ROM_6F, i) : d($2000 + i) = RomByte(#ROM_6H, i)
    d($3000 + i) = RomDataSwap(RomByte(#ROM_U7, RomSwap12(i)))
  Next
  For i = 0 To $7FF
    d($8000 + i) = RomDataSwap(RomByte(#ROM_U5, RomSwapU5(i)))
    d($8800 + i) = RomDataSwap(RomByte(#ROM_U6, $800 + RomSwapU6(i)))
    d($9000 + i) = RomDataSwap(RomByte(#ROM_U6, RomSwapU6(i)))
    d($9800 + i) = RomByte(#ROM_6F, $800 + i)
  Next
  For i = 0 To $FFF
    d($A000 + i) = RomByte(#ROM_6H, i) : d($B000 + i) = RomByte(#ROM_6J, i)
  Next
  Restore RomPatchData
  For p = 0 To 39
    Read.i dst : Read.i src
    For i = 0 To 7 : d(dst + i) = d(src + i) : Next
  Next
  For i = 0 To $3FFF
    BankRom(1, i) = d(i) : BankRom(1, $4000 + i) = d($8000 + i)
  Next
  For i = 0 To $FFF
    BankRom(0, i) = RomByte(#ROM_6E, i) : BankRom(0, $1000 + i) = RomByte(#ROM_6F, i)
    BankRom(0, $2000 + i) = RomByte(#ROM_6H, i) : BankRom(0, $3000 + i) = RomByte(#ROM_6J, i)
  Next
  For i = 0 To $3FFF : BankRom(0, $4000 + i) = BankRom(0, i) : Next
EndProcedure

; ---- machine state ----
Global MspLatch.i, MspIntVector.i, MspDsw1.i = $C9, MspDsw2.i = 0
Global MspIn0.i = $FF, MspIn1.i = $FF
Global MspWatchdog.i, MspWatchdogResets.i, MspRomWrites.i, MspInterrupts.i
Global MspDecoded.i = -1, MspBankSwitches.i, MspFrames.i
Global Dim MspSprPos.a(15)
Global Dim WsgRegs.a(31)

Procedure MachineSetBank(decoded.i)
  Protected i.i
  If decoded = MspDecoded : ProcedureReturn : EndIf
  MspDecoded = decoded : MspBankSwitches + 1
  CopyMemory(@BankRom(decoded, 0), @Z80Mem(0), $4000)
  CopyMemory(@BankRom(decoded, $4000), @Z80Mem($8000), $4000)
EndProcedure

Procedure.i MachineTrap(addr.i)
  If RomPlain : ProcedureReturn -1 : EndIf
  If addr >= $3FF8 And addr <= $3FFF : ProcedureReturn 1 : EndIf
  If (addr >= $0038 And addr <= $003F) Or (addr >= $03B0 And addr <= $03B7) Or (addr >= $1600 And addr <= $1607) Or
     (addr >= $2120 And addr <= $2127) Or (addr >= $3FF0 And addr <= $3FF7) Or (addr >= $8000 And addr <= $8007) Or (addr >= $97F0 And addr <= $97F7)
    ProcedureReturn 0
  EndIf
  ProcedureReturn -1
EndProcedure

Procedure MachineMapPages()
  Protected p.i
  For p = 0 To 255
    Z80PageRd(p) = 0 : Z80PageWr(p) = 0
    If p < $40 Or (p >= $80 And p < $C0) : Z80PageWr(p) = 1 : EndIf
    If RomPlain = 0 And (p = $00 Or p = $03 Or p = $16 Or p = $21 Or p = $3F Or p = $80 Or p = $97) : Z80PageRd(p) = 1 : EndIf
    If p >= $48 And p < $4C : Z80PageRd(p) = 1 : Z80PageWr(p) = 1 : EndIf
    If (p >= $50 And p < $80) Or p >= $C0 : Z80PageRd(p) = 1 : Z80PageWr(p) = 1 : EndIf
  Next
EndProcedure

Procedure MachineLatch(bit.i, value.i)
  If value : MspLatch | (1 << bit) : Else : MspLatch & ~(1 << bit) : EndIf
  If bit = 0 And value = 0 : Z80IntClear() : EndIf
EndProcedure

Procedure.i Z80MemRead(addr.i)
  Protected c.i, sel.i, t.i
  If addr < $4000 Or (addr >= $8000 And addr < $C000)
    t = MachineTrap(addr)
    If t >= 0 : MachineSetBank(t) : EndIf
    ProcedureReturn Z80Mem(addr)
  EndIf
  c = addr & $5FFF
  If c < $5000
    If c >= $4800 And c < $4C00 : ProcedureReturn $BF : EndIf
    ProcedureReturn Z80Mem(c)
  EndIf
  sel = (c >> 6) & 3
  Select sel
    Case 0 : ProcedureReturn MspIn0
    Case 1 : ProcedureReturn MspIn1
    Case 2 : ProcedureReturn MspDsw1
  EndSelect
  ProcedureReturn MspDsw2
EndProcedure

Procedure Z80MemWrite(addr.i, value.i)
  Protected c.i, o.i, t.i
  If addr < $4000 Or (addr >= $8000 And addr < $C000)
    t = MachineTrap(addr)
    If t >= 0 : MachineSetBank(t) : EndIf
    MspRomWrites + 1 : ProcedureReturn
  EndIf
  c = addr & $5FFF
  If c < $5000
    If c < $4800 Or c >= $4C00 : Z80Mem(c) = value : EndIf
    ProcedureReturn
  EndIf
  o = c & 255
  If o < $40
    MachineLatch(o & 7, value & 1)
  ElseIf o < $60
    WsgRegs(o - $40) = value & 15
  ElseIf o < $70
    MspSprPos(o - $60) = value
  ElseIf o >= $C0
    MspWatchdog = 0
  EndIf
EndProcedure

Procedure.i Z80PortIn(port.i)
  ProcedureReturn $FF
EndProcedure

Procedure Z80PortOut(port.i, value.i)
  If (port & 255) = 0 : MspIntVector = value & 255 : EndIf
EndProcedure

Procedure MachineReset()
  Protected i.i
  For i = $4000 To $4FFF : Z80Mem(i) = 0 : Next
  For i = 0 To 15 : MspSprPos(i) = 0 : Next
  For i = 0 To 7 : MachineLatch(i, 0) : Next
  For i = 0 To 31 : WsgRegs(i) = 0 : Next
  MspIntVector = 0 : MspWatchdog = 0
  Z80Reset()
EndProcedure

; Power-on: the ROM banks into place (decoded first, as MAME's init leaves it), then reset.
Procedure MachinePowerOn()
  MspDecoded = -1
  MachineSetBank(1)
  MspBankSwitches = 0
  MachineMapPages()
  MachineReset()
EndProcedure

DataSection
  RomSetData:
  Data.s "pacman.6e" : Data.i $1000 : Data.s "C1E6AB10"
  Data.s "pacman.6f" : Data.i $1000 : Data.s "1A6FB2D4"
  Data.s "pacman.6h" : Data.i $1000 : Data.s "BCDD1BEB"
  Data.s "pacman.6j" : Data.i $1000 : Data.s "817D94E3"
  Data.s "u5" : Data.i $0800 : Data.s "F45FBBCD"
  Data.s "u6" : Data.i $1000 : Data.s "A90E7000"
  Data.s "u7" : Data.i $1000 : Data.s "C82CD714"
  Data.s "5e" : Data.i $1000 : Data.s "5C281D01"
  Data.s "5f" : Data.i $1000 : Data.s "615AF909"
  Data.s "82s123.7f" : Data.i $0020 : Data.s "2FC650BD"
  Data.s "82s126.4a" : Data.i $0100 : Data.s "3EB3A8E4"
  Data.s "82s126.1m" : Data.i $0100 : Data.s "A9CC86BF"
  RomPatchData:
  Data.i $0410,$8008, $08E0,$81D8, $0A30,$8118, $0BD0,$80D8, $0C20,$8120, $0E58,$8168, $0EA8,$8198
  Data.i $1000,$8020, $1008,$8010, $1288,$8098, $1348,$8048, $1688,$8088, $16B0,$8188, $16D8,$80C8
  Data.i $16F8,$81C8, $19A8,$80A8, $19B8,$81A8
  Data.i $2060,$8148, $2108,$8018, $21A0,$81A0, $2298,$80A0, $23E0,$80E8, $2418,$8000, $2448,$8058
  Data.i $2470,$8140, $2488,$8080, $24B0,$8180, $24D8,$80C0, $24F8,$81C0, $2748,$8050, $2780,$8090
  Data.i $27B8,$8190, $2800,$8028, $2B20,$8100, $2B30,$8110, $2BF0,$81D0, $2CC0,$80D0, $2CD8,$80E0
  Data.i $2CF0,$81E0, $2D60,$8160
EndDataSection
