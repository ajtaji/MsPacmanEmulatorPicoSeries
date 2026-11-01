; Namco WSG (three voices) for the desktop, the same as rp2040/wsg.pico: the chip steps at 96 kHz
; (counter += frequency, waveform position = counter bits 15..19); two steps make one 48 kHz
; sample. A voice with volume 0 does not advance; with sound disabled (latch bit 1) nothing does.
; Registers (WsgRegs, $5040-$505F low nibbles): 05/0A/0F waveforms, 10..14 voice 0 frequency,
; 15 volume, 16..19 voice 1 frequency (bits 4-19), 1A volume, 1B..1E voice 2, 1F volume.
;
; Output: the sound card through the Neon Arcade engine (GL_AudioOpen / GL_AudioNext / GL_AudioPlay:
; waveOut on Windows, ALSA on Linux), 48 kHz 16-bit, the mono sample in both channels, 12 buffers of
; one frame (792 pairs).

EnableExplicit

#WSG_GAIN = 32
#SND_BUFFERS = 12

Global Dim WsgWave.w(255)
Global Dim WsgCounter.l(2)
Global Dim SndFrame.w(#MSP_FRAME_SAMPLES - 1)
Global SndOpen.i, SndUnderruns.i, SndQueued.i, SndMuted.i

Procedure WsgBegin(*prom)
  Protected i.i
  For i = 0 To 255 : WsgWave(i) = (PeekA(*prom + i) & 15) - 8 : Next
  For i = 0 To 2 : WsgCounter(i) = 0 : Next
EndProcedure

Procedure WsgVoice(wave.i, freq.i, vol.i, ch.i)
  Protected i.i, s.i, c.l = WsgCounter(ch)
  For i = 0 To #MSP_FRAME_SAMPLES - 1
    s = WsgWave(wave + ((c >> 15) & 31)) : c + freq
    s + WsgWave(wave + ((c >> 15) & 31)) : c + freq
    SndFrame(i) + s * vol * #WSG_GAIN
  Next
  WsgCounter(ch) = c
EndProcedure

; One frame's samples (792) into SndFrame, from the registers as they stand.
Procedure WsgRender()
  Protected i.i, f.i, v.i
  For i = 0 To #MSP_FRAME_SAMPLES - 1 : SndFrame(i) = 0 : Next
  If (MspLatch & 2) = 0 : ProcedureReturn : EndIf
  v = WsgRegs($15)
  If v
    f = WsgRegs($10) | (WsgRegs($11) << 4) | (WsgRegs($12) << 8) | (WsgRegs($13) << 12) | (WsgRegs($14) << 16)
    WsgVoice((WsgRegs($05) & 7) * 32, f, v, 0)
  EndIf
  v = WsgRegs($1A)
  If v
    f = (WsgRegs($16) << 4) | (WsgRegs($17) << 8) | (WsgRegs($18) << 12) | (WsgRegs($19) << 16)
    WsgVoice((WsgRegs($0A) & 7) * 32, f, v, 1)
  EndIf
  v = WsgRegs($1F)
  If v
    f = (WsgRegs($1B) << 4) | (WsgRegs($1C) << 8) | (WsgRegs($1D) << 12) | (WsgRegs($1E) << 16)
    WsgVoice((WsgRegs($0F) & 7) * 32, f, v, 2)
  EndIf
EndProcedure

Procedure.i SoundOpen()
  If GL_AudioOpen(48000, #MSP_FRAME_SAMPLES, #SND_BUFFERS) = #False : ProcedureReturn 0 : EndIf
  SndOpen = 1 : SndQueued = 0
  ProcedureReturn 1
EndProcedure

; One buffer to the card: the frame's samples, or silence. 0 when every buffer is still queued.
Procedure.i SoundSend(silent.i)
  Protected i.i, v.w, *dst = GL_AudioNext()
  If *dst = 0 : ProcedureReturn 0 : EndIf
  For i = 0 To #MSP_FRAME_SAMPLES - 1
    If SndMuted Or silent : v = 0 : Else : v = SndFrame(i) : EndIf
    PokeW(*dst + i * 4, v) : PokeW(*dst + i * 4 + 2, v)
  Next
  GL_AudioPlay(*dst)
  SndQueued + 1
  ProcedureReturn 1
EndProcedure

; Queue this frame's samples. The frames are made at the real-time rate, so the queue holds
; what it started with: it starts with #SND_CUSHION frames of silence, and when it has run dry
; (an underrun - a pass came late; the engine's GL_AudioQueued says 0) the cushion is put back
; the same way.
#SND_CUSHION = 5
Procedure.i SoundQueue()
  Protected k.i
  If SndOpen = 0 : ProcedureReturn 0 : EndIf
  If GL_AudioQueued() = 0
    If SndQueued > 0 : SndUnderruns + 1 : EndIf
    For k = 1 To #SND_CUSHION : SoundSend(1) : Next
  EndIf
  ProcedureReturn SoundSend(0)
EndProcedure

Procedure SoundClose()
  If SndOpen = 0 : ProcedureReturn : EndIf
  GL_AudioClose()
  SndOpen = 0
EndProcedure
