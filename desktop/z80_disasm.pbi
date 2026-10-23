; Z80 disassembler for the debug pane: one instruction at an address of Z80Mem, every documented
; and undocumented opcode (CB, ED, DD/FD with IXH/IXL/IYH/IYL, DDCB/FDCB). Decoded by the opcode's
; fields x = bits 7-6, y = 5-3, z = 2-0, p = y >> 1, q = y & 1 (the decomposition Zilog's own
; tables follow). Z80Disasm(addr, @length) returns the text and sets the length in bytes.

EnableExplicit

Procedure.i DisByte(a.i)
  ProcedureReturn Z80Mem(a & $FFFF)
EndProcedure

Procedure.s DisHex2(v.i)
  ProcedureReturn "$" + RSet(Hex(v & $FF), 2, "0")
EndProcedure
Procedure.s DisHex4(v.i)
  ProcedureReturn "$" + RSet(Hex(v & $FFFF), 4, "0")
EndProcedure

Procedure.s DisR(i.i, idx.s, disp.s)
  ; B C D E H L (HL) A, with H/L/(HL) replaced under a DD/FD prefix
  Select i
    Case 0 : ProcedureReturn "B"
    Case 1 : ProcedureReturn "C"
    Case 2 : ProcedureReturn "D"
    Case 3 : ProcedureReturn "E"
    Case 4 : If idx <> "" : ProcedureReturn idx + "H" : EndIf : ProcedureReturn "H"
    Case 5 : If idx <> "" : ProcedureReturn idx + "L" : EndIf : ProcedureReturn "L"
    Case 6 : If idx <> "" : ProcedureReturn "(" + idx + disp + ")" : EndIf : ProcedureReturn "(HL)"
  EndSelect
  ProcedureReturn "A"
EndProcedure

Procedure.s DisRP(p.i, idx.s)
  Select p
    Case 0 : ProcedureReturn "BC"
    Case 1 : ProcedureReturn "DE"
    Case 2 : If idx <> "" : ProcedureReturn idx : EndIf : ProcedureReturn "HL"
  EndSelect
  ProcedureReturn "SP"
EndProcedure

Procedure.s DisRP2(p.i, idx.s)
  If p = 3 : ProcedureReturn "AF" : EndIf
  ProcedureReturn DisRP(p, idx)
EndProcedure

Procedure.s DisCC(y.i)
  ProcedureReturn StringField("NZ,Z,NC,C,PO,PE,P,M", y + 1, ",")
EndProcedure

Procedure.s DisAlu(y.i)
  ProcedureReturn StringField("ADD A,|ADC A,|SUB |SBC A,|AND |XOR |OR |CP ", y + 1, "|")
EndProcedure

Procedure.s DisRot(y.i)
  ProcedureReturn StringField("RLC,RRC,RL,RR,SLA,SRA,SLL,SRL", y + 1, ",")
EndProcedure

Procedure.s DisDisp(d.i)
  If d >= 128 : ProcedureReturn "-" + DisHex2(256 - d) : EndIf
  ProcedureReturn "+" + DisHex2(d)
EndProcedure

Procedure.s Z80Disasm(addr.i, *len.Integer)
  Protected a.i = addr, op.i, x.i, y.i, z.i, p.i, q.i, idx.s = "", disp.s = "", d.i, n.i, nn.i, t.s, r.s
  op = DisByte(a) : a + 1
  If op = $DD Or op = $FD
    If op = $DD : idx = "IX" : Else : idx = "IY" : EndIf
    op = DisByte(a) : a + 1
    If op = $DD Or op = $FD Or op = $ED
      *len\i = 1 : ProcedureReturn "NOP*  (" + idx + " prefix ignored)"
    EndIf
    If op = $CB
      ; DDCB d op
      d = DisByte(a) : op = DisByte(a + 1) : a + 2
      x = op >> 6 : y = (op >> 3) & 7 : z = op & 7
      disp = DisDisp(d)
      Select x
        Case 0 : t = DisRot(y) + " (" + idx + disp + ")"
        Case 1 : t = "BIT " + Str(y) + ",(" + idx + disp + ")"
        Case 2 : t = "RES " + Str(y) + ",(" + idx + disp + ")"
        Default : t = "SET " + Str(y) + ",(" + idx + disp + ")"
      EndSelect
      If x <> 1 And z <> 6 : t + "," + DisR(z, "", "") : EndIf
      *len\i = a - addr : ProcedureReturn t
    EndIf
  EndIf
  x = op >> 6 : y = (op >> 3) & 7 : z = op & 7 : p = y >> 1 : q = y & 1
  ; an indexed (HL) operand takes a displacement byte (not for JP (IX), EX (SP),IX, LD SP,IX)
  If idx <> ""
    If (x = 1 And (y = 6 Or z = 6) And op <> $76) Or (x = 2 And z = 6) Or (x = 0 And (z = 4 Or z = 5 Or z = 6) And y = 6)
      d = DisByte(a) : a + 1 : disp = DisDisp(d)
    EndIf
  EndIf
  If op = $CB
    op = DisByte(a) : a + 1
    x = op >> 6 : y = (op >> 3) & 7 : z = op & 7
    Select x
      Case 0 : t = DisRot(y) + " " + DisR(z, "", "")
      Case 1 : t = "BIT " + Str(y) + "," + DisR(z, "", "")
      Case 2 : t = "RES " + Str(y) + "," + DisR(z, "", "")
      Default : t = "SET " + Str(y) + "," + DisR(z, "", "")
    EndSelect
    *len\i = a - addr : ProcedureReturn t
  EndIf
  If op = $ED And idx = ""
    op = DisByte(a) : a + 1
    x = op >> 6 : y = (op >> 3) & 7 : z = op & 7 : p = y >> 1 : q = y & 1
    t = "NOP*"
    If x = 1
      Select z
        Case 0 : If y = 6 : t = "IN (C)" : Else : t = "IN " + DisR(y, "", "") + ",(C)" : EndIf
        Case 1 : If y = 6 : t = "OUT (C),0" : Else : t = "OUT (C)," + DisR(y, "", "") : EndIf
        Case 2 : If q = 0 : t = "SBC HL," + DisRP(p, "") : Else : t = "ADC HL," + DisRP(p, "") : EndIf
        Case 3
          nn = DisByte(a) | (DisByte(a + 1) << 8) : a + 2
          If q = 0 : t = "LD (" + DisHex4(nn) + ")," + DisRP(p, "") : Else : t = "LD " + DisRP(p, "") + ",(" + DisHex4(nn) + ")" : EndIf
        Case 4 : t = "NEG"
        Case 5 : If y = 1 : t = "RETI" : Else : t = "RETN" : EndIf
        Case 6 : t = "IM " + StringField("0,0/1,1,2,0,0/1,1,2", y + 1, ",")
        Case 7 : t = StringField("LD I,A|LD R,A|LD A,I|LD A,R|RRD|RLD|NOP*|NOP*", y + 1, "|")
      EndSelect
    ElseIf x = 2 And z <= 3 And y >= 4
      t = StringField("LDI,CPI,INI,OUTI,LDD,CPD,IND,OUTD,LDIR,CPIR,INIR,OTIR,LDDR,CPDR,INDR,OTDR", (y - 4) * 4 + z + 1, ",")
    EndIf
    *len\i = a - addr : ProcedureReturn t
  EndIf
  Select x
    Case 0
      Select z
        Case 0
          Select y
            Case 0 : t = "NOP"
            Case 1 : t = "EX AF,AF'"
            Case 2, 3, 4, 5, 6, 7
              d = DisByte(a) : a + 1
              nn = (a + (d ! 128) - 128) & $FFFF
              If y = 2 : t = "DJNZ " + DisHex4(nn)
              ElseIf y = 3 : t = "JR " + DisHex4(nn)
              Else : t = "JR " + DisCC(y - 4) + "," + DisHex4(nn)
              EndIf
          EndSelect
        Case 1
          If q = 0
            nn = DisByte(a) | (DisByte(a + 1) << 8) : a + 2
            t = "LD " + DisRP(p, idx) + "," + DisHex4(nn)
          Else
            If idx <> "" : r = idx : Else : r = "HL" : EndIf
            t = "ADD " + r + "," + DisRP(p, idx)
          EndIf
        Case 2
          If idx <> "" : r = idx : Else : r = "HL" : EndIf
          Select y
            Case 0 : t = "LD (BC),A"
            Case 1 : t = "LD A,(BC)"
            Case 2 : t = "LD (DE),A"
            Case 3 : t = "LD A,(DE)"
            Default
              nn = DisByte(a) | (DisByte(a + 1) << 8) : a + 2
              Select y
                Case 4 : t = "LD (" + DisHex4(nn) + ")," + r
                Case 5 : t = "LD " + r + ",(" + DisHex4(nn) + ")"
                Case 6 : t = "LD (" + DisHex4(nn) + "),A"
                Default : t = "LD A,(" + DisHex4(nn) + ")"
              EndSelect
          EndSelect
        Case 3 : If q = 0 : t = "INC " + DisRP(p, idx) : Else : t = "DEC " + DisRP(p, idx) : EndIf
        Case 4 : t = "INC " + DisR(y, idx, disp)
        Case 5 : t = "DEC " + DisR(y, idx, disp)
        Case 6
          n = DisByte(a) : a + 1
          t = "LD " + DisR(y, idx, disp) + "," + DisHex2(n)
        Case 7 : t = StringField("RLCA,RRCA,RLA,RRA,DAA,CPL,SCF,CCF", y + 1, ",")
      EndSelect
    Case 1
      If op = $76
        t = "HALT"
      ElseIf y = 6 Or z = 6
        ; with (IX+d) the other operand is the plain register (LD H,(IX+d), LD (IX+d),L)
        If y = 6 : t = "LD " + DisR(6, idx, disp) + "," + DisR(z, "", "") : Else : t = "LD " + DisR(y, "", "") + "," + DisR(6, idx, disp) : EndIf
      Else
        t = "LD " + DisR(y, idx, disp) + "," + DisR(z, idx, disp)
      EndIf
    Case 2
      t = DisAlu(y) + DisR(z, idx, disp)
    Default
      Select z
        Case 0 : t = "RET " + DisCC(y)
        Case 1
          If q = 0
            t = "POP " + DisRP2(p, idx)
          Else
            Select p
              Case 0 : t = "RET"
              Case 1 : t = "EXX"
              Case 2 : If idx <> "" : t = "JP (" + idx + ")" : Else : t = "JP (HL)" : EndIf
              Default : If idx <> "" : t = "LD SP," + idx : Else : t = "LD SP,HL" : EndIf
            EndSelect
          EndIf
        Case 2
          nn = DisByte(a) | (DisByte(a + 1) << 8) : a + 2
          t = "JP " + DisCC(y) + "," + DisHex4(nn)
        Case 3
          Select y
            Case 0 : nn = DisByte(a) | (DisByte(a + 1) << 8) : a + 2 : t = "JP " + DisHex4(nn)
            Case 2 : n = DisByte(a) : a + 1 : t = "OUT (" + DisHex2(n) + "),A"
            Case 3 : n = DisByte(a) : a + 1 : t = "IN A,(" + DisHex2(n) + ")"
            Case 4 : If idx <> "" : t = "EX (SP)," + idx : Else : t = "EX (SP),HL" : EndIf
            Case 5 : t = "EX DE,HL"
            Case 6 : t = "DI"
            Case 7 : t = "EI"
          EndSelect
        Case 4
          nn = DisByte(a) | (DisByte(a + 1) << 8) : a + 2
          t = "CALL " + DisCC(y) + "," + DisHex4(nn)
        Case 5
          If q = 0
            t = "PUSH " + DisRP2(p, idx)
          ElseIf p = 0
            nn = DisByte(a) | (DisByte(a + 1) << 8) : a + 2 : t = "CALL " + DisHex4(nn)
          EndIf
        Case 6
          n = DisByte(a) : a + 1
          t = DisAlu(y) + DisHex2(n)
        Case 7 : t = "RST " + DisHex2(y * 8)
      EndSelect
  EndSelect
  *len\i = a - addr
  ProcedureReturn t
EndProcedure
