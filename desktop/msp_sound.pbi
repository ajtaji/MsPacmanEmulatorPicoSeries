; Namco WSG (three voices) for the desktop, the same as rp2040/wsg.pico: the chip steps at 96 kHz
; (counter += frequency, waveform position = counter bits 15..19); two steps make one 48 kHz
; sample. A voice with volume 0 does not advance; with sound disabled (latch bit 1) nothing does.
; Registers (WsgRegs, $5040-$505F low nibbles): 05/0A/0F waveforms, 10..14 voice 0 frequency,
; 15 volume, 16..19 voice 1 frequency (bits 4-19), 1A volume, 1B..1E voice 2, 1F volume.
;
; Output: Windows waveOut, 48 kHz mono 16-bit, a ring of buffers of one frame (792 samples) each.

EnableExplicit

#WSG_GAIN = 32
#SND_BUFFERS = 8

Global Dim WsgWave.w(255)
Global Dim WsgCounter.l(2)
Global Dim SndFrame.w(#MSP_FRAME_SAMPLES - 1)
Global SndDevice.i, SndOpen.i, SndNext.i, SndUnderruns.i, SndQueued.i, SndMuted.i
Global Dim SndHeader.WAVEHDR(#SND_BUFFERS - 1)
Global Dim *SndBuffer(#SND_BUFFERS - 1)

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
  Protected fmt.WAVEFORMATEX, i.i
  fmt\wFormatTag = #WAVE_FORMAT_PCM : fmt\nChannels = 1 : fmt\nSamplesPerSec = 48000
  fmt\wBitsPerSample = 16 : fmt\nBlockAlign = 2 : fmt\nAvgBytesPerSec = 96000 : fmt\cbSize = 0
  If waveOutOpen_(@SndDevice, #WAVE_MAPPER, @fmt, 0, 0, #CALLBACK_NULL) <> #MMSYSERR_NOERROR
    ProcedureReturn 0
  EndIf
  For i = 0 To #SND_BUFFERS - 1
    *SndBuffer(i) = AllocateMemory(#MSP_FRAME_SAMPLES * 2)
    SndHeader(i)\lpData = *SndBuffer(i)
    SndHeader(i)\dwBufferLength = #MSP_FRAME_SAMPLES * 2
    SndHeader(i)\dwFlags = 0
    waveOutPrepareHeader_(SndDevice, @SndHeader(i), SizeOf(WAVEHDR))
    SndHeader(i)\dwFlags | #WHDR_DONE           ; free to fill
  Next
  SndOpen = 1
  ProcedureReturn 1
EndProcedure

; Buffers the device still holds (0 means the next one plays late: an underrun).
Procedure.i SoundPending()
  Protected i.i, n.i
  For i = 0 To #SND_BUFFERS - 1
    If (SndHeader(i)\dwFlags & #WHDR_DONE) = 0 : n + 1 : EndIf
  Next
  ProcedureReturn n
EndProcedure

; Queue this frame's samples. Returns 0 when every buffer is still playing (frame dropped).
Procedure.i SoundQueue()
  Protected i.i = SndNext
  If SndOpen = 0 : ProcedureReturn 0 : EndIf
  If (SndHeader(i)\dwFlags & #WHDR_DONE) = 0 : ProcedureReturn 0 : EndIf
  If SoundPending() = 0 And SndQueued > 0 : SndUnderruns + 1 : EndIf
  If SndMuted
    FillMemory(*SndBuffer(i), #MSP_FRAME_SAMPLES * 2, 0)
  Else
    CopyMemory(@SndFrame(0), *SndBuffer(i), #MSP_FRAME_SAMPLES * 2)
  EndIf
  SndHeader(i)\dwFlags & ~#WHDR_DONE
  waveOutWrite_(SndDevice, @SndHeader(i), SizeOf(WAVEHDR))
  SndNext = (i + 1) % #SND_BUFFERS : SndQueued + 1
  ProcedureReturn 1
EndProcedure

Procedure SoundClose()
  Protected i.i
  If SndOpen = 0 : ProcedureReturn : EndIf
  waveOutReset_(SndDevice)
  For i = 0 To #SND_BUFFERS - 1
    waveOutUnprepareHeader_(SndDevice, @SndHeader(i), SizeOf(WAVEHDR))
    FreeMemory(*SndBuffer(i))
  Next
  waveOutClose_(SndDevice)
  SndOpen = 0
EndProcedure
