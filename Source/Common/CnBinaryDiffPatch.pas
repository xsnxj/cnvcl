{******************************************************************************}
{                       CnPack For Delphi/C++Builder                           }
{                     中国人自己的开放源码第三方开发包                         }
{                   (C)Copyright 2001-2016 CnPack 开发组                       }
{                   ------------------------------------                       }
{                                                                              }
{            本开发包是开源的自由软件，您可以遵照 CnPack 的发布协议来修        }
{        改和重新发布这一程序。                                                }
{                                                                              }
{            发布这一开发包的目的是希望它有用，但没有任何担保。甚至没有        }
{        适合特定目的而隐含的担保。更详细的情况请参阅 CnPack 发布协议。        }
{                                                                              }
{            您应该已经和开发包一起收到一份 CnPack 发布协议的副本。如果        }
{        还没有，可访问我们的网站：                                            }
{                                                                              }
{            网站地址：http://www.cnpack.org                                   }
{            电子邮件：master@cnpack.org                                       }
{                                                                              }
{******************************************************************************}

{******************************************************************************}
{        该单元大部分内容基于Stefan Reuther的BDiff / BPatch C 代码翻译而来。   }
{        下面是BDiff / BPatch的声明:                                           }
{ -----------------------------------------------------------------------------}
{(c) copyright 1999 by Stefan Reuther <Streu@gmx.de>. Copying this program is  }
{allowed, as long as you include source code and document changes you made in a}
{user-visible way so people know they're using your version, not mine.         }
{This program is distributed in the hope that it will be useful, but without   }
{warranties of any kind, be they explicit or implicit.                         }
{ -----------------------------------------------------------------------------}

unit CnBinaryDiffPatch;
{* |<PRE>
================================================================================
* 软件名称：开发包基础库
* 单元名称：简易的二进制差分以及补丁算法单元
* 单元作者：刘啸（liuxiao@cnpack.org）
* 备    注：该单元是简易的二进制差分以及补丁算法实现。
*           大部分基于Stefan Reuther的BDiff / BPatch C 代码翻译而来。
* 开发平台：PWin7 + Delphi 5.0
* 兼容测试：暂未进行
* 本 地 化：该单元无需本地化处理
* 修改记录：2016.08.05 V1.0
*               创建单元，实现 Diff 功能
================================================================================
|</PRE>}

interface

{$I CnPack.inc}

uses
  SysUtils, Classes, Windows;

const
  CN_BINARY_DIFF_NAME: AnsiString = 'CnBDiff';
  CN_BINARY_DIFF_VER: AnsiString = '1';

function BinaryDiffStream(OldStream, NewStream, PatchStream: TMemoryStream): Boolean;
{* 二进制差分比较新旧内存块（流），差分结果放入 PatchStream 中}

function BinaryPatchStream(OldStream, PatchStream, NewStream: TMemoryStream): Boolean;
{* 二进制差分补丁旧内存块（流），合成结果放入 NewStream 中}

function BinaryDiffFile(const OldFile, NewFile, PatchFile: string): Boolean;
{* 二进制差分比较新旧文件，差分结果存入 PatchFile 中}

function BinaryPatchFile(const OldFile, PatchFile, NewFile: string): Boolean;
{* 二进制差分补丁旧文件，合成结果存入 NewFile 中}

implementation

const
  CN_MIN_LENGTH = 24;
  CRLF: AnsiString = #13#10;

type
  TCardinalArray = array[0..65535] of Cardinal;
  PCardinalArray = ^TCardinalArray;

  TCnMatchRec = packed record
    OldPos: Cardinal;
    NewPos: Cardinal;
    Len: Cardinal;
  end;
  PCnMatchRec = ^TCnMatchRec;

  TCnDiffOutputType = (dotBinary, dotFiltered, dotQuoted);

var
  CnDiffOutputType: TCnDiffOutputType = dotFiltered;

function BlockSortCompare(BytePosA, BytePosB: Cardinal; Data: PByte; DataLen: Cardinal): Integer;
var
  Pa, Pb: PShortInt;
  Len: Cardinal;
begin
  Pa := PShortInt(Cardinal(Data) + BytePosA);
  Pb := PShortInt(Cardinal(Data) + BytePosB);
  Len := DataLen - BytePosA;
  if DataLen - BytePosB < Len then
    Len := DataLen - BytePosB;

  while (Len <> 0) and (Pa^ = Pb^) do
  begin
    Inc(Pa);
    Inc(Pb);
    Dec(Len);
  end;

  if Len = 0 then
    Result := BytePosA - BytePosB
  else
    Result := Pa^ - Pb^;
end;

procedure BlockSortSink(LeftPos, RightPos: Cardinal; Block: PInteger;
  Data: PByte; DataLen: Cardinal);
var
  I, J, X: Cardinal;
  BlockIntArray: PCardinalArray;
begin
  I := LeftPos;
  BlockIntArray := PCardinalArray(Block);
  X := BlockIntArray^[I];
  while True do
  begin
    J := 2 * I + 1;
    if J >= RightPos then
      Break;
    if J < RightPos - 1 then
      if BlockSortCompare(BlockIntArray^[J], BlockIntArray^[J + 1], Data, DataLen) < 0 then
        Inc(J);
    if BlockSortCompare(X, BlockIntArray^[J], Data, DataLen) > 0 then
      Break;

    BlockIntArray^[I] := BlockIntArray^[J];
    I := J;
  end;
  BlockIntArray^[I] := X;
end;

function BlockSort(Data: PByte; DataLen: Cardinal): PInteger;
var
  Block: PInteger;
  I, X, LeftPos, RightPos: Cardinal;
  BlockIntArray: PCardinalArray;
begin
  Result := nil;
  if DataLen <= 0 then
    Exit;

  Block := PInteger(GetMemory(SizeOf(Cardinal) * DataLen));
  if Block = nil then
    Exit;

  BlockIntArray := PCardinalArray(Block);
  for I := 0 to DataLen - 1 do
    BlockIntArray^[I] := I;

  LeftPos := DataLen div 2;
  RightPos := DataLen;

  while LeftPos > 0 do
  begin
    Dec(LeftPos);
    BlockSortSink(LeftPos, RightPos, Block, Data, DataLen);
  end;

  while RightPos > 0 do
  begin
    X := BlockIntArray^[LeftPos];
    BlockIntArray^[LeftPos] := BlockIntArray^[RightPos - 1];
    BlockIntArray^[RightPos - 1] := X;
    Dec(RightPos);
    BlockSortSink(LeftPos, RightPos, Block, Data, DataLen);
  end;
  Result := Block;
end;

function FindString(Data: PByte; Block: PInteger; DataLen: Cardinal; Sub: PByte;
  MaxLen: Cardinal; var Index: Cardinal): Cardinal;
var
  First, Last, Mid, FoundSize, L: Cardinal;
  Pm, Sm: PShortInt;
  BlockIntArray: PCardinalArray;
begin
  First := 0;
  Last := DataLen - 1;
  Result := 0;
  Index := 0;

  BlockIntArray := PCardinalArray(Block);
  while First <= Last do
  begin
    Mid := (First + Last) div 2;
    Pm := PShortInt(Cardinal(Data) + BlockIntArray^[Mid]);
    Sm := PShortInt(Sub);

    L := DataLen - BlockIntArray^[Mid];
    if L > MaxLen then
      L := MaxLen;

    FoundSize := 0;
    while (FoundSize < L) and (Pm^ = Sm^) do
    begin
      Inc(FoundSize);
      Inc(Pm);
      Inc(Sm);
    end;

    if FoundSize > Result then
    begin
      Result := FoundSize;
      Index := BlockIntArray^[Mid];
    end;

    if (FoundSize = L) or (Pm^ < Sm^) then
      First := Mid + 1
    else
    begin
      Last := Mid;
      if Last <> 0 then
        Dec(Last)
      else
        Break;
    end;
  end;
end;

procedure PackLong(P: PByte; L: DWORD);
begin
  P^ := L and $FF;
  Inc(P);
  P^ := (L shr 8) and $FF;
  Inc(P);
  P^ := (L shr 16) and $FF;
  Inc(P);
  P^ := (L shr 24) and $FF;
end;

function GetLong(P: PByte): DWORD;
begin
  Result := P^;
  Inc(P);
  Result := Result + 256 * P^;
  Inc(P);
  Result := Result + 65536 * P^;
  Inc(P);
  Result := Result + 16777216 * P^;
end;

function CheckSum(Data: PByte; DataLen: Cardinal): DWORD;
begin
  Result := 0;
  while DataLen > 0 do
  begin
    Result := ((Result shr 30) and 3) or (Result shl 2);
    Result := Result xor Data^;

    Dec(DataLen);
    Inc(Data);
  end;
end;

procedure BsFindMaxMatch(Ret: PCnMatchRec; Data: PByte; Sort: PInteger; Len: Cardinal;
  Text: PByte; TextLen: Cardinal);
var
  FoundPos, FoundLen: Cardinal;
begin
  Ret^.Len := 0;
  Ret^.NewPos := 0;
  while TextLen <> 0 do
  begin
    FoundLen := FindString(Data, Sort, Len, Text, TextLen, FoundPos);
    if FoundLen >= CN_MIN_LENGTH then
    begin
      Ret^.OldPos := FoundPos;
      Ret^.Len := FoundLen;
      Exit;
    end;
    Inc(Text);
    Dec(TextLen);
    Inc(Ret^.NewPos);
  end;
end;

procedure WriteHeader(OutStream: TStream; OldSize, NewSize: Cardinal);
var
  Buf: array[0..7] of Byte;
  S: AnsiString;
begin
  if OutStream <> nil then
  begin
    case CnDiffOutputType of
      dotBinary:
        begin
          OutStream.Write(CN_BINARY_DIFF_NAME[1], Length(CN_BINARY_DIFF_NAME));
          OutStream.Write(CN_BINARY_DIFF_VER[1], Length(CN_BINARY_DIFF_VER));
          PackLong(@Buf[0], OldSize);
          PackLong(@Buf[4], NewSize);
          OutStream.Write(Buf[0], SizeOf(Buf));
        end;
      dotFiltered, dotQuoted:
        begin
          S := Format('%% --- Old (%d bytes)' + #13#10 + '%% +++ New (%d bytes)' + #13#10, [OldSize, NewSize]);
          OutStream.Write(S[1], Length(S));
        end;
    end;
  end;
end;

function IsPrintableChar(AChar: Byte): Boolean;
begin
  Result := AChar in [32..127];
end;

procedure WriteFilteredOrQuotedData(OutStream: TStream; Data: PByte;
  DataLen: Cardinal; IsFiltered: Boolean);
const
  DOT_CHAR: AnsiChar = '.';
var
  S: AnsiString;
begin
  if IsFiltered then
  begin
    while DataLen > 0 do
    begin
      if IsPrintableChar(Data^) and (Chr(Data^) <> '\') then
        OutStream.Write(Data^, 1)
      else
      begin
        S := Format('#$%2.2x', [Data^]);
        OutStream.Write(S[1], Length(S));
      end;

      Inc(Data);
      Dec(DataLen);
    end;
  end
  else
  begin
    while DataLen > 0 do
    begin
      if IsPrintableChar(Data^) then
        OutStream.Write(Data^, 1)
      else
        OutStream.Write(DOT_CHAR, 1);
      Inc(Data);
      Dec(DataLen);
    end;
  end;
end;

procedure WriteAddContent(OutStream: TStream; Data: PByte; DataLen: Cardinal);
const
  ADD_CHAR: AnsiChar = '+';
var
  Buf: array[0..3] of Byte;
begin
  if OutStream <> nil then
  begin
    if CnDiffOutputType = dotBinary then
    begin
      OutStream.Write(ADD_CHAR, 1);
      PackLong(@Buf[0], DataLen);
      OutStream.Write(Buf[0], SizeOf(Buf));
      OutStream.Write(Data^, DataLen);
    end
    else
    begin
      OutStream.Write(ADD_CHAR, 1);
      WriteFilteredOrQuotedData(OutStream, Data, DataLen, CnDiffOutputType = dotFiltered);
      OutStream.Write(CRLF[1], Length(CRLF));
    end;
  end;
end;

procedure WriteCopyContent(OutStream: TStream; NewBase: PByte; NewPos: Cardinal;
  OldBase: PByte; OldPos: Cardinal; DataLen: Cardinal);
const
  COPY_CHAR: AnsiChar = '@';
var
  Buf: array[0..11] of Byte;
  S: AnsiString;
begin
  if OutStream <> nil then
  begin
    if CnDiffOutputType = dotBinary then
    begin
      OutStream.Write(COPY_CHAR, 1);
      PackLong(@Buf[0], OldPos);
      PackLong(@Buf[4], DataLen);
      PackLong(@Buf[8], CheckSum(PByte(Cardinal(NewBase) + NewPos), DataLen));
      OutStream.Write(Buf[0], SizeOf(Buf));
    end
    else
    begin
      S := Format('@ -[%d] => +[%d] %d bytes' + #13#10, [OldPos, NewPos, DataLen]);
      OutStream.Write(S[1], Length(S));
      WriteFilteredOrQuotedData(OutStream, PByte(Cardinal(NewBase) + NewPos), DataLen,
        CnDiffOutputType = dotFiltered);
      OutStream.Write(CRLF[1], Length(CRLF));
    end;
  end;
end;

// 二进制差分比较新旧内存块（流），差分结果放入 PatchStream 中
function BinaryDiffStream(OldStream, NewStream, PatchStream: TMemoryStream): Boolean;
var
  Sort: PInteger;
  Todo, Nofs: Cardinal;
  Match: TCnMatchRec;
begin
  Result := False;
  if (OldStream = nil) or (NewStream = nil) or (PatchStream = nil) then
    Exit;

  Sort := BlockSort(OldStream.Memory, OldStream.Size);
  if Sort = nil then
    Exit;

  WriteHeader(PatchStream, OldStream.Size, NewStream.Size);

  Todo := NewStream.Size;
  Nofs := 0;
  while Todo > 0 do
  begin
    BsFindMaxMatch(@Match, OldStream.Memory, Sort, OldStream.Size,
      PByte(Cardinal(NewStream.Memory) + Nofs), Todo);

    if Match.Len <> 0 then
    begin
      WriteAddContent(PatchStream, PByte(Cardinal(NewStream.Memory) + Nofs), Match.NewPos);

      Inc(Nofs, Match.NewPos);
      Dec(Todo, Match.NewPos);

      WriteCopyContent(PatchStream, NewStream.Memory, Nofs, OldStream.Memory, Match.OldPos, Match.Len);

      Inc(Nofs, Match.Len);
      Dec(Todo, Match.Len);
    end
    else
    begin
      WriteAddContent(PatchStream, PByte(Cardinal(NewStream.Memory) + Nofs), Todo);
      Break;
    end;
  end;
  FreeMemory(Sort);
  Result := True;
end;

// 二进制差分补丁旧内存块（流），合成结果放入 NewStream 中
function BinaryPatchStream(OldStream, PatchStream, NewStream: TMemoryStream): Boolean;
begin

end;

// 二进制差分比较新旧文件，差分结果存入 PatchFile 中
function BinaryDiffFile(const OldFile, NewFile, PatchFile: string): Boolean;
var
  OldStream, NewStream, PatchStream: TMemoryStream;
begin
  OldStream := nil;
  NewStream := nil;
  PatchStream := nil;

  try
    OldStream := TMemoryStream.Create;
    OldStream.LoadFromFile(OldFile);
    NewStream := TMemoryStream.Create;
    NewStream.LoadFromFile(NewFile);

    PatchStream := TMemoryStream.Create;
    Result := BinaryDiffStream(OldStream, NewStream, PatchStream);
    PatchStream.SaveToFile(PatchFile);
  finally
    PatchStream.Free;
    NewStream.Free;
    OldStream.Free;
  end;
end;

// 二进制差分补丁旧文件，合成结果存入 NewFile 中
function BinaryPatchFile(const OldFile, PatchFile, NewFile: string): Boolean;
var
  OldStream, NewStream, PatchStream: TMemoryStream;
begin
  OldStream := nil;
  PatchStream := nil;
  NewStream := nil;

  try
    OldStream := TMemoryStream.Create;
    OldStream.LoadFromFile(OldFile);
    PatchStream := TMemoryStream.Create;
    PatchStream.LoadFromFile(PatchFile);

    NewStream := TMemoryStream.Create;
    Result := BinaryPatchStream(OldStream, PatchStream, NewStream);
    NewStream.SaveToFile(NewFile);
  finally
    NewStream.Free;
    PatchStream.Free;
    OldStream.Free;
  end;
end;

end.
