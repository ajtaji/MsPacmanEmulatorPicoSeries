; Ms. Pac-Man for the desktop - PureBasic, drawn with the Neon Arcade Display Engine.
; The same machine as the Pico version (rp2040/), on the Z80 core with the Pico core's API.
;
; BUILD (x64, from PowerShell, C back end):
;   & "C:\Program Files\PureBasic\Compilers\pbcompilerc.exe" desktop\MsPacman.pb /EXE build\MsPacman.exe /THREAD /DPIAWARE
;       [/CONSTANT GL_ENGINE_DIR$=C:/path/to/engine/]   (default: the shared engine path below)
;       [/CONSTANT MSP_Z80_DIR$=C:/path/to/Z80EmulatorPicoSeries/desktop/]   (default: beside this repo)
; RUN:
;   MsPacman.exe [ROM folder]               the window (asks for the folder when none is given)
;   MsPacman.exe <ROM folder> --log N       no window: N frames, a log line per second, then exit
;                                           (--log-every F: a line every F frames)
;   MsPacman.exe <ROM folder> --test-picture --dump <file> [--log N]
;   MsPacman.exe <ROM folder> --press 600:coin,660:start,900:left ...   inputs held for 6 frames
;                                           at those frames (coin start start2 up down left right)
;   MsPacman.exe <ROM folder> --mute ...    starts with the sound muted (M toggles it)
;   MsPacman.exe <ROM folder> --shot <png> <frames>
;                                           the window for that many frames, then its picture
;                                           saved and the program closes by itself
;                                           the fixed test picture (as Diagnostics/video_check)
;
; KEYS: arrows = joystick, 5 or C = coin, 1 = 1P start, 2 = 2P start, F5 run/pause,
;       F10 step one instruction, F11 one frame, F3 reset, M mute.
; The ROMs are commercial: none are in the repository; the folder is the user's.

EnableExplicit

CompilerIf Not Defined(GL_ENGINE_DIR$, #PB_Constant)
  #GL_ENGINE_DIR$ = "C:/Embedded Compiler/Neon-Arcade-Dispay-Engine/"
CompilerEndIf
XIncludeFile #GL_ENGINE_DIR$ + "GlTypes.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlUtilities.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlMath.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlSpriteFunctions.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlUI.pbi"
XIncludeFile #GL_ENGINE_DIR$ + "GlUIChrome.pbi"

UseCRC32Fingerprint()
UsePNGImageEncoder()

; The Z80 core and its disassembler: Z80EmulatorPicoSeries/desktop (the Pico core's handlers,
; generated for PureBasic), found beside this repository unless MSP_Z80_DIR$ says where.
CompilerIf Not Defined(MSP_Z80_DIR$, #PB_Constant)
  #MSP_Z80_DIR$ = #PB_Compiler_FilePath + "../../Z80EmulatorPicoSeries/desktop/"
CompilerEndIf
#Z80_TIMED = 1
#Z80_SHARED_TAIL = 0
#Z80_MEM_HOOKS = 1
#Z80_Q = 1
#Z80_TRACK_R = 1
XIncludeFile #MSP_Z80_DIR$ + "z80core.pbi"
XIncludeFile #MSP_Z80_DIR$ + "z80disasm.pbi"
XIncludeFile "msp_machine.pbi"
XIncludeFile "msp_video.pbi"
XIncludeFile "msp_sound.pbi"

; ---------------------------------------------------------------------------
; The machine's frame
; ---------------------------------------------------------------------------
Global EmuRunning.i = 1, EmuBreakOn.i, EmuBreakPC.i, EmuStopReason.s, EmuTDebt.i
Global EmuTStates.q, EmuInstr.q, EmuFrameCount.q, EmuTestPicture.i
Global EmuHeldKeys.i, EmuHostHeld.i, EmuPress.s, EmuPressBits.i, EmuPressUntil.q

; --press: "frame:what" items; what = coin start start2 up down left right.
Procedure EmuScriptInputs()
  Protected n.i, i.i, item.s, at.q, what.s, bits.i
  If EmuPress = "" : ProcedureReturn : EndIf
  n = CountString(EmuPress, ",") + 1
  For i = 1 To n
    item = Trim(StringField(EmuPress, i, ","))
    at = Val(StringField(item, 1, ":")) : what = LCase(StringField(item, 2, ":"))
    If at = EmuFrameCount
      Select what
        Case "coin" : bits = $20
        Case "start" : bits = $100
        Case "start2" : bits = $200
        Case "up" : bits = 1
        Case "left" : bits = 2
        Case "right" : bits = 4
        Case "down" : bits = 8
        Default : bits = 0
      EndSelect
      EmuPressBits = bits : EmuPressUntil = at + 6
    EndIf
  Next
  If EmuFrameCount >= EmuPressUntil : EmuPressBits = 0 : EndIf
EndProcedure

; IN0 / IN1 from the keys held (active low; see rp2040/input.pico for the bits).
Procedure EmuInputs()
  Protected in0.i = $FF, in1.i = $FF, k.i
  EmuScriptInputs()
  k = EmuHostHeld | EmuPressBits
  If k & 1 : in0 & ~1 : EndIf          ; up
  If k & 2 : in0 & ~2 : EndIf          ; left
  If k & 4 : in0 & ~4 : EndIf          ; right
  If k & 8 : in0 & ~8 : EndIf          ; down
  If k & $20 : in0 & ~$20 : EndIf      ; coin 1
  If k & $100 : in1 & ~$20 : EndIf     ; 1 player start
  If k & $200 : in1 & ~$40 : EndIf     ; 2 player start
  MspIn0 = in0 : MspIn1 = in1
EndProcedure

Procedure EmuTestPictureFill()
  Protected i.i
  For i = 0 To 1023
    Z80Mem($4000 + i) = i & 255
    Z80Mem($4400 + i) = (i >> 5) & 31
  Next
  For i = 0 To 7
    Z80Mem($4FF0 + i * 2) = (((i * 9) & 63) << 2) | (i & 3)
    Z80Mem($4FF0 + i * 2 + 1) = (i * 5 + 1) & 31
    MspSprPos(i * 2) = 40 + i * 24
    MspSprPos(i * 2 + 1) = 40 + i * 28
  Next
  MspSprPos(14) = 250 : MspSprPos(15) = 8
  MspSprPos(12) = 20 : MspSprPos(13) = 250
EndProcedure

; Vertical blank: the picture, the frame's sound, the controls, the watchdog, the interrupt.
Procedure EmuVblank()
  If EmuTestPicture : EmuTestPictureFill() : EndIf
  VideoRender()
  WsgRender()
  SoundQueue()
  EmuInputs()
  MspWatchdog + 1
  If EmuTestPicture : MspWatchdog = 0 : EndIf
  If MspWatchdog >= 16
    MspWatchdogResets + 1
    MachineReset()
  ElseIf MspLatch & 1
    Z80IntRequest(MspIntVector) : MspInterrupts + 1
  EndIf
  MspFrames + 1 : EmuFrameCount + 1
EndProcedure

; One instruction (the debugger's step). Returns T-states used.
Procedure.i EmuStep()
  Protected used.i = Z80Run(1)
  EmuTStates + used : EmuTDebt + used : EmuInstr + 1
  If EmuTDebt >= #MSP_FRAME_TSTATES
    EmuTDebt - #MSP_FRAME_TSTATES
    EmuVblank()
  EndIf
  ProcedureReturn used
EndProcedure

; One frame of T-states. With a breakpoint set it runs an instruction at a time and stops on it.
Procedure EmuFrame()
  Protected used.i
  If Z80Stopped
    EmuRunning = 0 : EmuStopReason = "the Z80 stopped (error " + Str(Z80Error) + ")"
    ProcedureReturn
  EndIf
  If EmuBreakOn
    While EmuRunning
      EmuStep()
      If Z80PC = EmuBreakPC
        EmuRunning = 0 : EmuStopReason = "breakpoint at " + "$" + Z80DisH4(EmuBreakPC)
      EndIf
      If EmuTDebt < 30 : Break : EndIf       ; a frame boundary has just passed
      If Z80Stopped : Break : EndIf
    Wend
    ProcedureReturn
  EndIf
  used = Z80Run(#MSP_FRAME_TSTATES - EmuTDebt)
  EmuTStates + used
  EmuTDebt = EmuTDebt + used - #MSP_FRAME_TSTATES
  If EmuTDebt < 0 : EmuTDebt = 0 : EndIf
  EmuVblank()
EndProcedure

; The frame as the Pico dumps it: the SNAP line (tools/grab.py's format), then 224 x 288 RGB565.
Procedure.i EmuDumpFrame(path.s)
  Protected f.i, i.i, line.s, *px
  f = CreateFile(#PB_Any, path)
  If f = 0 : ProcedureReturn 0 : EndIf
  line = "SNAP "
  For i = 0 To 2047 : line + RSet(Hex(Z80Mem($4000 + i)), 2, "0") : Next
  For i = 0 To 15 : line + RSet(Hex(Z80Mem($4FF0 + i)), 2, "0") : Next
  For i = 0 To 15 : line + RSet(Hex(MspSprPos(i)), 2, "0") : Next
  line + RSet(Hex((MspLatch >> 3) & 1), 2, "0") + "000000"
  WriteStringN(f, line, #PB_Ascii)
  WriteStringN(f, "FRAME_BEGIN 224 288", #PB_Ascii)
  *px = AllocateMemory(#VID_W * #VID_H * 2)
  For i = 0 To #VID_W * #VID_H - 1 : PokeU(*px + i * 2, VidRgb565(VidFrame(i))) : Next
  WriteData(f, *px, #VID_W * #VID_H * 2)
  FreeMemory(*px)
  WriteStringN(f, "", #PB_Ascii) : WriteStringN(f, "FRAME_END", #PB_Ascii)
  CloseFile(f)
  ProcedureReturn 1
EndProcedure

Procedure.s EmuCoreName()
  ProcedureReturn "Z80 core"
EndProcedure

Procedure.i EmuStart(folder.s)
  If RomLoadFolder(folder) = 0 : ProcedureReturn 0 : EndIf
  RomBuildBanks()
  VideoDecode(*RomData(#ROM_5E), *RomData(#ROM_5F), *RomData(#ROM_7F), *RomData(#ROM_4A))
  WsgBegin(*RomData(#ROM_1M))
  MachinePowerOn()
  EmuTDebt = 0
  ProcedureReturn 1
EndProcedure

; ---------------------------------------------------------------------------
; --log: no window
; ---------------------------------------------------------------------------
Global LogEvery.i = 61
Procedure LogRun(frames.i, dump.s)
  Protected n.i, t0.q, t1.q, lastT.q, lastI.q, lastF.q, now.q, sec.i
  OpenConsole()
  PrintN("Ms. Pac-Man desktop - " + EmuCoreName() + " - log run of " + Str(frames) + " frames")
  PrintN("ROMS: decoded 0000-3FFF CRC-32 " + Fingerprint(@BankRom(1, 0), $4000, #PB_Cipher_CRC32) +
         "  8000-BFFF CRC-32 " + Fingerprint(@BankRom(1, $4000), $4000, #PB_Cipher_CRC32))
  t0 = ElapsedMilliseconds() : t1 = t0
  For n = 1 To frames
    EmuFrame()
    If n % LogEvery = 0
      now = ElapsedMilliseconds()
      sec + 1
      PrintN("t=" + Str(sec) + " frames=" + Str(EmuFrameCount - lastF) + " tstates=" + Str(EmuTStates - lastT) +
             " ints=" + Str(MspInterrupts) + " pc=" + "$" + Z80DisH4(Z80PC) + " banks=" + Str(MspBankSwitches) +
             " decoded=" + Str(MspDecoded) + " watchdog=" + Str(MspWatchdogResets) + " host_ms=" + Str(now - t1))
      lastF = EmuFrameCount : lastT = EmuTStates : t1 = now
    EndIf
  Next
  now = ElapsedMilliseconds()
  PrintN("done: " + Str(frames) + " frames in " + Str(now - t0) + " ms (" + StrF(frames * 1000.0 / ((now - t0) + 1), 1) + " frames/s unpaced)")
  If dump <> ""
    If EmuDumpFrame(dump) : PrintN("frame written: " + dump) : Else : PrintN("could not write " + dump) : EndIf
  EndIf
EndProcedure

; ---------------------------------------------------------------------------
; The window
; ---------------------------------------------------------------------------
Global Win.i, Gl.i, UiScale.f, FontScale.f, ScreenTex.l, ScreenSprite.GLSprite
Global Dim TexRows.l(#VID_W * #VID_H - 1)
Global MouseDown.b, Wheel.i, KeyCode.i, KeyChar.i
Global PhysW.i, PhysH.i, MemTab.i, MemTop.i, BreakText.String, BreakCaret.i
Global FpsShown.f, FpsCount.i, FpsMark.q, SpeedTStates.q, SpeedMark.q, SpeedMHz.f
Global GetDpiForWindow_.i, ShotPath.s, ShotFrames.i
Global EmuWasPaused.i, PaceResyncs.i
Global Dim PaneUs.q(7), Dim PaneShown.f(7)
Global DrawUs.q, EmuUs.q, LoopCount.q, DrawUsShown.f, EmuUsShown.f, LoopsShown.f, QpcFreq.q
Declare SaveWindowShot(path.s)
Declare.q MicroNow()

Procedure.f WindowScale(w.i)
  Protected dpi.i, lib.i
  If GetDpiForWindow_ = 0
    lib = OpenLibrary(#PB_Any, "user32.dll")
    If lib : GetDpiForWindow_ = GetFunction(lib, "GetDpiForWindow") : EndIf
  EndIf
  If GetDpiForWindow_ : dpi = CallFunctionFast(GetDpiForWindow_, WindowID(w)) : EndIf
  If dpi <= 0 : ProcedureReturn 1.0 : EndIf
  ProcedureReturn dpi / 96.0
EndProcedure

Procedure BuildFonts()
  Protected s.f = UiScale
  *Neon_FontUI = Neon_CreateFontPx("Segoe UI", Round(14 * s, #PB_Round_Nearest))
  *Neon_FontSmall = Neon_CreateFontPx("Segoe UI", Round(12 * s, #PB_Round_Nearest))
  *Neon_FontBold = Neon_CreateFontPx("Segoe UI", Round(15 * s, #PB_Round_Nearest), #PB_Font_Bold)
  *Neon_FontMono = Neon_CreateFontPx("Consolas", Round(13 * s, #PB_Round_Nearest))
  GLFontSetSnapToPixel(*Neon_FontUI, #True) : GLFontSetSnapToPixel(*Neon_FontSmall, #True)
  GLFontSetSnapToPixel(*Neon_FontBold, #True) : GLFontSetSnapToPixel(*Neon_FontMono, #True)
  Neon_UIScale = s : FontScale = s
EndProcedure

Procedure ScreenTextureInit()
  glGenTextures_(1, @ScreenTex)
  glBindTexture_(#GL_TEXTURE_2D, ScreenTex)
  glTexParameteri_(#GL_TEXTURE_2D, #GL_TEXTURE_MIN_FILTER, #GL_NEAREST)
  glTexParameteri_(#GL_TEXTURE_2D, #GL_TEXTURE_MAG_FILTER, #GL_NEAREST)
  glTexParameteri_(#GL_TEXTURE_2D, #GL_TEXTURE_WRAP_S, #GL_CLAMP_TO_EDGE)
  glTexParameteri_(#GL_TEXTURE_2D, #GL_TEXTURE_WRAP_T, #GL_CLAMP_TO_EDGE)
  glTexImage2D_(#GL_TEXTURE_2D, 0, #GL_RGBA, #VID_W, #VID_H, 0, #GL_RGBA, #GL_UNSIGNED_BYTE, @VidFrame(0))
  ScreenSprite\TextureID = ScreenTex : ScreenSprite\Width = #VID_W : ScreenSprite\Height = #VID_H
EndProcedure

; The engine samples a sprite's top edge at v = 1 (Windows): the texture is sent bottom row first.
Procedure ScreenTextureUpload()
  Protected y.i
  For y = 0 To #VID_H - 1
    CopyMemory(@VidFrame(y * #VID_W), @TexRows((#VID_H - 1 - y) * #VID_W), #VID_W * 4)
  Next
  glBindTexture_(#GL_TEXTURE_2D, ScreenTex)
  glTexSubImage2D_(#GL_TEXTURE_2D, 0, 0, 0, #VID_W, #VID_H, #GL_RGBA, #GL_UNSIGNED_BYTE, @TexRows(0))
EndProcedure

Procedure.s Flags(f.i)
  Protected s.s, i.i, names.s = "SZYHXPNC"
  For i = 0 To 7
    If f & (128 >> i) : s + Mid(names, i + 1, 1) : Else : s + "." : EndIf
  Next
  ProcedureReturn s
EndProcedure

Procedure DrawRegisters(x.f, y.f, w.f, h.f)
  Protected lh.f = *Neon_FontMono\LineHeight, cx.f = x + Neon_S(12), cy.f = y + Neon_S(34)
  Protected tr.f = 0.85, tg.f = 0.9, tb.f = 0.95
  Neon_Panel(x, y, w, h, "Z80 - " + EmuCoreName(), 0.30, 0.85, 1.0, Neon_S(26))
  Neon_Text(*Neon_FontMono, cx, cy, "PC " + "$" + Z80DisH4(Z80PC) + "  SP " + "$" + Z80DisH4(Z80SP) + "  AF " + "$" + Z80DisH4((Z80A << 8) | Z80F), tr, tg, tb) : cy + lh
  Neon_Text(*Neon_FontMono, cx, cy, "BC " + "$" + Z80DisH4(Z80BC) + "  DE " + "$" + Z80DisH4(Z80DE) + "  HL " + "$" + Z80DisH4(Z80HL), tr, tg, tb) : cy + lh
  Neon_Text(*Neon_FontMono, cx, cy, "IX " + "$" + Z80DisH4(Z80IX) + "  IY " + "$" + Z80DisH4(Z80IY) + "  I  " + "$" + Z80DisH2(Z80I), tr, tg, tb) : cy + lh
  Neon_Text(*Neon_FontMono, cx, cy, "IM " + Str(Z80IM) + "  IFF1 " + Str(Z80IFF1) + "  HALT " + Str(Z80Halted) + "  flags " + Flags(Z80F), tr, tg, tb) : cy + lh
  Neon_Text(*Neon_FontMono, cx, cy, "latch " + "$" + Z80DisH2(MspLatch) + "  vector " + "$" + Z80DisH2(MspIntVector) + "  bank " + StringField("pac-man,decoded", MspDecoded + 1, ","), tr, tg, tb) : cy + lh
  Neon_Text(*Neon_FontMono, cx, cy, "IN0 " + "$" + Z80DisH2(MspIn0) + "  IN1 " + "$" + Z80DisH2(MspIn1) + "  DSW1 " + "$" + Z80DisH2(MspDsw1) + "  watchdog " + Str(MspWatchdogResets), tr, tg, tb)
EndProcedure

Procedure DrawDisassembly(x.f, y.f, w.f, h.f)
  Protected lh.f = *Neon_FontMono\LineHeight, cy.f = y + Neon_S(34), a.i = Z80PC, n.i, len.i, t.s, bytes.s, i.i
  Neon_Panel(x, y, w, h, "Disassembly at PC", 0.30, 0.85, 1.0, Neon_S(26))
  While cy + lh < y + h - Neon_S(6)
    t = Z80Disasm(a, @len)
    bytes = ""
    For i = 0 To len - 1 : bytes + RSet(Hex(Z80Mem((a + i) & $FFFF)), 2, "0") + " " : Next
    If n = 0
      Neon_Box(x + Neon_S(4), cy, w - Neon_S(8), lh, 0.10, 0.25, 0.30)
    EndIf
    Neon_Text(*Neon_FontMono, x + Neon_S(12), cy, RSet(Hex(a & $FFFF), 4, "0") + "  " + LSet(bytes, 12) + t, 0.85, 0.9, 0.95)
    a = (a + len) & $FFFF : cy + lh : n + 1
  Wend
EndProcedure

Procedure DrawMemory(x.f, y.f, w.f, h.f)
  Protected lh.f = *Neon_FontMono\LineHeight, cy.f, base.i, row.i, i.i, t.s, rows.i
  Neon_Panel(x, y, w, h, "Memory", 0.30, 0.85, 1.0, Neon_S(26))
  MemTab = Neon_TabStrip(301, x + Neon_S(4), y + Neon_S(30), w - Neon_S(8), Neon_S(26), "Video RAM|Colour RAM|RAM|Sprites|ROM", MemTab)
  Select MemTab
    Case 0 : base = $4000
    Case 1 : base = $4400
    Case 2 : base = $4C00
    Case 3 : base = $4FF0
    Default : base = $0000
  EndSelect
  rows = (h - Neon_S(66)) / lh
  If Neon_Hit(x, y, w, h) And Wheel : MemTop - Wheel * 2 : EndIf
  If MemTop < 0 : MemTop = 0 : EndIf
  cy = y + Neon_S(62)
  For row = 0 To rows - 1
    t = RSet(Hex((base + (MemTop + row) * 16) & $FFFF), 4, "0") + "  "
    For i = 0 To 15 : t + RSet(Hex(Z80Mem((base + (MemTop + row) * 16 + i) & $FFFF)), 2, "0") + " " : Next
    Neon_Text(*Neon_FontMono, x + Neon_S(12), cy, t, 0.80, 0.86, 0.92)
    cy + lh
  Next
EndProcedure

Procedure DrawControls(x.f, y.f, w.f, h.f)
  Protected bw.f = Neon_S(92), bh.f = Neon_S(28), gx.f = x + Neon_S(10), gy.f = y + Neon_S(34), lab.s
  Neon_Panel(x, y, w, h, "Run", 1.0, 0.85, 0.30, Neon_S(26))
  If EmuRunning : lab = "Pause  F5" : Else : lab = "Run  F5" : EndIf
  If Neon_Button(gx, gy, bw, bh, lab, EmuRunning) : EmuRunning ! 1 : EmuStopReason = "" : EndIf
  If Neon_Button(gx + bw + Neon_S(6), gy, bw, bh, "Step  F10", #False, Bool(EmuRunning = 0)) : EmuStep() : VideoRender() : EndIf
  If Neon_Button(gx + 2 * (bw + Neon_S(6)), gy, bw, bh, "Frame  F11", #False, Bool(EmuRunning = 0)) : EmuFrame() : EndIf
  If Neon_Button(gx + 3 * (bw + Neon_S(6)), gy, bw, bh, "Reset  F3") : MachineReset() : EmuTDebt = 0 : EndIf
  gy + bh + Neon_S(8)
  Neon_Text(*Neon_FontUI, gx, gy + Neon_S(4), "Break at", 0.8, 0.85, 0.9)
  If Neon_TextInput(302, gx + Neon_S(70), gy, Neon_S(80), bh, @BreakText, "hex", @BreakCaret) Or #True
    If BreakText\s <> ""
      EmuBreakPC = Val("$" + BreakText\s) & $FFFF : EmuBreakOn = 1
    Else
      EmuBreakOn = 0
    EndIf
  EndIf
  If Neon_Button(gx + Neon_S(160), gy, Neon_S(70), bh, "Clear") : BreakText\s = "" : EmuBreakOn = 0 : EndIf
  If Neon_Button(gx + Neon_S(240), gy, Neon_S(80), bh, "Coin  5") : EmuHeldKeys | $20 : EndIf
  If Neon_Button(gx + Neon_S(326), gy, Neon_S(80), bh, "1P  1") : EmuHeldKeys | $100 : EndIf
  gy + bh + Neon_S(10)
  Neon_Text(*Neon_FontUI, gx, gy, StrF(FpsShown, 2) + " frames/s   Z80 " + StrF(SpeedMHz, 3) + " MHz   sound: " +
            StringField("none,playing,muted", 1 + SndOpen + Bool(SndOpen And SndMuted), ",") +
            "   underruns " + Str(SndUnderruns) + "   bank switches " + Str(MspBankSwitches), 0.7, 0.9, 0.7)
  Neon_Text(*Neon_FontSmall, gx, gy + *Neon_FontUI\LineHeight, "window: " + StrF(LoopsShown, 0) + " passes/s, drawing " + StrF(DrawUsShown / 1000.0, 2) + " ms a pass, emulating " + StrF(EmuUsShown / 1000.0, 1) + " ms/s, resyncs " + Str(PaceResyncs) + "   ms: begin " + StrF(PaneShown(6), 2) + " screen " + StrF(PaneShown(0), 2) + " run " + StrF(PaneShown(1), 2) + " regs " + StrF(PaneShown(2), 2) + " dis " + StrF(PaneShown(3), 2) + " mem " + StrF(PaneShown(4), 2) + " flip " + StrF(PaneShown(5), 2), 0.55, 0.65, 0.75)
  If EmuStopReason <> "" : Neon_Text(*Neon_FontUI, gx, gy + 2 * *Neon_FontUI\LineHeight, "Stopped: " + EmuStopReason, 1.0, 0.6, 0.4) : EndIf
EndProcedure

Global SizedW.i = -1, SizedH.i = -1

; The size globals - only when the window's size changed (resizing the gadget every pass costs
; a relayout each time).
Procedure SizeGlobals()
  Protected client.RECT, cw.i = WindowWidth(Win), ch.i = WindowHeight(Win)
  If cw = SizedW And ch = SizedH : ProcedureReturn : EndIf
  SizedW = cw : SizedH = ch
  ResizeGadget(Gl, 0, 0, cw, ch)
  GetClientRect_(WindowID(Win), @client)
  PhysW = client\right - client\left : PhysH = client\bottom - client\top
  If PhysW < 1 : PhysW = 1 : EndIf
  If PhysH < 1 : PhysH = 1 : EndIf
  Util_BaseWidth = PhysW : Util_BaseHeight = PhysH
  Util_WinWidth = cw : Util_WinHeight = ch
  GL_ViewportX = 0 : GL_ViewportY = 0 : GL_ViewportW = PhysW : GL_ViewportH = PhysH
  UiScale = WindowScale(Win)
  If Abs(UiScale - FontScale) > 0.01 : BuildFonts() : EndIf
EndProcedure

Procedure DrawWindow()
  Protected margin.f = Neon_S(12), sc.i, sw.f, sh.f, px.f, rx.f, rw.f, y.f, hh.f
  Protected tp.q = MicroNow()
  ; one window, one GL context: it is made current once, in WindowRun (doing it every pass cost ~7 ms)
  SizeGlobals()
  Neon_ChromeBeginFrame(WindowMouseX(Win), WindowMouseY(Win), MouseDown, Wheel, KeyCode, KeyChar, 1.0 / 60.0)
  glBindFramebuffer(#GL_FRAMEBUFFER, 0)
  glDisable_(#GL_SCISSOR_TEST)
  glViewport_(0, 0, PhysW, PhysH)
  glClearColor_(0.03, 0.04, 0.06, 1.0) : glClear_(#GL_COLOR_BUFFER_BIT)
  ; the screen: the largest whole scale that fits the left 45 %
  sc = (PhysH - 2 * margin) / #VID_H
  If (PhysW * 0.45 - 2 * margin) / #VID_W < sc : sc = (PhysW * 0.45 - 2 * margin) / #VID_W : EndIf
  If sc < 1 : sc = 1 : EndIf
  sw = #VID_W * sc : sh = #VID_H * sc
  px = margin : y = (PhysH - sh) / 2
  Neon_Box(px - 2, y - 2, sw + 4, sh + 4, 0.15, 0.20, 0.30)
  PaneUs(6) + MicroNow() - tp : tp = MicroNow()
  ScreenTextureUpload()
  ; DrawGLSprite's position is the drawn rectangle's top-left at any scale
  DrawGLSprite(@ScreenSprite, px, y, 0.0, sc, 1.0, 1.0, 1.0, 1.0, #True, -1, -1, -1, -1, #True)
  ; the debug panes
  rx = px + sw + margin : rw = PhysW - rx - margin
  hh = Neon_S(150)
  PaneUs(0) + MicroNow() - tp : tp = MicroNow()
  DrawControls(rx, margin, rw, hh)
  PaneUs(1) + MicroNow() - tp : tp = MicroNow()
  DrawRegisters(rx, margin + hh + margin, rw, Neon_S(190))
  PaneUs(2) + MicroNow() - tp : tp = MicroNow()
  y = margin + hh + margin + Neon_S(190) + margin
  DrawDisassembly(rx, y, rw * 0.5 - margin / 2, PhysH - y - margin)
  PaneUs(3) + MicroNow() - tp : tp = MicroNow()
  DrawMemory(rx + rw * 0.5 + margin / 2, y, rw * 0.5 - margin / 2, PhysH - y - margin)
  PaneUs(4) + MicroNow() - tp : tp = MicroNow()
  Neon_ChromeEndFrame()
  If ShotPath <> "" And EmuFrameCount >= ShotFrames : SaveWindowShot(ShotPath) : ShotFrames = -1 : EndIf
  SetGadgetAttribute(Gl, #PB_OpenGL_FlipBuffers, #True)
  PaneUs(5) + MicroNow() - tp
  Wheel = 0 : KeyCode = 0 : KeyChar = 0
EndProcedure

Procedure.i HostKeys()
  Protected k.i
  If GetForegroundWindow_() <> WindowID(Win) : ProcedureReturn 0 : EndIf
  If Neon_FocusID <> 0 : ProcedureReturn 0 : EndIf      ; typing into the breakpoint box
  If GetAsyncKeyState_(#VK_UP) & $8000 : k | 1 : EndIf
  If GetAsyncKeyState_(#VK_LEFT) & $8000 : k | 2 : EndIf
  If GetAsyncKeyState_(#VK_RIGHT) & $8000 : k | 4 : EndIf
  If GetAsyncKeyState_(#VK_DOWN) & $8000 : k | 8 : EndIf
  If (GetAsyncKeyState_('5') & $8000) Or (GetAsyncKeyState_('C') & $8000) : k | $20 : EndIf
  If GetAsyncKeyState_('1') & $8000 : k | $100 : EndIf
  If GetAsyncKeyState_('2') & $8000 : k | $200 : EndIf
  ProcedureReturn k
EndProcedure

; What the window drew, saved as a PNG (the --shot mode).
Procedure SaveWindowShot(path.s)
  Protected *px = AllocateMemory(PhysW * PhysH * 4), img.i, x.i, y.i, c.l, *row
  glReadBuffer_(#GL_BACK)
  glReadPixels_(0, 0, PhysW, PhysH, #GL_RGBA, #GL_UNSIGNED_BYTE, *px)
  img = CreateImage(#PB_Any, PhysW, PhysH, 24)
  If img And StartDrawing(ImageOutput(img))
    For y = 0 To PhysH - 1
      *row = *px + (PhysH - 1 - y) * PhysW * 4
      For x = 0 To PhysW - 1
        c = PeekL(*row + x * 4)
        Plot(x, y, RGB(c & 255, (c >> 8) & 255, (c >> 16) & 255))
      Next
    Next
    StopDrawing()
    SaveImage(img, path, #PB_ImagePlugin_PNG)
  EndIf
  FreeMemory(*px)
EndProcedure

Procedure.q MicroNow()
  Protected c.q
  If QpcFreq = 0 : QueryPerformanceFrequency_(@QpcFreq) : EndIf
  QueryPerformanceCounter_(@c)
  ProcedureReturn c * 1000000 / QpcFreq
EndProcedure

Procedure WindowRun(folder.s)
  Protected ev.i, quit.i, frames.i, ok.i, nowUs.q, paceStart.q, paceFrames.q, i.i
  ExamineDesktops()
  Gl = OpenGLWindow("Ms. Pac-Man - PureMetal desktop (" + EmuCoreName() + ")", 1280, 820,
                    #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget | #PB_Window_SizeGadget)
  If Gl = 0 : MessageRequester("Ms. Pac-Man", "Could not open an OpenGL window.") : ProcedureReturn : EndIf
  Win = Util_MainWindowID
  UiScale = WindowScale(Win) : BuildFonts()
  GL_SetVSync(1)
  SetGadgetAttribute(Gl, #PB_OpenGL_SetContext, #True)
  ScreenTextureInit()
  ok = SoundOpen()
  SetActiveGadget(Gl)
  FpsMark = ElapsedMilliseconds() : SpeedMark = FpsMark
  Repeat
    Repeat
      ev = WindowEvent()
      Select ev
        Case #PB_Event_CloseWindow : quit = 1
        Case #PB_Event_Gadget
          If EventGadget() = Gl
            Select EventType()
              Case #PB_EventType_LeftButtonDown : MouseDown = #True
              Case #PB_EventType_LeftButtonUp : MouseDown = #False
              Case #PB_EventType_MouseWheel : Wheel + GetGadgetAttribute(Gl, #PB_OpenGL_WheelDelta)
              Case #PB_EventType_KeyDown
                KeyCode = GetGadgetAttribute(Gl, #PB_OpenGL_Key)
                If Neon_FocusID = 0
                  Select KeyCode
                    Case #PB_Shortcut_F5 : EmuRunning ! 1 : EmuStopReason = ""
                    Case #PB_Shortcut_F10 : If EmuRunning = 0 : EmuStep() : VideoRender() : EndIf
                    Case #PB_Shortcut_F11 : If EmuRunning = 0 : EmuFrame() : EndIf
                    Case #PB_Shortcut_F3 : MachineReset() : EmuTDebt = 0
                    Case #PB_Shortcut_M : SndMuted ! 1
                  EndSelect
                EndIf
              Case #PB_EventType_Input : KeyChar = GetGadgetAttribute(Gl, #PB_OpenGL_Input)
            EndSelect
          EndIf
      EndSelect
    Until ev = 0
    EmuHostHeld = HostKeys() | EmuHeldKeys
    Protected t0.q = MicroNow()
    If EmuRunning
      ; Paced by the PC's performance counter: frame n is due at n x 16,500 us (60.606 a second).
      ; A slow pass is caught up (up to 6 frames at once); further behind than that, the clock is
      ; moved instead of racing. The sound queue (8 frames) is the cushion between the two clocks.
      frames = 0
      nowUs = MicroNow()
      If paceStart = 0 Or EmuWasPaused : paceStart = nowUs - paceFrames * 16500 : EmuWasPaused = 0 : EndIf
      While EmuRunning And (nowUs - paceStart) >= paceFrames * 16500 And frames < 6
        EmuFrame() : frames + 1 : FpsCount + 1 : paceFrames + 1 : EmuHeldKeys = 0
      Wend
      If (nowUs - paceStart) - paceFrames * 16500 > 200000 : paceStart = nowUs - paceFrames * 16500 : PaceResyncs + 1 : EndIf
    Else
      EmuWasPaused = 1
    EndIf
    EmuUs + MicroNow() - t0
    If ElapsedMilliseconds() - FpsMark >= 1000
      DrawUsShown = DrawUs / (LoopCount + 0.001) : EmuUsShown = EmuUs * 1000.0 / (ElapsedMilliseconds() - FpsMark)
      LoopsShown = LoopCount * 1000.0 / (ElapsedMilliseconds() - FpsMark)
      For i = 0 To 6 : PaneShown(i) = PaneUs(i) / (LoopCount + 0.001) / 1000.0 : PaneUs(i) = 0 : Next
      DrawUs = 0 : EmuUs = 0 : LoopCount = 0
      FpsShown = FpsCount * 1000.0 / (ElapsedMilliseconds() - FpsMark)
      SpeedMHz = (EmuTStates - SpeedTStates) / 1000.0 / (ElapsedMilliseconds() - SpeedMark)
      FpsCount = 0 : FpsMark = ElapsedMilliseconds() : SpeedTStates = EmuTStates : SpeedMark = FpsMark
    EndIf
    t0 = MicroNow()
    DrawWindow()
    DrawUs + MicroNow() - t0 : LoopCount + 1
    If ShotFrames = -1 : quit = 1 : EndIf
  Until quit
  SoundClose()
EndProcedure

; ---------------------------------------------------------------------------
Define folder.s, i.i, logFrames.i, dump.s
For i = 0 To CountProgramParameters() - 1
  Select LCase(ProgramParameter(i))
    Case "--log" : i + 1 : logFrames = Val(ProgramParameter(i))
    Case "--dump" : i + 1 : dump = ProgramParameter(i)
    Case "--test-picture" : EmuTestPicture = 1
    Case "--press" : i + 1 : EmuPress = ProgramParameter(i)
    Case "--mute" : SndMuted = 1
    Case "--log-every" : i + 1 : LogEvery = Val(ProgramParameter(i)) : If LogEvery < 1 : LogEvery = 1 : EndIf
    Case "--shot" : i + 1 : ShotPath = ProgramParameter(i) : i + 1 : ShotFrames = Val(ProgramParameter(i))
    Default : folder = ProgramParameter(i)
  EndSelect
Next
If folder = "" And logFrames = 0
  folder = PathRequester("The folder with the Ms. Pac-Man ROM set (MAME 'mspacman')", "")
EndIf
If folder = ""
  End
EndIf
If EmuStart(folder) = 0
  If logFrames : OpenConsole() : PrintN("ROMS: " + RomError) : End 1 : EndIf
  MessageRequester("Ms. Pac-Man", RomError)
  End 1
EndIf
If logFrames
  LogRun(logFrames, dump)
Else
  WindowRun(folder)
EndIf
