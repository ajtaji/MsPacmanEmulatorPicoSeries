; Ms. Pac-Man for the desktop - PureBasic, drawn with the Neon Arcade Display Engine.
; The same machine as the Pico version (rp2040/), on the Z80 core with the Pico core's API.
;
; BUILD (x64, from PowerShell, C back end):
;   & "C:\Program Files\PureBasic\Compilers\pbcompilerc.exe" desktop\MsPacman.pb /EXE build\MsPacman.exe /THREAD /DPIAWARE
;       [/CONSTANT GL_ENGINE_DIR$=C:/path/to/engine/]   (default: Neon-Arcade-Dispay-Engine cloned beside this repo)
;       [/CONSTANT MSP_Z80_DIR$=C:/path/to/Z80EmulatorPicoSeries/desktop/]   (default: beside this repo)
; RUN:
;   MsPacman.exe [ROM folder]               the window (asks for the folder when none is given)
;   MsPacman.exe <ROM folder> --log N       no window: N frames, a log line per second, then exit
;                                           (--log-every F: a line every F frames)
;   MsPacman.exe <ROM folder> --test-picture --dump <file> [--log N]
;   MsPacman.exe <ROM folder> --press 600:coin,660:start,900:left ...   inputs held for 6 frames
;                                           at those frames (coin start start2 up down left right)
;   MsPacman.exe <ROM folder> --log N --wav <file>   the sound chip's output saved as a WAV
;   MsPacman.exe <ROM folder> --poke 900:4EBC:01,...   writes Z80 memory at those frames (hex)
;   MsPacman.exe <ROM folder> --log N --sndtrace <file>   a line a frame: the sound driver's channel bytes
;                                           and the sound chip's registers
;   MsPacman.exe <ROM folder> --mute ...    starts with the sound muted (M toggles it)
;   MsPacman.exe <ROM folder> --fullscreen-test <log>   full screen in and out twice, checked (synthetic)
;   MsPacman.exe <ROM folder> --pointer-test <log>   the window checks its controls with synthetic pointer
;                                           positions (never the real pointer); exit code = failures
;   MsPacman.exe <ROM folder> --shot <png> <frames>
;                                           the window for that many frames, then its picture
;                                           saved and the program closes by itself
;                                           the fixed test picture (as Diagnostics/video_check)
;
; KEYS: the controls table (CtlInit; the Controls button shows it): arrows = joystick, 5 or C = coin,
;       1 / 2 = 1P / 2P start, F5 run/pause, F10 step one instruction, F9 one frame, F3 reset, M mute,
;       F11 full screen on/off, Esc leaves full screen.
; The ROMs are commercial: none are in the repository; the folder is the user's.

EnableExplicit

CompilerIf Not Defined(GL_ENGINE_DIR$, #PB_Constant)
  #GL_ENGINE_DIR$ = #PB_Compiler_FilePath + "../../Neon-Arcade-Dispay-Engine/"   ; github.com/ajtaji/Neon-Arcade-Dispay-Engine
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

; --wav: the sound chip's output (what the speakers get, 48 kHz mono 16-bit) to a file.
Global WavFile.i, WavSamples.q
Procedure WavOpen(path.s)
  WavFile = CreateFile(#PB_Any, path)
  If WavFile = 0 : ProcedureReturn : EndIf
  WriteString(WavFile, "RIFF", #PB_Ascii) : WriteLong(WavFile, 0) : WriteString(WavFile, "WAVEfmt ", #PB_Ascii)
  WriteLong(WavFile, 16) : WriteWord(WavFile, 1) : WriteWord(WavFile, 1) : WriteLong(WavFile, 48000)
  WriteLong(WavFile, 96000) : WriteWord(WavFile, 2) : WriteWord(WavFile, 16)
  WriteString(WavFile, "data", #PB_Ascii) : WriteLong(WavFile, 0)
EndProcedure
Procedure WavClose()
  If WavFile = 0 : ProcedureReturn : EndIf
  FileSeek(WavFile, 4) : WriteLong(WavFile, 36 + WavSamples * 2)
  FileSeek(WavFile, 40) : WriteLong(WavFile, WavSamples * 2)
  CloseFile(WavFile) : WavFile = 0
EndProcedure

; --sndtrace: a line a frame - the sound driver's six channel bytes ($4E9C effect 1-3, $4ECC song 1-3,
; as the game left them for the next interrupt), the frame counter $4C84 and the game mode $4E00, and the
; 32 sound registers the chip plays this frame.
; The driver's inputs are taken when the Z80 reaches the driver ($2D0C, inside the interrupt), because the
; game's own logic runs earlier in the same interrupt and may change them after vertical blank.
Global SndTraceFile.i, SndTraceIn.s = " 00 00 00 00 00 00 00 00 00"
Procedure SndTraceCapture()
  Protected i.i
  SndTraceIn = ""
  For i = 0 To 5 : SndTraceIn + " " + RSet(Hex(Z80Mem($4E9C + i * 16)), 2, "0") : Next
  SndTraceIn + " " + RSet(Hex(Z80Mem($4C84)), 2, "0") + " " + RSet(Hex(Z80Mem($4E00)), 2, "0") + " " + RSet(Hex(Z80Mem($4E13)), 2, "0")
EndProcedure
Procedure SndTrace()
  Protected i.i, line.s = Str(MspFrames) + SndTraceIn + " |"
  For i = 0 To 31 : line + " " + Hex(WsgRegs(i) & 15) : Next
  WriteStringN(SndTraceFile, line, #PB_Ascii)
EndProcedure

; --poke "frame:addr:value,...": writes into the Z80's memory at the start of those frames (hex address and
; value), e.g. to start one of the sound driver's effects or songs by its channel bit. "first-last:addr:value"
; writes it at the start of every frame in that range.
Global EmuPoke.s
Procedure EmuPokes()
  Protected i.i, item.s, span.s, first.i, last.i, n.i = CountString(EmuPoke, ",") + 1
  For i = 1 To n
    item = StringField(EmuPoke, i, ",")
    span = StringField(item, 1, ":")
    first = Val(StringField(span, 1, "-"))
    last = first
    If FindString(span, "-") : last = Val(StringField(span, 2, "-")) : EndIf
    If MspFrames >= first And MspFrames <= last
      Z80Mem(Val("$" + StringField(item, 2, ":")) & $FFFF) = Val("$" + StringField(item, 3, ":")) & 255
    EndIf
  Next
EndProcedure

; Vertical blank: the picture, the frame's sound, the controls, the watchdog, the interrupt.
Procedure EmuVblank()
  If EmuPoke <> "" : EmuPokes() : EndIf
  If EmuTestPicture : EmuTestPictureFill() : EndIf
  VideoRender()
  WsgRender()
  If SndTraceFile : SndTrace() : EndIf
  SoundQueue()
  If WavFile : WriteData(WavFile, @SndFrame(0), #MSP_FRAME_SAMPLES * 2) : WavSamples + #MSP_FRAME_SAMPLES : EndIf
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
  If SndTraceFile                          ; an instruction at a time, to the next vertical blank
    used = MspFrames
    Repeat
      EmuStep()
      If Z80PC = $2D0C                      ; the sound driver: pokes again (the game's logic in this
        If EmuPoke <> "" : EmuPokes() : EndIf ; interrupt may have changed them), then its inputs
        SndTraceCapture()
      EndIf
      If Z80Stopped : Break : EndIf
    Until MspFrames <> used
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
  If WavFile : PrintN("sound written: " + Str(WavSamples) + " samples") : WavClose() : EndIf
  If SndTraceFile : CloseFile(SndTraceFile) : SndTraceFile = 0 : EndIf
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
; --pointer-test (see its section): the synthetic pointer, and where the memory pane was drawn
Global PtOn.i, PtFile.s, PtX.f, PtY.f, PtDown.b, PtWheel.i, PtPass.i, PtPhase.i, PtFails.i, PtPoints.i, PtWorst.f
Global PtLog.s, PtBefore.s, PtMemTop.i, PtDone.i
Global MemPaneX.f, MemPaneY.f, MemPaneW.f, MemPaneH.f, TabStripY.f
Structure PtRect : x.f : y.f : w.f : h.f : EndStructure
Global NewMap PtCtl.PtRect()                    ; the Run panel's controls, by name, as last drawn
Procedure PtNote(name.s, x.f, y.f, w.f, h.f)
  PtCtl(name)\x = x : PtCtl(name)\y = y : PtCtl(name)\w = w : PtCtl(name)\h = h
EndProcedure

; ---------------------------------------------------------------- the controls
; ONE table, read by the input code (CtlHeld, CtlKey), by the Run panel's button labels and by the Controls
; panel - so what the panel shows is what the keys do. The README's "Controls" section is copied from it.
;   kind 0: an arcade input, held while one of its keys is down; bits as EmuHostHeld takes them (1 up,
;           2 left, 4 right, 8 down, $20 coin, $100 1 player start, $200 2 player start); vk1/vk2 the keys
;   kind 1: an emulator shortcut; key = the shortcut code the GL gadget reports; always = it works while
;           typing in the breakpoint box too
; The emulator reads the keyboard only (no gamepad). The arcade machine has no Esc key, so Esc only ever
; leaves full screen; F11, the full-screen key, used to be "one frame", which is F9 now.
Enumeration CtlAction 1
  #ACT_RUN : #ACT_STEP : #ACT_FRAME : #ACT_RESET : #ACT_MUTE : #ACT_FULL : #ACT_LEAVE
EndEnumeration
Structure CtlEntry
  kind.i : name.s : keys.s : vk1.i : vk2.i : bits.i : action.i : key.i : always.i
EndStructure
Global NewList Ctl.CtlEntry()
Declare EnterFull()
Declare LeaveFull()
Global FullOn.i, ShowControls.i

Procedure CtlAdd(kind.i, name.s, keys.s, vk1.i, vk2.i, bits.i, action.i, key.i, always.i = 0)
  AddElement(Ctl())
  Ctl()\kind = kind : Ctl()\name = name : Ctl()\keys = keys : Ctl()\vk1 = vk1 : Ctl()\vk2 = vk2
  Ctl()\bits = bits : Ctl()\action = action : Ctl()\key = key : Ctl()\always = always
EndProcedure

Procedure CtlInit()
  CtlAdd(0, "Joystick up", "Up arrow", #VK_UP, 0, 1, 0, 0)
  CtlAdd(0, "Joystick down", "Down arrow", #VK_DOWN, 0, 8, 0, 0)
  CtlAdd(0, "Joystick left", "Left arrow", #VK_LEFT, 0, 2, 0, 0)
  CtlAdd(0, "Joystick right", "Right arrow", #VK_RIGHT, 0, 4, 0, 0)
  CtlAdd(0, "Coin", "5 or C", '5', 'C', $20, 0, 0)
  CtlAdd(0, "1 player start", "1", '1', 0, $100, 0, 0)
  CtlAdd(0, "2 player start", "2", '2', 0, $200, 0, 0)
  CtlAdd(1, "Run / pause", "F5", 0, 0, 0, #ACT_RUN, #PB_Shortcut_F5)
  CtlAdd(1, "Step one instruction (paused)", "F10", 0, 0, 0, #ACT_STEP, #PB_Shortcut_F10)
  CtlAdd(1, "Run one frame (paused)", "F9", 0, 0, 0, #ACT_FRAME, #PB_Shortcut_F9)
  CtlAdd(1, "Reset", "F3", 0, 0, 0, #ACT_RESET, #PB_Shortcut_F3)
  CtlAdd(1, "Sound on / off", "M", 0, 0, 0, #ACT_MUTE, #PB_Shortcut_M)
  CtlAdd(1, "Full screen on / off", "F11", 0, 0, 0, #ACT_FULL, #PB_Shortcut_F11, 1)
  CtlAdd(1, "Leave full screen", "Esc", 0, 0, 0, #ACT_LEAVE, #PB_Shortcut_Escape, 1)
EndProcedure

; The keys of a shortcut, for a button's label.
Procedure.s CtlKeys(action.i)
  ForEach Ctl()
    If Ctl()\action = action : ProcedureReturn Ctl()\keys : EndIf
  Next
  ProcedureReturn ""
EndProcedure

; The arcade inputs held now.
Procedure.i CtlHeld()
  Protected k.i
  ForEach Ctl()
    If Ctl()\kind = 0
      If (GetAsyncKeyState_(Ctl()\vk1) & $8000) Or (Ctl()\vk2 And (GetAsyncKeyState_(Ctl()\vk2) & $8000)) : k | Ctl()\bits : EndIf
    EndIf
  Next
  ProcedureReturn k
EndProcedure

Procedure CtlDo(action.i)
  Select action
    Case #ACT_RUN : EmuRunning ! 1 : EmuStopReason = ""
    Case #ACT_STEP : If EmuRunning = 0 : EmuStep() : VideoRender() : EndIf
    Case #ACT_FRAME : If EmuRunning = 0 : EmuFrame() : EndIf
    Case #ACT_RESET : MachineReset() : EmuTDebt = 0
    Case #ACT_MUTE : SndMuted ! 1
    Case #ACT_FULL : If FullOn : LeaveFull() : Else : EnterFull() : EndIf
    Case #ACT_LEAVE : If FullOn : LeaveFull() : EndIf
  EndSelect
EndProcedure

; A key the GL gadget reported (#PB_EventType_KeyDown).
Procedure CtlKey(code.i)
  ForEach Ctl()
    If Ctl()\kind = 1 And Ctl()\key = code
      If Neon_FocusID = 0 Or Ctl()\always : CtlDo(Ctl()\action) : EndIf
      ProcedureReturn
    EndIf
  Next
EndProcedure

Global FpsShown.f, FpsCount.i, FpsMark.q, SpeedTStates.q, SpeedMark.q, SpeedMHz.f
Global GetDpiForWindow_.i, ShotPath.s, ShotFrames.i
Global EmuWasPaused.i, PaceResyncs.i
Global Dim PaneUs.q(7), Dim PaneShown.f(7)
Global DrawUs.q, EmuUs.q, LoopCount.q, DrawUsShown.f, EmuUsShown.f, LoopsShown.f, QpcFreq.q
Declare SaveWindowShot(path.s)
Declare.q MicroNow()

; The display scale as measured: the physical client width (GetClientRect) over the logical inner width.
Procedure.f MeasuredScale()
  Protected r.RECT, lw.i = WindowWidth(Win, #PB_Window_InnerCoordinate)
  GetClientRect_(WindowID(Win), @r)
  If lw <= 0 Or r\right - r\left <= 0 : ProcedureReturn 1.0 : EndIf
  ProcedureReturn (r\right - r\left) / lw
EndProcedure

Procedure BuildFonts()
  Protected s.f = UiScale
  If *Neon_FontUI    : FreeGLFont(*Neon_FontUI)    : EndIf
  If *Neon_FontSmall : FreeGLFont(*Neon_FontSmall) : EndIf
  If *Neon_FontBold  : FreeGLFont(*Neon_FontBold)  : EndIf
  If *Neon_FontMono  : FreeGLFont(*Neon_FontMono)  : EndIf
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
  MemPaneX = x : MemPaneY = y : MemPaneW = w : MemPaneH = h : TabStripY = y + Neon_S(30)
  If Neon_Hit(x, y, w, h) And Neon_Wheel : MemTop - Neon_Wheel * 2 : EndIf
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
  If EmuRunning : lab = "Pause  " : Else : lab = "Run  " : EndIf
  lab + CtlKeys(#ACT_RUN)
  PtNote("pause", gx, gy, bw, bh) : PtNote("step", gx + bw + Neon_S(6), gy, bw, bh)
  PtNote("frame", gx + 2 * (bw + Neon_S(6)), gy, bw, bh) : PtNote("reset", gx + 3 * (bw + Neon_S(6)), gy, bw, bh)
  If Neon_Button(gx, gy, bw, bh, lab, EmuRunning) : EmuRunning ! 1 : EmuStopReason = "" : EndIf
  If Neon_Button(gx + bw + Neon_S(6), gy, bw, bh, "Step  " + CtlKeys(#ACT_STEP), #False, Bool(EmuRunning = 0)) : CtlDo(#ACT_STEP) : EndIf
  If Neon_Button(gx + 2 * (bw + Neon_S(6)), gy, bw, bh, "Frame  " + CtlKeys(#ACT_FRAME), #False, Bool(EmuRunning = 0)) : CtlDo(#ACT_FRAME) : EndIf
  If Neon_Button(gx + 3 * (bw + Neon_S(6)), gy, bw, bh, "Reset  " + CtlKeys(#ACT_RESET)) : CtlDo(#ACT_RESET) : EndIf
  PtNote("controls", gx + 4 * (bw + Neon_S(6)), gy, bw, bh) : PtNote("full", gx + 5 * (bw + Neon_S(6)), gy, Neon_S(130), bh)
  If Neon_Button(gx + 4 * (bw + Neon_S(6)), gy, bw, bh, "Controls", ShowControls) : ShowControls ! 1 : EndIf
  If Neon_Button(gx + 5 * (bw + Neon_S(6)), gy, Neon_S(130), bh, "Full screen  " + CtlKeys(#ACT_FULL)) : CtlDo(#ACT_FULL) : EndIf
  gy + bh + Neon_S(8)
  PtNote("focus", gx + Neon_S(70), gy, Neon_S(80), bh) : PtNote("clear", gx + Neon_S(160), gy, Neon_S(70), bh)
  PtNote("coin", gx + Neon_S(240), gy, Neon_S(80), bh) : PtNote("1p", gx + Neon_S(326), gy, Neon_S(80), bh)
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
  Protected client.RECT, cw.i = WindowWidth(Win, #PB_Window_InnerCoordinate), ch.i = WindowHeight(Win, #PB_Window_InnerCoordinate)
  GetClientRect_(WindowID(Win), @client)
  ; the physical size is compared too: a move to a monitor with another scale may keep the logical size
  If cw = SizedW And ch = SizedH And client\right - client\left = PhysW And client\bottom - client\top = PhysH : ProcedureReturn : EndIf
  SizedW = cw : SizedH = ch
  ResizeGadget(Gl, 0, 0, cw, ch)                ; the gadget fills the inner client from (0,0); a 1:1 window: no GL_HandleResize
  PhysW = client\right - client\left : PhysH = client\bottom - client\top
  If PhysW < 1 : PhysW = 1 : EndIf
  If PhysH < 1 : PhysH = 1 : EndIf
  Util_BaseWidth = PhysW : Util_BaseHeight = PhysH
  Util_WinWidth = cw : Util_WinHeight = ch
  GL_ViewportX = 0 : GL_ViewportY = 0 : GL_ViewportW = PhysW : GL_ViewportH = PhysH
  UiScale = MeasuredScale()
  If Abs(UiScale - FontScale) > 0.01 : BuildFonts() : EndIf
EndProcedure

; ---------------------------------------------------------------- full screen
; A borderless window covering the monitor the window is on (no display-mode change), drawing only the
; game: its 224 x 288 picture at the arcade monitor's real shape - a 4:3 tube turned on its side, so 3:4 -
; as large as fits, centred, black around it. A whole-number scale is taken when it loses at most a tenth
; of the height. The windowed placement is saved and put back exactly; the scale is measured again on the
; way in and out (SizeGlobals). The cursor hides after 2 s without moving and shows again when moved.
Declare SaveWindowShot(path.s)
Global FullPlace.WINDOWPLACEMENT, FullStyle.i, FullMonL.i, FullMonT.i, FullMonR.i, FullMonB.i
Global FullDrawX.f, FullDrawY.f, FullDrawW.f, FullDrawH.f, FullShot.s
Global FullLastMX.i = -1, FullLastMY.i = -1, FullMovedMs.q, FullCursorHidden.i
Global ScreenSprite34.GLSprite                  ; the screen texture at the monitor's shape: 216 x 288 = 3:4

Procedure EnterFull()
  Protected hwnd.i = WindowID(Win), mi.MONITORINFO
  If FullOn : ProcedureReturn : EndIf
  FullPlace\length = SizeOf(WINDOWPLACEMENT)
  GetWindowPlacement_(hwnd, @FullPlace)
  FullStyle = GetWindowLongPtr_(hwnd, #GWL_STYLE)
  mi\cbSize = SizeOf(MONITORINFO)
  GetMonitorInfo_(MonitorFromWindow_(hwnd, #MONITOR_DEFAULTTONEAREST), @mi)
  FullMonL = mi\rcMonitor\left : FullMonT = mi\rcMonitor\top : FullMonR = mi\rcMonitor\right : FullMonB = mi\rcMonitor\bottom
  SetWindowLongPtr_(hwnd, #GWL_STYLE, (FullStyle & ~#WS_OVERLAPPEDWINDOW) | #WS_POPUP)
  SetWindowPos_(hwnd, #HWND_TOP, FullMonL, FullMonT, FullMonR - FullMonL, FullMonB - FullMonT, #SWP_FRAMECHANGED | #SWP_NOOWNERZORDER | #SWP_SHOWWINDOW)
  FullOn = 1 : SizedW = -1 : FullMovedMs = ElapsedMilliseconds() : FullLastMX = -1
  SetActiveGadget(Gl)
EndProcedure

Procedure LeaveFull()
  Protected hwnd.i = WindowID(Win)
  If FullOn = 0 : ProcedureReturn : EndIf
  SetWindowLongPtr_(hwnd, #GWL_STYLE, FullStyle)
  SetWindowPlacement_(hwnd, @FullPlace)
  SetWindowPos_(hwnd, 0, 0, 0, 0, 0, #SWP_NOMOVE | #SWP_NOSIZE | #SWP_NOZORDER | #SWP_NOOWNERZORDER | #SWP_FRAMECHANGED)
  If FullCursorHidden : ShowCursor_(#True) : FullCursorHidden = 0 : EndIf
  FullOn = 0 : SizedW = -1
  SetActiveGadget(Gl)
EndProcedure

; The cursor in full screen: hidden after 2 s still, shown when it moves.
Procedure FullCursor()
  Protected mx.i = WindowMouseX(Win), my.i = WindowMouseY(Win)
  If mx <> FullLastMX Or my <> FullLastMY
    FullLastMX = mx : FullLastMY = my : FullMovedMs = ElapsedMilliseconds()
    If FullCursorHidden : ShowCursor_(#True) : FullCursorHidden = 0 : EndIf
  ElseIf FullCursorHidden = 0 And ElapsedMilliseconds() - FullMovedMs > 2000
    ShowCursor_(#False) : FullCursorHidden = 1
  EndIf
EndProcedure

; Full screen: only the game.
Procedure DrawFullScreen()
  Protected k.f, ki.i
  glBindFramebuffer(#GL_FRAMEBUFFER, 0)
  glDisable_(#GL_SCISSOR_TEST)
  glViewport_(0, 0, PhysW, PhysH)
  glClearColor_(0.0, 0.0, 0.0, 1.0) : glClear_(#GL_COLOR_BUFFER_BIT)
  ScreenTextureUpload()
  ScreenSprite34\TextureID = ScreenTex : ScreenSprite34\Width = #VID_H * 3 / 4 : ScreenSprite34\Height = #VID_H
  k = PhysH / #VID_H                                   ; the height fills the monitor ...
  If ScreenSprite34\Width * k > PhysW : k = PhysW / ScreenSprite34\Width : EndIf   ; ... unless the width does not fit
  ki = Int(k)
  If ki >= 1 And ki >= k * 0.9 : k = ki : EndIf        ; a whole-number scale, when it loses at most a tenth
  FullDrawW = ScreenSprite34\Width * k : FullDrawH = #VID_H * k
  FullDrawX = (PhysW - FullDrawW) / 2 : FullDrawY = (PhysH - FullDrawH) / 2
  DrawGLSprite(@ScreenSprite34, FullDrawX, FullDrawY, 0.0, k, 1.0, 1.0, 1.0, 1.0, #True, -1, -1, -1, -1, #True)
  If FullShot <> "" : SaveWindowShot(FullShot) : FullShot = "" : EndIf
  SetGadgetAttribute(Gl, #PB_OpenGL_FlipBuffers, #True)
  FullCursor()
EndProcedure

; The Controls panel: the controls table, as the input code reads it.
Procedure DrawControlsPanel(x.f, y.f, w.f, h.f)
  Protected cy.f = y + Neon_S(40), lh.f = *Neon_FontUI\LineHeight + Neon_S(4), kind.i = -1, col.f = x + Neon_S(250)
  Neon_Panel(x, y, w, h, "Controls (keyboard; no gamepad)", 1.0, 0.85, 0.30, Neon_S(26))
  PtNote("close", x + w - Neon_S(90), y + Neon_S(4), Neon_S(80), Neon_S(22))
  If Neon_Button(x + w - Neon_S(90), y + Neon_S(4), Neon_S(80), Neon_S(22), "Close") : ShowControls = 0 : EndIf
  ForEach Ctl()
    If Ctl()\kind <> kind
      kind = Ctl()\kind
      If kind = 0 : Neon_Text(*Neon_FontBold, x + Neon_S(12), cy, "The arcade machine", 1.0, 0.85, 0.30)
      Else : cy + Neon_S(8) : Neon_Text(*Neon_FontBold, x + Neon_S(12), cy, "The emulator", 1.0, 0.85, 0.30)
      EndIf
      cy + lh
    EndIf
    Neon_Text(*Neon_FontUI, x + Neon_S(24), cy, Ctl()\name, 0.85, 0.9, 0.95)
    Neon_Text(*Neon_FontUI, col, cy, Ctl()\keys, 0.45, 0.95, 1.0)
    cy + lh
  Next
EndProcedure

; ---------------------------------------------------------------- --fullscreen-test
; Synthetic, like --pointer-test: in by the Full screen button (a synthetic press) and out by Esc, then in
; and out by F11 - both through the same key handler as the keyboard. Each time in: the window covers its
; monitor exactly, the game is 3:4 and centred, the emulation keeps 60.6 frames a second; each time out:
; the windowed placement, style, client size and scale are back exactly. Saves one picture of this window
; in full screen (<log>.png).
Global FsOn.i, FsFile.s, FsLog.s, FsFails.i, FsPass.i, FsCycle.i, FsState.i, FsMs.q, FsF0.q
Global FsRect.RECT, FsClient.RECT, FsStyle.i, FsScale.f

Procedure FsCheck(ok.i, what.s)
  If ok : FsLog + "PASS " + what + #LF$ : Else : FsLog + "FAIL " + what + #LF$ : FsFails + 1 : EndIf
EndProcedure

Procedure.i FsDone()
  ProcedureReturn Bool(FsCycle >= 2)
EndProcedure

; Called after each window pass.
Procedure FsStep()
  Protected r.RECT, c.RECT, aspect.f, fps.f, gapL.f, gapR.f, gapT.f, gapB.f, how.s
  FsPass + 1
  If FsPass < 40 Or FsCycle >= 2 : ProcedureReturn : EndIf
  If FsCycle = 0 : how = "the Full screen button, out by Esc" : Else : how = "F11, out by F11" : EndIf
  Select FsState
    Case 0                                            ; windowed: note everything, then go in
      GetWindowRect_(WindowID(Win), @FsRect) : GetClientRect_(WindowID(Win), @FsClient)
      FsStyle = GetWindowLongPtr_(WindowID(Win), #GWL_STYLE) : FsScale = Neon_UIScale
      FsLog + "cycle " + Str(FsCycle + 1) + ", in by " + how + #LF$
      FsLog + "  windowed: window " + Str(FsRect\left) + "," + Str(FsRect\top) + " " + Str(FsRect\right - FsRect\left) + "x" +
              Str(FsRect\bottom - FsRect\top) + ", client " + Str(FsClient\right) + "x" + Str(FsClient\bottom) + ", scale " + StrF(FsScale, 3) + #LF$
      If FsCycle = 0                                  ; a synthetic press where the button was drawn
        PtX = PtCtl("full")\x + PtCtl("full")\w / 2 : PtY = PtCtl("full")\y + PtCtl("full")\h / 2 : PtDown = 1
      Else
        CtlKey(#PB_Shortcut_F11)
      EndIf
      FsState = 1 : FsMs = ElapsedMilliseconds()
    Case 1                                            ; the release, then let it settle for a second
      PtDown = 0 : PtX = -100 : PtY = -100
      If ElapsedMilliseconds() - FsMs > 1000 : FsF0 = EmuFrameCount : FsMs = ElapsedMilliseconds() : FsState = 2 : EndIf
    Case 2                                            ; three seconds in full screen, then judge it
      If ElapsedMilliseconds() - FsMs < 3000 : ProcedureReturn : EndIf
      fps = (EmuFrameCount - FsF0) * 1000.0 / (ElapsedMilliseconds() - FsMs)
      GetWindowRect_(WindowID(Win), @r) : GetClientRect_(WindowID(Win), @c)
      FsCheck(FullOn, "  full screen is on")
      FsCheck(Bool(r\left = FullMonL And r\top = FullMonT And r\right = FullMonR And r\bottom = FullMonB),
              "  the window covers its monitor: " + Str(r\left) + "," + Str(r\top) + "-" + Str(r\right) + "," + Str(r\bottom) +
              " (monitor " + Str(FullMonL) + "," + Str(FullMonT) + "-" + Str(FullMonR) + "," + Str(FullMonB) + ")")
      FsCheck(Bool(c\right = PhysW And c\bottom = PhysH And PhysW = FullMonR - FullMonL And PhysH = FullMonB - FullMonT),
              "  client and canvas are the monitor's size: " + Str(PhysW) + "x" + Str(PhysH))
      aspect = FullDrawW / FullDrawH
      FsCheck(Bool(Abs(aspect - 0.75) < 0.002), "  the game is 3:4: " + StrF(FullDrawW, 1) + " x " + StrF(FullDrawH, 1) + " = " + StrF(aspect, 4))
      gapL = FullDrawX : gapR = PhysW - FullDrawX - FullDrawW : gapT = FullDrawY : gapB = PhysH - FullDrawY - FullDrawH
      FsCheck(Bool(Abs(gapL - gapR) <= 1 And Abs(gapT - gapB) <= 1 And gapL >= 0 And gapT >= 0),
              "  centred: bars left " + StrF(gapL, 1) + " right " + StrF(gapR, 1) + " top " + StrF(gapT, 1) + " bottom " + StrF(gapB, 1))
      FsCheck(Bool(Abs(Neon_UIScale - MeasuredScale()) < 0.01), "  the scale measured again: " + StrF(Neon_UIScale, 3))
      FsCheck(Bool(fps > 59.6 And fps < 61.6), "  the emulation keeps time: " + StrF(fps, 2) + " frames a second over 3 s")
      FsLog + "  (cursor " + StringField("shown,hidden", FullCursorHidden + 1, ",") + " after 3 s without a move here)" + #LF$
      If FsCycle = 0 : FullShot = FsFile + ".png" : EndIf
      FsState = 3 : FsMs = ElapsedMilliseconds()
    Case 3                                            ; out
      If FsCycle = 0 : CtlKey(#PB_Shortcut_Escape) : Else : CtlKey(#PB_Shortcut_F11) : EndIf
      FsState = 4 : FsMs = ElapsedMilliseconds()
    Case 4                                            ; a second later: everything as it was?
      If ElapsedMilliseconds() - FsMs < 1000 : ProcedureReturn : EndIf
      GetWindowRect_(WindowID(Win), @r) : GetClientRect_(WindowID(Win), @c)
      FsCheck(Bool(FullOn = 0), "  full screen is off")
      FsCheck(Bool(r\left = FsRect\left And r\top = FsRect\top And r\right = FsRect\right And r\bottom = FsRect\bottom),
              "  the windowed rectangle is back exactly: " + Str(r\left) + "," + Str(r\top) + " " + Str(r\right - r\left) + "x" + Str(r\bottom - r\top))
      FsCheck(Bool(c\right = FsClient\right And c\bottom = FsClient\bottom), "  the client size is back: " + Str(c\right) + "x" + Str(c\bottom))
      FsCheck(Bool(GetWindowLongPtr_(WindowID(Win), #GWL_STYLE) = FsStyle), "  the window style is back")
      FsCheck(Bool(Abs(Neon_UIScale - FsScale) < 0.01 And Abs(Neon_UIScale - MeasuredScale()) < 0.01), "  the scale measured again: " + StrF(Neon_UIScale, 3))
      FsCheck(Bool(FullCursorHidden = 0), "  the cursor is shown")
      FsCycle + 1 : FsState = 0
      If FsCycle >= 2 : FsLog + "fullscreen-test: " + Str(FsFails) + " failures" + #LF$ : EndIf
  EndSelect
EndProcedure

Procedure DrawWindow()
  Protected margin.f = Neon_S(12), sc.i, sw.f, sh.f, px.f, rx.f, rw.f, y.f, hh.f
  Protected tp.q = MicroNow()
  ; one window, one GL context: it is made current once, in WindowRun (doing it every pass cost ~7 ms)
  SizeGlobals()
  If FullOn                                       ; full screen: the game alone
    DrawFullScreen()
    Wheel = 0 : KeyCode = 0 : KeyChar = 0
    ProcedureReturn
  EndIf
  ; WindowMouseX/Y as they are (physical in a DPI-aware window); --pointer-test feeds its own point the same way
  Protected mx.i = WindowMouseX(Win), my.i = WindowMouseY(Win), down.b = MouseDown, wh.i = Wheel
  If PtOn Or FsOn : mx = PtX : my = PtY : down = PtDown : wh = PtWheel : EndIf
  Neon_ChromeBeginFrame(mx, my, down, wh, KeyCode, KeyChar, 1.0 / 60.0)
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
  Neon_Box(px - Neon_S(2), y - Neon_S(2), sw + Neon_S(4), sh + Neon_S(4), 0.15, 0.20, 0.30)
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
  If ShowControls                                 ; the Controls panel in place of the two lower panes
    DrawControlsPanel(rx, y, rw, PhysH - y - margin)
  Else
    DrawDisassembly(rx, y, rw * 0.5 - margin / 2, PhysH - y - margin)
    PaneUs(3) + MicroNow() - tp : tp = MicroNow()
    DrawMemory(rx + rw * 0.5 + margin / 2, y, rw * 0.5 - margin / 2, PhysH - y - margin)
  EndIf
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
  ProcedureReturn CtlHeld()                            ; the controls table
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

; ---------------------------------------------------------------- --pointer-test
; The real pointer is shared with everyone on this desktop, so it is never moved: the window is driven with
; synthetic positions in the units WindowMouseX/Y give a DPI-aware window (physical pixels), through the same
; path (Neon_ChromeBeginFrame). For every control the engine registered: four points just inside its left,
; right, top and bottom edges - the engine must read the point back (Neon_MX/MY) and find that control
; there; then a press and release on each control of the Run panel and each memory tab, which must do what
; the control does; then a wheel turn at four points of the memory pane at the bottom, which must scroll it.
; /CONSTANT PLANT_CRT=1 turns the engine's CRT curve back on, only to see the test fail.
Structure PtStepT
  x.f : y.f : id.i : kind.i      ; kind: 0 hover, 1 click, 2 wheel
  expect.s : what.s
EndStructure
Global NewList PtSteps.PtStepT()

Procedure.s PtState()
  ProcedureReturn "running=" + Str(EmuRunning) + " instr=" + Str(EmuInstr) + " frames=" + Str(EmuFrameCount) + " pc=" + Hex(Z80PC) +
                  " held=" + Hex(EmuHeldKeys) + " focus=" + Str(Neon_FocusID) + " tab=" + Str(MemTab) + " controls=" + Str(ShowControls) + " break=" + BreakText\s
EndProcedure

Procedure PtAdd(x.f, y.f, id.i, kind.i, what.s, expect.s = "")
  AddElement(PtSteps())
  PtSteps()\x = x : PtSteps()\y = y : PtSteps()\id = id : PtSteps()\kind = kind : PtSteps()\what = what : PtSteps()\expect = expect
EndProcedure

Procedure PtBuild()
  Protected i.i, k.i, x.f, y.f, w.f, h.f, id.i, m.f = Neon_S(2), name.s
  Protected NewList tabs.i()
  For i = 0 To Neon_HotPrevCount - 1
    x = Neon_HotPrev(i)\x : y = Neon_HotPrev(i)\y : w = Neon_HotPrev(i)\w : h = Neon_HotPrev(i)\h : id = Neon_HotPrev(i)\id
    If w < 4 Or h < 4 : Continue : EndIf
    PtAdd(x + m, y + h / 2, id, 0, "left edge")
    PtAdd(x + w - m, y + h / 2, id, 0, "right edge")
    PtAdd(x + w / 2, y + m, id, 0, "top edge")
    PtAdd(x + w / 2, y + h - m, id, 0, "bottom edge")
  Next
  ; presses on the Run panel, by name, where each was drawn (Pause first: it enables Step and Frame)
  For k = 1 To 8
    name = StringField("pause,step,frame,reset,focus,clear,coin,1p", k, ",")
    If FindMapElement(PtCtl(), name)
      PtAdd(PtCtl()\x + PtCtl()\w - m, PtCtl()\y + PtCtl()\h - m, 0, 1, "press " + name + ", bottom-right", name)
    EndIf
  Next
  ; the memory tabs, by their place in the strip
  For i = 0 To Neon_HotPrevCount - 1
    If Abs(Neon_HotPrev(i)\y - TabStripY) < Neon_S(4) And Neon_HotPrev(i)\w >= 4 : AddElement(tabs()) : tabs() = i : EndIf
  Next
  k = 0
  ForEach tabs()
    x = Neon_HotPrev(tabs())\x : y = Neon_HotPrev(tabs())\y : w = Neon_HotPrev(tabs())\w : h = Neon_HotPrev(tabs())\h
    PtAdd(x + w - m, y + h - m, Neon_HotPrev(tabs())\id, 1, "press, bottom-right corner", "tab" + Str(k))
    k + 1
  Next
  ; the memory pane at the bottom of the window: a wheel turn at four points; then the Controls button,
  ; which opens the Controls panel over the lower panes and closes it (the Full screen button is
  ; --fullscreen-test's)
  PtAdd(MemPaneX + m, MemPaneY + MemPaneH / 2, -1, 2, "wheel, left edge")
  PtAdd(MemPaneX + MemPaneW - m, MemPaneY + MemPaneH / 2, -1, 2, "wheel, right edge")
  PtAdd(MemPaneX + MemPaneW / 2, MemPaneY + Neon_S(70), -1, 2, "wheel, top rows")
  PtAdd(MemPaneX + MemPaneW / 2, MemPaneY + MemPaneH - m, -1, 2, "wheel, bottom edge")
  If FindMapElement(PtCtl(), "controls")
    PtAdd(PtCtl()\x + PtCtl()\w - m, PtCtl()\y + PtCtl()\h - m, 0, 1, "press controls (opens)", "controls1")
    PtAdd(PtCtl()\x + m, PtCtl()\y + m, 0, 1, "press controls (closes)", "controls0")
  EndIf
  PtLog + "scale " + StrF(Neon_UIScale, 3) + "  logical " + Str(Util_WinWidth) + "x" + Str(Util_WinHeight) + "  physical " +
          Str(PhysW) + "x" + Str(PhysH) + "  UI_UseCRT " + Str(UI_UseCRT) + "  controls " + Str(Neon_HotPrevCount) + #LF$
EndProcedure

Procedure.i PtExpect(e.s, before.s, after.s)
  Select e
    Case "pause" : ProcedureReturn Bool(FindString(before, "running=1") And FindString(after, "running=0"))
    Case "step"  : ProcedureReturn Bool(StringField(StringField(after, 2, " "), 2, "=") <> StringField(StringField(before, 2, " "), 2, "="))
    Case "frame" : ProcedureReturn Bool(StringField(StringField(after, 3, " "), 2, "=") <> StringField(StringField(before, 3, " "), 2, "="))
    Case "reset" : ProcedureReturn Bool(FindString(after, " pc=0 ") And FindString(before, " pc=0 ") = 0)
    Case "focus" : ProcedureReturn Bool(FindString(after, "focus=302"))
    Case "clear" : ProcedureReturn Bool(FindString(before, "break=12") And Right(after, 6) = "break=")
    Case "coin"  : ProcedureReturn Bool(Val("$" + StringField(StringField(after, 5, " "), 2, "=")) & $20)
    Case "1p"    : ProcedureReturn Bool(Val("$" + StringField(StringField(after, 5, " "), 2, "=")) & $100)
  EndSelect
  If Left(e, 3) = "tab" : ProcedureReturn Bool(FindString(after, "tab=" + Mid(e, 4) + " ")) : EndIf
  If e = "controls1" : ProcedureReturn Bool(FindString(before, "controls=0") And FindString(after, "controls=1")) : EndIf
  If e = "controls0" : ProcedureReturn Bool(FindString(before, "controls=1") And FindString(after, "controls=0")) : EndIf
  ProcedureReturn 0
EndProcedure

; Called after each window pass has drawn: judges the pass, then sets the pointer for the next one.
Procedure PtStep()
  Protected err.f, found.i, ok.i, line.s, scrolled.i
  PtPass + 1
  If PtPass < 30 : ProcedureReturn : EndIf            ; let the window settle
  If PtPass = 30 : PtBuild() : FirstElement(PtSteps()) : PtPhase = 0 : ProcedureReturn : EndIf
  If PtDone Or ListIndex(PtSteps()) < 0 : ProcedureReturn : EndIf
  Select PtPhase
    Case 0                                            ; put the pointer there (and, for a press, the button down)
      If PtSteps()\expect = "clear" : BreakText\s = "12" : Neon_FocusID = 0 : EndIf
      PtBefore = PtState() : PtMemTop = MemTop
      PtX = PtSteps()\x : PtY = PtSteps()\y : PtDown = Bool(PtSteps()\kind = 1) : PtWheel = 0
      If PtSteps()\kind = 2 : PtWheel = -1 : EndIf
      PtPhase = 1 : ProcedureReturn
    Case 1
      If PtSteps()\kind = 1 : PtDown = 0 : PtPhase = 2 : ProcedureReturn : EndIf   ; release on the next pass
  EndSelect
  ; the pass with the pointer there has been drawn: judge it
  PtPoints + 1
  err = Abs(Neon_MX - PtX) : If Abs(Neon_MY - PtY) > err : err = Abs(Neon_MY - PtY) : EndIf
  If err > PtWorst : PtWorst = err : EndIf
  Select PtSteps()\kind
    Case 0 : found = Neon_HoverIdAt(Neon_MX, Neon_MY) : ok = Bool(found = PtSteps()\id And err <= 0.5)
    Case 1 : ok = Bool(err <= 0.5 And PtExpect(PtSteps()\expect, PtBefore, PtState()))
    Case 2 : scrolled = MemTop : ok = Bool(err <= 0.5 And scrolled > PtMemTop) : MemTop = 0
  EndSelect
  line = RSet(Str(PtSteps()\id), 15) + " " + LSet(PtSteps()\what, 27) + " at " + StrF(PtX, 1) + "," + StrF(PtY, 1) +
         "  read back " + StrF(Neon_MX, 1) + "," + StrF(Neon_MY, 1)
  If PtSteps()\kind = 0 : line + "  found " + Str(found) : EndIf
  If PtSteps()\kind = 1 : line + "  " + PtSteps()\expect + ": " + PtBefore + "  ->  " + PtState() : EndIf
  If PtSteps()\kind = 2 : line + "  memory top row " + Str(PtMemTop) + " -> " + Str(scrolled) : EndIf
  If ok : line = "PASS " + line : Else : line = "FAIL " + line : PtFails + 1 : EndIf
  PtLog + line + #LF$
  PtX = -100 : PtY = -100 : PtDown = 0 : PtWheel = 0 : PtPhase = 0
  If NextElement(PtSteps()) = 0
    PtDone = 1
    PtLog + "pointer-test: " + Str(PtPoints) + " points, " + Str(PtFails) + " failures, scale " + StrF(Neon_UIScale, 3) +
            ", worst pointer read-back error " + StrF(PtWorst, 2) + " px" + #LF$
  EndIf
EndProcedure

Procedure.i PtFinished()
  ProcedureReturn PtDone
EndProcedure

Procedure WindowRun(folder.s)
  Protected ev.i, quit.i, frames.i, ok.i, nowUs.q, paceStart.q, paceFrames.q, i.i
  ExamineDesktops()
  Gl = OpenGLWindow("Ms. Pac-Man - PureMetal desktop (" + EmuCoreName() + ")", 1280, 820,
                    #PB_Window_SystemMenu | #PB_Window_ScreenCentered | #PB_Window_MinimizeGadget | #PB_Window_MaximizeGadget | #PB_Window_SizeGadget)
  If Gl = 0 : MessageRequester("Ms. Pac-Man", "Could not open an OpenGL window.") : ProcedureReturn : EndIf
  Win = Util_MainWindowID
  CtlInit()
  ; the engine bends the mouse for its CRT curvature unless told otherwise (UI_UseCRT defaults to #True);
  ; this window draws flat, so a bent mouse missed the right-hand ends of controls by up to 10 px
  UI_UseCRT = #False
  CompilerIf Defined(PLANT_CRT, #PB_Constant)
    UI_UseCRT = #True                           ; only to see --pointer-test fail
  CompilerEndIf
  UiScale = MeasuredScale() : BuildFonts()
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
                CtlKey(KeyCode)                        ; the controls table
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
    If PtOn
      PtStep()
      If PtFinished() : quit = 1 : EndIf
    EndIf
    If FsOn
      FsStep()
      If FsDone() : quit = 1 : EndIf
    EndIf
  Until quit
  SoundClose()
  If FullOn : LeaveFull() : EndIf
  If PtOn Or FsOn                                 ; the tests: the log, and the failures as the exit code
    Protected f.i
    If PtOn : f = CreateFile(#PB_Any, PtFile) : If f : WriteString(f, PtLog) : CloseFile(f) : EndIf : EndIf
    If FsOn : f = CreateFile(#PB_Any, FsFile) : If f : WriteString(f, FsLog) : CloseFile(f) : EndIf : EndIf
    End PtFails + FsFails
  EndIf
EndProcedure

; ---------------------------------------------------------------------------
; A crash is written down, not lost: build with /LINENUMBERING to get the source line too.
Procedure CrashReport()
  Protected f.i = CreateFile(#PB_Any, GetTemporaryDirectory() + "MsPacman-crash.txt")
  If f
    WriteStringN(f, "error: " + ErrorMessage() + " (code " + Str(ErrorCode()) + ") at address $" + Hex(ErrorAddress()))
    WriteStringN(f, "line " + Str(ErrorLine()) + " of " + ErrorFile())
    CloseFile(f)
  EndIf
EndProcedure
OnErrorCall(@CrashReport())

Define folder.s, i.i, logFrames.i, dump.s
For i = 0 To CountProgramParameters() - 1
  Select LCase(ProgramParameter(i))
    Case "--log" : i + 1 : logFrames = Val(ProgramParameter(i))
    Case "--dump" : i + 1 : dump = ProgramParameter(i)
    Case "--test-picture" : EmuTestPicture = 1
    Case "--press" : i + 1 : EmuPress = ProgramParameter(i)
    Case "--mute" : SndMuted = 1
    Case "--wav" : i + 1 : WavOpen(ProgramParameter(i))
    Case "--poke" : i + 1 : EmuPoke = ProgramParameter(i)
    Case "--pointer-test" : i + 1 : PtFile = ProgramParameter(i) : PtOn = 1 : SndMuted = 1
    Case "--fullscreen-test" : i + 1 : FsFile = ProgramParameter(i) : FsOn = 1
    Case "--sndtrace" : i + 1 : SndTraceFile = CreateFile(#PB_Any, ProgramParameter(i))
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
