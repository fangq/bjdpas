unit bjdata;

{==============================================================================

  bjdata.pas - a self-contained Binary JData (BJData) parser and writer
               for Object Pascal (Free Pascal / Lazarus / Delphi-compatible)

  BJData is a quasi-human-readable binary JSON format derived from UBJSON
  (Draft 12) with added support for N-dimensional packed arrays, unsigned
  and half-precision numeric types, a native byte type, structure-of-arrays
  (SoA) containers and binary extension types.

    Specification: https://neurojson.org/bjdata/draft4
    Project page:  https://github.com/NeuroJSON/bjdata

  Copyright (c) 2026  Qianqian Fang <q.fang at neu.edu>
  Licensed under the Apache License, Version 2.0

  Everything is implemented by a single class, TBJData, which serves as an
  in-memory document tree (DOM) as well as the entry point for parsing and
  serialization:

    doc := TBJData.ParseFile('input.bjd');
    WriteLn(doc.ToJSON(2));
    doc.Values['newkey'] := TBJData.NewInt(42);
    doc.SaveToFile('output.bjd');
    doc.Free;

==============================================================================}

{$mode objfpc}{$H+}
{$INLINE ON}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}

interface

uses
  Classes, SysUtils, Math;

const
  BJDataVersion = '0.5.0';

  {---- BJData type markers (Draft 4) ----}
  bjmNull       = 'Z';   // null
  bjmNoOp       = 'N';   // no-op, skipped while decoding
  bjmTrue       = 'T';   // boolean true
  bjmFalse      = 'F';   // boolean false
  bjmInt8       = 'i';   // int8
  bjmUInt8      = 'U';   // uint8
  bjmInt16      = 'I';   // int16
  bjmUInt16     = 'u';   // uint16  (BJData extension)
  bjmInt32      = 'l';   // int32
  bjmUInt32     = 'm';   // uint32  (BJData extension)
  bjmInt64      = 'L';   // int64
  bjmUInt64     = 'M';   // uint64  (BJData extension)
  bjmFloat16    = 'h';   // float16/half (BJData extension)
  bjmFloat32    = 'd';   // float32/single
  bjmFloat64    = 'D';   // float64/double
  bjmHighPrec   = 'H';   // high-precision number, stored as a string
  bjmChar       = 'C';   // single ASCII char
  bjmByte       = 'B';   // raw byte (BJData extension)
  bjmString     = 'S';   // UTF-8 string
  bjmExtension  = 'E';   // binary extension (BJData extension)
  bjmArrayStart = '[';
  bjmArrayEnd   = ']';
  bjmObjectStart= '{';
  bjmObjectEnd  = '}';
  bjmTypeMark   = '$';   // optimized container type
  bjmCountMark  = '#';   // optimized container count

  {---- reserved extension type IDs (0-255) ----}
  bjxReserved     = 0;
  bjxEpochSec     = 1;   // uint32 seconds since epoch
  bjxEpochUSec    = 2;   // int64 microseconds since epoch
  bjxEpochNSec    = 3;   // int64 seconds + uint32 nanoseconds
  bjxDate         = 4;   // int16 year + uint8 month + uint8 day
  bjxTimeSec      = 5;   // uint8 hour/minute/second + pad
  bjxDateTimeUSec = 6;   // int64 microseconds since epoch
  bjxTimeDeltaUSec= 7;   // int64 microseconds duration
  bjxComplex64    = 8;   // 2 x float32
  bjxComplex128   = 9;   // 2 x float64
  bjxUUID         = 10;  // 16-byte RFC-4122 UUID (big-endian)

type
  EBJData = class(Exception);

  { node types of the document tree }
  TBJDataKind = (
    bjkNull,        // Z
    bjkNoOp,        // N (only present when bjpKeepNoOp is used)
    bjkBoolean,     // T / F
    bjkInt,         // i I l L, and B / signed interpretation
    bjkUInt,        // U u m M (values that do not fit in Int64)
    bjkFloat,       // h d D
    bjkString,      // S, C (single char) and H (high-precision number)
    bjkArray,       // [ ... ]
    bjkObject,      // { ... }
    bjkTypedArray,  // [$type#[dims] packed N-dimensional numeric array
    bjkExtension    // E
  );

  TBJDataParseOption = (
    bjpKeepNoOp,          // keep 'N' markers as bjkNoOp nodes instead of skipping
    bjpExpandTypedArray,  // decode [$type#count] into a plain array of scalars
    bjpSoAAsColumns       // decode a '{$' SoA record as an object of arrays
  );                      // (default: always an array of objects)
  TBJDataParseOptions = set of TBJDataParseOption;

  TBJDataWriteOption = (
    bjwCount,      // write the optimized '#' count for arrays and objects
    bjwType,       // write the optimized '$' type for uniform arrays
    bjwSoA,        // write uniform arrays of objects as SoA records
    bjwColumnMajor // prefer column-major layout for N-d arrays and SoA
  );
  TBJDataWriteOptions = set of TBJDataWriteOption;

const
  BJDefaultParseOptions: TBJDataParseOptions = [];
  BJDefaultWriteOptions: TBJDataWriteOptions = [bjwCount, bjwType];

type
  TBJData = class;

  TBJDataItems = array of TBJData;
  TBJDataNames = array of string;
  TBJDataDims  = array of Int64;

  { TBJValue - a read-only view of one value inside a buffer.

    Navigating a document through TBJValue allocates nothing: every call
    decodes straight from the bytes, strings and packed payloads can be read
    without copying them, and a subtree becomes a TBJData tree only when
    ToData is called. The buffer must stay alive and unchanged for as long as
    any view of it is used. }

  TBJValue = record
  private
    FPos: PByte;          // the marker of this value, or its payload when
    FEnd: PByte;          // FImplied is set (elements of a typed container
    FImplied: AnsiChar;   // carry no marker of their own)
    function PayloadPtr: PByte; inline;
    function ContainerBody(out AElem: AnsiChar; out ACount: Int64): PByte;
  public
    class function Create(ABuffer: PByte; ASize: PtrUInt): TBJValue; static;
    class function FromBytes(const ABuffer: TBytes): TBJValue; static;

    function IsValid: Boolean; inline;
    function Kind: TBJDataKind;
    function Marker: AnsiChar; inline;
    function IsNull: Boolean;
    function IsNumber: Boolean;
    function IsContainer: Boolean;
    function IsPacked: Boolean;
    function IsSoA: Boolean;

    {---- scalars ----}
    function AsInt64: Int64;
    function AsQWord: QWord;
    function AsDouble: Double;
    function AsBoolean: Boolean;
    function AsString: string;
    function TextPtr: PAnsiChar;
    function TextLength: SizeInt;
    function TextEquals(const AText: string): Boolean;

    {---- containers ----}
    function Count: SizeInt;
    function Item(AIndex: SizeInt): TBJValue;
    function Find(const AKey: string): TBJValue;
    function FindKey(AKey: PAnsiChar; ALength: SizeInt): TBJValue;
    function Path(const APath: string): TBJValue;

    {---- packed arrays ----}
    function ElemMarker: AnsiChar;
    function ElementCount: Int64;
    function DimCount: Integer;
    function Dim(AIndex: Integer): Int64;
    function ColumnMajor: Boolean;
    function DataPtr: Pointer;
    function DataSize: PtrUInt;
    function ElemAsInt64(AIndex: Int64): Int64;
    function ElemAsDouble(AIndex: Int64): Double;

    {---- the value as a whole ----}
    function Size: PtrUInt;
    function ToData(AOptions: TBJDataParseOptions = []): TBJData;
    function ToJSON(AIndent: Integer = 0): string;
  end;

  { TBJIterator - walks the children of an array or an object; obtained from
    TBJValue.GetEnumerator, so a container can be used with for..in }

  TBJIterator = record
  private
    FNext: PByte;
    FEnd: PByte;
    FLeft: Int64;         // remaining children, -1 until an end marker
    FElem: AnsiChar;      // element type of an optimized container
    FIsObject: Boolean;
    FCurrent: TBJValue;
    FKeyPtr: PByte;
    FKeyLen: SizeInt;
  public
    function MoveNext: Boolean;
    function Key: string;
    function KeyPtr: PAnsiChar;
    function KeyLength: SizeInt;
    function KeyEquals(const AKey: string): Boolean;
    property Current: TBJValue read FCurrent;
  end;

  TBJValueEnumerator = record helper for TBJValue
  public
    function GetEnumerator: TBJIterator;
  end;

  { TBJData }

  TBJData = class(TObject)
  private
    FKind: TBJDataKind;
    FMarker: AnsiChar;
    FInt: Int64;            // integer/unsigned/boolean payload
    FFloat: Double;         // floating-point payload
    FStr: string;           // string/char/high-precision payload
    FBin: TBytes;           // packed array payload or extension payload
    FDims: TBJDataDims;     // dimensions of a packed array or SoA record
    FColumnMajor: Boolean;  // packed payload is in column-major order
    FFromSoA: Boolean;      // array/object was decoded from an SoA record
    FItems: TBJDataItems;   // child nodes (array and object)
    FNames: TBJDataNames;   // child names (object only)
    FCount: SizeInt;        // number of child nodes in use
    function GetItem(AIndex: SizeInt): TBJData;
    procedure SetItem(AIndex: SizeInt; AValue: TBJData);
    function GetName(AIndex: SizeInt): string;
    procedure SetName(AIndex: SizeInt; const AValue: string);
    function GetValue(const AKey: string): TBJData;
    procedure SetValue(const AKey: string; AValue: TBJData);
    function GetAsInt64: Int64;
    function GetAsQWord: QWord;
    function GetAsDouble: Double;
    function GetAsString: string;
    function GetAsBoolean: Boolean;
    function GetDim(AIndex: SizeInt): Int64;
    function GetDimCount: SizeInt;
    procedure NeedKind(AKind: TBJDataKind; const AWhat: string);
    procedure NeedContainer;
    procedure InsertSlot(AIndex: SizeInt);
    procedure Grow;
    { unchecked append, used by the decoder: the caller guarantees that the
      node is a container of the matching flavour }
    function AppendChild(AValue: TBJData): TBJData; overload; inline;
    function AppendChild(const AKey: string; AValue: TBJData): TBJData; overload; inline;
    function AppendSlot: SizeInt; inline;
  public
    constructor Create(AKind: TBJDataKind = bjkNull);
    destructor Destroy; override;
    procedure FreeInstance; override;

    {---- constructors for each value type ----}
    { allocate a bare node without running a constructor: a constructor of a
      class with managed fields carries an implicit exception frame, which is
      measurable when a document has millions of nodes }
    class function NewFast(AKind: TBJDataKind; AMarker: AnsiChar): TBJData; inline;
    class function NewNull: TBJData;
    class function NewNoOp: TBJData;
    class function NewBool(AValue: Boolean): TBJData;
    class function NewInt(AValue: Int64): TBJData; overload;
    class function NewInt(AValue: Int64; AMarker: AnsiChar): TBJData; overload;
    class function NewUInt(AValue: QWord): TBJData;
    class function NewFloat(AValue: Double): TBJData; overload;
    class function NewFloat(AValue: Double; AMarker: AnsiChar): TBJData; overload;
    class function NewString(const AValue: string): TBJData;
    class function NewChar(AValue: AnsiChar): TBJData;
    class function NewHighPrec(const AValue: string): TBJData;
    class function NewArray: TBJData;
    class function NewObject: TBJData;
    class function NewTypedArray(AMarker: AnsiChar; const ADims: array of Int64): TBJData;
    class function NewBytes(const AValue: TBytes): TBJData;
    class function NewExtension(ATypeId: Int64; const APayload: TBytes): TBJData;
    class function NewComplex(ARe, AIm: Double; ASingle: Boolean = False): TBJData;
    class function NewUUID(const AValue: string): TBJData;
    class function NewDateTime(AValue: TDateTime): TBJData;

    {---- lazy access: creating a view costs nothing ----}
    class function View(const ABuffer: TBytes): TBJValue;

    {---- parsing ----}
    class function Parse(const ABuffer; ALength: PtrUInt;
      AOptions: TBJDataParseOptions = []): TBJData;
    class function ParseBytes(const ABuffer: TBytes;
      AOptions: TBJDataParseOptions = []): TBJData;
    class function ParseStream(AStream: TStream;
      AOptions: TBJDataParseOptions = []): TBJData;
    class function ParseFile(const AFileName: string;
      AOptions: TBJDataParseOptions = []): TBJData;

    {---- serialization ----}
    procedure SaveToStream(AStream: TStream;
      AOptions: TBJDataWriteOptions = [bjwCount, bjwType]);
    procedure SaveToFile(const AFileName: string;
      AOptions: TBJDataWriteOptions = [bjwCount, bjwType]);
    function ToBytes(AOptions: TBJDataWriteOptions = [bjwCount, bjwType]): TBytes;
    function ToJSON(AIndent: Integer = 0): string;

    {---- container access ----}
    function IndexOfName(const AKey: string): SizeInt;
    function Has(const AKey: string): Boolean;
    function Add(AValue: TBJData): TBJData; overload;
    function Add(const AKey: string; AValue: TBJData): TBJData; overload;
    function AddNull: TBJData;
    function Insert(AIndex: SizeInt; AValue: TBJData): TBJData;
    function Extract(AIndex: SizeInt): TBJData;
    procedure Delete(AIndex: SizeInt);
    procedure Remove(const AKey: string);
    procedure Clear;
    procedure Reserve(ACapacity: SizeInt);
    function Clone: TBJData;
    function Path(const APath: string): TBJData;

    {---- packed array access ----}
    function ElementCount: Int64;
    function ElemAsDouble(AIndex: Int64): Double;
    function ElemAsInt64(AIndex: Int64): Int64;
    procedure SetElem(AIndex: Int64; const AValue: Double); overload;
    procedure SetElem(AIndex: Int64; const AValue: Int64); overload;
    procedure SetDims(const ADims: array of Int64);
    function ExpandTypedArray: TBJData;
    function AsBytes: TBytes;

    {---- extension helpers ----}
    function ExtTypeId: Int64;
    function ExtPayload: TBytes;
    function AsComplex(out ARe, AIm: Double): Boolean;
    function AsUUIDString: string;
    function AsDateTime: TDateTime;

    {---- state ----}
    function IsNull: Boolean;
    function IsContainer: Boolean;
    function IsNumber: Boolean;
    function IsHighPrec: Boolean;

    property Kind: TBJDataKind read FKind;
    property Marker: AnsiChar read FMarker write FMarker;
    property Count: SizeInt read FCount;
    property Items[AIndex: SizeInt]: TBJData read GetItem write SetItem; default;
    property Names[AIndex: SizeInt]: string read GetName write SetName;
    property Values[const AKey: string]: TBJData read GetValue write SetValue;
    property AsInt64: Int64 read GetAsInt64;
    property AsQWord: QWord read GetAsQWord;
    property AsDouble: Double read GetAsDouble;
    property AsString: string read GetAsString;
    property AsBoolean: Boolean read GetAsBoolean;
    property DimCount: SizeInt read GetDimCount;
    property Dim[AIndex: SizeInt]: Int64 read GetDim;
    property ColumnMajor: Boolean read FColumnMajor write FColumnMajor;
    property FromSoA: Boolean read FFromSoA write FFromSoA;
  end;

{---- marker helpers, exposed for applications that inspect raw markers ----}
function BJMarkerSize(AMarker: AnsiChar): Integer;
function BJIsIntMarker(AMarker: AnsiChar): Boolean;
function BJIsFloatMarker(AMarker: AnsiChar): Boolean;
function BJIsFixedMarker(AMarker: AnsiChar): Boolean;
function BJIsUnsignedMarker(AMarker: AnsiChar): Boolean;
function BJPlainText(const AValue: string): Boolean;
function BJIntMarkerFor(AValue: Int64): AnsiChar;
function BJUIntMarkerFor(AValue: QWord): AnsiChar;
function BJHalfToDouble(AValue: Word): Double;
function BJDoubleToHalf(AValue: Double): Word;
function BJKindName(AKind: TBJDataKind): string;
function BJKindOf(AMarker: AnsiChar): TBJDataKind;
{ the position just past the value starting at APos; raises on malformed input }
function BJSkipValue(APos, AEnd: PByte): PByte;
function BJFloatToStr(AValue: Double): string;
function BJJSONEscape(const AValue: string): string;

implementation

var
  BJFormat: TFormatSettings;

const
  BJUnixEpoch = 25569.0;    { TDateTime value of 1970-01-01 }

{==============================================================================
  marker and numeric helpers
==============================================================================}

function BJMarkerSize(AMarker: AnsiChar): Integer;
begin
  case AMarker of
    bjmInt8, bjmUInt8, bjmByte, bjmChar:
      Result := 1;
    bjmInt16, bjmUInt16, bjmFloat16:
      Result := 2;
    bjmInt32, bjmUInt32, bjmFloat32:
      Result := 4;
    bjmInt64, bjmUInt64, bjmFloat64:
      Result := 8;
  else
    Result := 0;
  end;
end;

function BJIsIntMarker(AMarker: AnsiChar): Boolean;
begin
  Result := AMarker in [bjmInt8, bjmUInt8, bjmInt16, bjmUInt16,
                        bjmInt32, bjmUInt32, bjmInt64, bjmUInt64];
end;

function BJIsFloatMarker(AMarker: AnsiChar): Boolean;
begin
  Result := AMarker in [bjmFloat16, bjmFloat32, bjmFloat64];
end;

function BJIsFixedMarker(AMarker: AnsiChar): Boolean;
begin
  Result := BJMarkerSize(AMarker) > 0;
end;

function BJIsUnsignedMarker(AMarker: AnsiChar): Boolean;
begin
  Result := AMarker in [bjmUInt8, bjmUInt16, bjmUInt32, bjmUInt64,
                        bjmByte, bjmChar];
end;

function BJIntMarkerFor(AValue: Int64): AnsiChar;
begin
  if (AValue >= 0) and (AValue <= 255) then
    if AValue <= 127 then
      Result := bjmInt8
    else
      Result := bjmUInt8
  else if (AValue >= -128) and (AValue < 0) then
    Result := bjmInt8
  else if (AValue >= -32768) and (AValue <= 32767) then
    Result := bjmInt16
  else if (AValue >= 0) and (AValue <= 65535) then
    Result := bjmUInt16
  else if (AValue >= -2147483648) and (AValue <= 2147483647) then
    Result := bjmInt32
  else if (AValue >= 0) and (AValue <= 4294967295) then
    Result := bjmUInt32
  else
    Result := bjmInt64;
end;

function BJUIntMarkerFor(AValue: QWord): AnsiChar;
begin
  if AValue <= 127 then
    Result := bjmInt8
  else if AValue <= 255 then
    Result := bjmUInt8
  else if AValue <= 32767 then
    Result := bjmInt16
  else if AValue <= 65535 then
    Result := bjmUInt16
  else if AValue <= 2147483647 then
    Result := bjmInt32
  else if AValue <= 4294967295 then
    Result := bjmUInt32
  else if AValue <= QWord(High(Int64)) then
    Result := bjmInt64
  else
    Result := bjmUInt64;
end;

{ reverse the byte order of ACount elements of AElemSize bytes; the BJData
  payload is always little-endian, so this is a no-op on little-endian hosts }
procedure BJFromLE(APtr: PByte; AElemSize: Integer; ACount: PtrUInt);
{$IFDEF ENDIAN_BIG}
var
  i, j: Integer;
  n: PtrUInt;
  t: Byte;
begin
  if AElemSize < 2 then
    Exit;
  for n := 0 to ACount - 1 do
  begin
    i := 0;
    j := AElemSize - 1;
    while i < j do
    begin
      t := APtr[i];
      APtr[i] := APtr[j];
      APtr[j] := t;
      Inc(i);
      Dec(j);
    end;
    Inc(APtr, AElemSize);
  end;
end;
{$ELSE}
begin
end;
{$ENDIF}

function BJHalfToDouble(AValue: Word): Double;
var
  s: Integer;
  e: Integer;
  f: LongWord;
begin
  s := (AValue shr 15) and 1;
  e := (AValue shr 10) and $1F;
  f := AValue and $3FF;
  if e = 0 then
  begin
    if f = 0 then
      Result := 0.0
    else
      Result := f * 5.9604644775390625e-8;      { 2^-24 }
  end
  else if e = 31 then
  begin
    if f = 0 then
      Result := Infinity
    else
      Result := NaN;
  end
  else
    Result := (1.0 + f / 1024.0) * Power(2.0, e - 15);
  if (s = 1) and not IsNan(Result) then
    Result := -Result;
end;

function BJDoubleToHalf(AValue: Double): Word;
var
  v: Single;
  u: LongWord;
  sign: Word;
  e: Integer;
  mant, rest: LongWord;
  shift: Integer;
begin
  v := AValue;
  u := PLongWord(@v)^;
  sign := Word((u shr 16) and $8000);
  e := Integer((u shr 23) and $FF);
  mant := u and $7FFFFF;
  if e = 255 then                                { Inf or NaN }
  begin
    if mant = 0 then
      Result := sign or $7C00
    else
      Result := sign or $7E00;
    Exit;
  end;
  e := e - 127 + 15;
  if e >= 31 then                                { overflow to infinity }
  begin
    Result := sign or $7C00;
    Exit;
  end;
  if e <= 0 then                                 { subnormal or zero }
  begin
    if e < -10 then
    begin
      Result := sign;
      Exit;
    end;
    mant := mant or $800000;
    shift := 14 - e;
    Result := sign or Word(mant shr shift);
    rest := mant and ((LongWord(1) shl shift) - 1);
    if (rest > (LongWord(1) shl (shift - 1))) or
       ((rest = (LongWord(1) shl (shift - 1))) and ((Result and 1) <> 0)) then
      Inc(Result);
    Exit;
  end;
  Result := sign or Word((e shl 10) or (mant shr 13));
  rest := mant and $1FFF;
  if (rest > $1000) or ((rest = $1000) and ((Result and 1) <> 0)) then
    Inc(Result);
end;

function BJKindName(AKind: TBJDataKind): string;
begin
  case AKind of
    bjkNull:       Result := 'null';
    bjkNoOp:       Result := 'no-op';
    bjkBoolean:    Result := 'boolean';
    bjkInt:        Result := 'integer';
    bjkUInt:       Result := 'unsigned';
    bjkFloat:      Result := 'float';
    bjkString:     Result := 'string';
    bjkArray:      Result := 'array';
    bjkObject:     Result := 'object';
    bjkTypedArray: Result := 'packed array';
    bjkExtension:  Result := 'extension';
  else
    Result := 'unknown';
  end;
end;

{ format a floating-point number for JSON output; non-finite values use the
  JData notation ("_NaN_", "_Inf_", "-_Inf_") and include the quotes }
function BJFloatToStr(AValue: Double): string;
var
  p: Integer;
  back: Double;
begin
  if IsNan(AValue) then
    Result := '"_NaN_"'
  else if IsInfinite(AValue) then
  begin
    if AValue > 0 then
      Result := '"_Inf_"'
    else
      Result := '"-_Inf_"';
  end
  else
  begin
    Result := '';
    for p := 15 to 17 do
    begin
      Result := FloatToStrF(AValue, ffGeneral, p, 0, BJFormat);
      { the round-trip must be compared in double precision: StrToFloat
        returns an extended on platforms that have one }
      back := StrToFloatDef(Result, 0.0, BJFormat);
      if back = AValue then
        Break;
    end;
  end;
end;

{ True when the string contains a character that JSON has to escape; most
  strings do not, and can then be copied into the output in one piece }
function BJPlainText(const AValue: string): Boolean;
var
  i: Integer;
  c: AnsiChar;
begin
  for i := 1 to Length(AValue) do
  begin
    c := AValue[i];
    if (c < ' ') or (c = '"') or (c = '\') then
      Exit(False);
  end;
  Result := True;
end;

function BJJSONEscape(const AValue: string): string;
const
  HexDigits: array[0..15] of AnsiChar = '0123456789abcdef';
var
  i, n: Integer;
  c: AnsiChar;
begin
  if BJPlainText(AValue) then
    Exit(AValue);
  SetLength(Result, Length(AValue) * 2 + 8);
  n := 0;
  for i := 1 to Length(AValue) do
  begin
    if n + 8 > Length(Result) then
      SetLength(Result, Length(Result) * 2);
    c := AValue[i];
    case c of
      '"', '\':
        begin
          Result[n + 1] := '\';
          Result[n + 2] := c;
          Inc(n, 2);
        end;
      #8, #9, #10, #12, #13:
        begin
          Result[n + 1] := '\';
          case c of
            #8:  Result[n + 2] := 'b';
            #9:  Result[n + 2] := 't';
            #10: Result[n + 2] := 'n';
            #12: Result[n + 2] := 'f';
          else
            Result[n + 2] := 'r';
          end;
          Inc(n, 2);
        end;
    else
      if c < ' ' then
      begin
        Result[n + 1] := '\';
        Result[n + 2] := 'u';
        Result[n + 3] := '0';
        Result[n + 4] := '0';
        Result[n + 5] := HexDigits[Ord(c) shr 4];
        Result[n + 6] := HexDigits[Ord(c) and 15];
        Inc(n, 6);
      end
      else
      begin
        Result[n + 1] := c;
        Inc(n);
      end;
    end;
  end;
  SetLength(Result, n);
end;

function BJHexStr(const ABuf: TBytes): string;
var
  i: Integer;
begin
  SetLength(Result, Length(ABuf) * 2);
  for i := 0 to High(ABuf) do
  begin
    Result[i * 2 + 1] := LowerCase(IntToHex(ABuf[i], 2))[1];
    Result[i * 2 + 2] := LowerCase(IntToHex(ABuf[i], 2))[2];
  end;
end;

{==============================================================================
  Buffer walking - shared by the lazy views and by anything that needs to know
  how long an encoded value is without decoding it
==============================================================================}

function BJIndexMarkerFor(ACount: Int64): AnsiChar; forward;

function BJKindOf(AMarker: AnsiChar): TBJDataKind;
begin
  case AMarker of
    bjmNull:      Result := bjkNull;
    bjmNoOp:      Result := bjkNoOp;
    bjmTrue, bjmFalse:
                  Result := bjkBoolean;
    bjmUInt64:    Result := bjkUInt;
    bjmInt8, bjmUInt8, bjmInt16, bjmUInt16, bjmInt32, bjmUInt32, bjmInt64,
    bjmByte:      Result := bjkInt;
    bjmFloat16, bjmFloat32, bjmFloat64:
                  Result := bjkFloat;
    bjmString, bjmHighPrec, bjmChar:
                  Result := bjkString;
    bjmExtension: Result := bjkExtension;
    bjmArrayStart:Result := bjkArray;
    bjmObjectStart:Result := bjkObject;
  else
    raise EBJData.CreateFmt('unknown type marker "%s" (0x%.2x)',
      [AMarker, Ord(AMarker)]);
  end;
end;

procedure BJWalkError(const AMsg: string);
begin
  raise EBJData.Create(AMsg);
end;

procedure BJNeed(APos, AEnd: PByte; ACount: PtrUInt); inline;
begin
  if APos + ACount > AEnd then
    BJWalkError('unexpected end of input');
end;

{ read a value of the given fixed marker at APos and advance }
function BJWalkInt(var APos: PByte; AEnd: PByte; AMarker: AnsiChar): Int64;
var
  n: Integer;
  v16: Word;
  v32: LongWord;
  v64: Int64;
begin
  n := BJMarkerSize(AMarker);
  if n = 0 then
    BJWalkError(Format('"%s" is not a fixed-length numeric marker', [AMarker]));
  BJNeed(APos, AEnd, n);
  case n of
    1:
      if AMarker = bjmInt8 then
        Result := PShortInt(APos)^
      else
        Result := APos^;
    2:
      begin
        Move(APos^, v16, 2);
        BJFromLE(@v16, 2, 1);
        if AMarker = bjmInt16 then
          Result := SmallInt(v16)
        else
          Result := v16;
      end;
    4:
      begin
        Move(APos^, v32, 4);
        BJFromLE(@v32, 4, 1);
        if AMarker = bjmInt32 then
          Result := LongInt(v32)
        else
          Result := v32;
      end;
  else
    begin
      Move(APos^, v64, 8);
      BJFromLE(@v64, 8, 1);
      Result := v64;
    end;
  end;
  Inc(APos, n);
end;

{ read a marker plus a non-negative integer }
function BJWalkSize(var APos: PByte; AEnd: PByte): Int64;
var
  m: AnsiChar;
begin
  BJNeed(APos, AEnd, 1);
  m := AnsiChar(APos^);
  Inc(APos);
  if not BJIsIntMarker(m) then
    BJWalkError(Format('"%s" cannot be used as a length or count', [m]));
  Result := BJWalkInt(APos, AEnd, m);
  if Result < 0 then
    BJWalkError('a negative length or count is not allowed');
end;

{ skip an object key }
procedure BJWalkKey(var APos: PByte; AEnd: PByte);
var
  n: Int64;
begin
  n := BJWalkSize(APos, AEnd);
  BJNeed(APos, AEnd, n);
  Inc(APos, n);
end;

{ the dimension vector after a '#'; returns the element count and, when ADims
  is given, the individual dimensions }
function BJWalkCount(var APos: PByte; AEnd: PByte; ADims: TBJDataDims;
  out ANDim: Integer; out AColumnMajor: Boolean): Int64;
var
  m, et: AnsiChar;
  k, i, v: Int64;

  procedure Push(AValue: Int64);
  begin
    if (ADims <> nil) and (ANDim < Length(ADims)) then
      ADims[ANDim] := AValue;
    Inc(ANDim);
  end;

  function ReadVector: Int64;
  var
    i: Int64;
  begin
    Result := 1;
    BJNeed(APos, AEnd, 1);
    m := AnsiChar(APos^);
    if m = bjmArrayStart then                  // [[dims]] : column-major
    begin
      Inc(APos);
      AColumnMajor := True;
      Result := ReadVector;
      BJNeed(APos, AEnd, 1);
      if AnsiChar(APos^) = bjmArrayEnd then
        Inc(APos);
      Exit;
    end;
    if m = bjmCountMark then
    begin
      Inc(APos);
      k := BJWalkSize(APos, AEnd);
      BJNeed(APos, AEnd, 1);
      if AnsiChar(APos^) = bjmArrayStart then  // [#1 [dims] : column-major
      begin
        Inc(APos);
        AColumnMajor := True;
        Exit(ReadVector);
      end;
      for i := 1 to k do
      begin
        v := BJWalkSize(APos, AEnd);
        Push(v);
        Result := Result * v;
      end;
      Exit;
    end;
    if m = bjmTypeMark then                    // [$t#n dims...
    begin
      Inc(APos);
      BJNeed(APos, AEnd, 1);
      et := AnsiChar(APos^);
      Inc(APos);
      BJNeed(APos, AEnd, 1);
      if AnsiChar(APos^) <> bjmCountMark then
        BJWalkError('a dimension vector needs a count');
      Inc(APos);
      k := BJWalkSize(APos, AEnd);
      for i := 1 to k do
      begin
        v := BJWalkInt(APos, AEnd, et);
        Push(v);
        Result := Result * v;
      end;
      Exit;
    end;
    while True do                              // [dim dim ... ]
    begin
      BJNeed(APos, AEnd, 1);
      m := AnsiChar(APos^);
      if m = bjmArrayEnd then
      begin
        Inc(APos);
        Break;
      end;
      v := BJWalkSize(APos, AEnd);
      Push(v);
      Result := Result * v;
    end;
  end;

begin
  ANDim := 0;
  AColumnMajor := False;
  BJNeed(APos, AEnd, 1);
  m := AnsiChar(APos^);
  Inc(APos);
  if m = bjmArrayStart then
    Result := ReadVector
  else
  begin
    if not BJIsIntMarker(m) then
      BJWalkError(Format('"%s" cannot be used as a container count', [m]));
    Result := BJWalkInt(APos, AEnd, m);
    if Result < 0 then
      BJWalkError('a negative container count is not allowed');
    Push(Result);
  end;
end;

{ skip the payload of a value whose type is fixed by the container header }
procedure BJWalkTyped(var APos: PByte; AEnd: PByte; AMarker: AnsiChar);
var
  n: Int64;
begin
  case AMarker of
    bjmNull, bjmNoOp, bjmTrue, bjmFalse:
      ;
    bjmString, bjmHighPrec:
      begin
        n := BJWalkSize(APos, AEnd);
        BJNeed(APos, AEnd, n);
        Inc(APos, n);
      end;
  else
    n := BJMarkerSize(AMarker);
    if n = 0 then
      BJWalkError(Format('"%s" cannot be a container element type', [AMarker]));
    BJNeed(APos, AEnd, n);
    Inc(APos, n);
  end;
end;

{ measure one SoA schema field, adding its payload width to ASize and
  appending the index type of every offset column to AOffsets }
procedure BJWalkSchemaField(var APos: PByte; AEnd: PByte; var ASize: Int64;
  var AOffsets: string);
var
  m, t: AnsiChar;
  n, i: Int64;
begin
  BJNeed(APos, AEnd, 1);
  m := AnsiChar(APos^);
  Inc(APos);
  case m of
    bjmArrayStart:
      begin
        BJNeed(APos, AEnd, 1);
        if AnsiChar(APos^) = bjmTypeMark then
        begin
          Inc(APos);
          BJNeed(APos, AEnd, 1);
          t := AnsiChar(APos^);
          Inc(APos);
          if (t = bjmString) or (t = bjmHighPrec) then
          begin                                // dictionary column
            BJNeed(APos, AEnd, 1);
            if AnsiChar(APos^) <> bjmCountMark then
              BJWalkError('a dictionary column needs a count');
            Inc(APos);
            n := BJWalkSize(APos, AEnd);
            for i := 1 to n do
              BJWalkKey(APos, AEnd);
            ASize := ASize + BJMarkerSize(BJIndexMarkerFor(n));
          end
          else
          begin                                // offset table column
            if BJMarkerSize(t) = 0 then
              BJWalkError('an offset column needs an integer type');
            BJNeed(APos, AEnd, 1);
            if AnsiChar(APos^) <> bjmArrayEnd then
              BJWalkError('an offset column needs a closing bracket');
            Inc(APos);
            ASize := ASize + BJMarkerSize(t);
            AOffsets := AOffsets + t;
          end;
        end
        else
          while True do                        // fixed array column
          begin
            BJNeed(APos, AEnd, 1);
            if AnsiChar(APos^) = bjmArrayEnd then
            begin
              Inc(APos);
              Break;
            end;
            BJWalkSchemaField(APos, AEnd, ASize, AOffsets);
          end;
      end;
    bjmObjectStart:
      while True do                            // nested record
      begin
        BJNeed(APos, AEnd, 1);
        if AnsiChar(APos^) = bjmObjectEnd then
        begin
          Inc(APos);
          Break;
        end;
        BJWalkKey(APos, AEnd);
        BJWalkSchemaField(APos, AEnd, ASize, AOffsets);
      end;
    bjmString, bjmHighPrec:
      ASize := ASize + BJWalkSize(APos, AEnd);
    bjmTrue:
      ASize := ASize + 1;
    bjmNull:
      ;
  else
    if BJMarkerSize(m) = 0 then
      BJWalkError(Format('"%s" is not a valid SoA schema type', [m]));
    ASize := ASize + BJMarkerSize(m);
  end;
end;

// skip a structure-of-arrays record; APos is just past the schema opener
procedure BJWalkSoA(var APos: PByte; AEnd: PByte);
var
  recsize, count, n: Int64;
  offsets: string;
  ndim, i, k: Integer;
  colmajor: Boolean;
  last: Int64;
begin
  recsize := 0;
  offsets := '';
  while True do
  begin
    BJNeed(APos, AEnd, 1);
    if AnsiChar(APos^) = bjmObjectEnd then
    begin
      Inc(APos);
      Break;
    end;
    if AnsiChar(APos^) = bjmNoOp then
    begin
      Inc(APos);
      Continue;
    end;
    BJWalkKey(APos, AEnd);
    BJWalkSchemaField(APos, AEnd, recsize, offsets);
  end;
  BJNeed(APos, AEnd, 1);
  if AnsiChar(APos^) <> bjmCountMark then
    BJWalkError('an SoA record needs a count');
  Inc(APos);
  count := BJWalkCount(APos, AEnd, nil, ndim, colmajor);
  n := count * recsize;
  BJNeed(APos, AEnd, n);
  Inc(APos, n);
  { each offset column appends its own table and string buffer }
  for k := 1 to Length(offsets) do
  begin
    last := 0;
    for i := 0 to count do
      last := BJWalkInt(APos, AEnd, offsets[k]);
    BJNeed(APos, AEnd, last);
    Inc(APos, last);
  end;
end;

function BJSkipValue(APos, AEnd: PByte): PByte;
var
  m, et: AnsiChar;
  n, i, cnt: Int64;
  ndim: Integer;
  colmajor: Boolean;
begin
  BJNeed(APos, AEnd, 1);
  m := AnsiChar(APos^);
  Inc(APos);
  case m of
    bjmNull, bjmNoOp, bjmTrue, bjmFalse:
      ;
    bjmInt8, bjmUInt8, bjmInt16, bjmUInt16, bjmInt32, bjmUInt32, bjmInt64,
    bjmUInt64, bjmFloat16, bjmFloat32, bjmFloat64, bjmChar, bjmByte:
      begin
        n := BJMarkerSize(m);
        BJNeed(APos, AEnd, n);
        Inc(APos, n);
      end;
    bjmString, bjmHighPrec:
      begin
        n := BJWalkSize(APos, AEnd);
        BJNeed(APos, AEnd, n);
        Inc(APos, n);
      end;
    bjmExtension:
      begin
        BJWalkSize(APos, AEnd);
        n := BJWalkSize(APos, AEnd);
        BJNeed(APos, AEnd, n);
        Inc(APos, n);
      end;
    bjmArrayStart:
      begin
        BJNeed(APos, AEnd, 1);
        et := AnsiChar(APos^);
        if et = bjmTypeMark then
        begin
          Inc(APos);
          BJNeed(APos, AEnd, 1);
          et := AnsiChar(APos^);
          Inc(APos);
          if et = bjmObjectStart then
            BJWalkSoA(APos, AEnd)
          else
          begin
            BJNeed(APos, AEnd, 1);
            if AnsiChar(APos^) <> bjmCountMark then
              BJWalkError('a typed array needs a count');
            Inc(APos);
            cnt := BJWalkCount(APos, AEnd, nil, ndim, colmajor);
            if BJIsFixedMarker(et) then
            begin
              n := cnt * BJMarkerSize(et);
              BJNeed(APos, AEnd, n);
              Inc(APos, n);
            end
            else
              for i := 1 to cnt do
                BJWalkTyped(APos, AEnd, et);
          end;
        end
        else if et = bjmCountMark then
        begin
          Inc(APos);
          cnt := BJWalkCount(APos, AEnd, nil, ndim, colmajor);
          for i := 1 to cnt do
            APos := BJSkipValue(APos, AEnd);
        end
        else
          while True do
          begin
            BJNeed(APos, AEnd, 1);
            if AnsiChar(APos^) = bjmArrayEnd then
            begin
              Inc(APos);
              Break;
            end;
            APos := BJSkipValue(APos, AEnd);
          end;
      end;
    bjmObjectStart:
      begin
        BJNeed(APos, AEnd, 1);
        et := AnsiChar(APos^);
        if et = bjmTypeMark then
        begin
          Inc(APos);
          BJNeed(APos, AEnd, 1);
          et := AnsiChar(APos^);
          Inc(APos);
          if et = bjmObjectStart then
            BJWalkSoA(APos, AEnd)
          else
          begin
            BJNeed(APos, AEnd, 1);
            if AnsiChar(APos^) <> bjmCountMark then
              BJWalkError('a typed object needs a count');
            Inc(APos);
            cnt := BJWalkCount(APos, AEnd, nil, ndim, colmajor);
            for i := 1 to cnt do
            begin
              BJWalkKey(APos, AEnd);
              BJWalkTyped(APos, AEnd, et);
            end;
          end;
        end
        else if et = bjmCountMark then
        begin
          Inc(APos);
          cnt := BJWalkCount(APos, AEnd, nil, ndim, colmajor);
          for i := 1 to cnt do
          begin
            BJWalkKey(APos, AEnd);
            APos := BJSkipValue(APos, AEnd);
          end;
        end
        else
          while True do
          begin
            BJNeed(APos, AEnd, 1);
            if AnsiChar(APos^) = bjmObjectEnd then
            begin
              Inc(APos);
              Break;
            end;
            if AnsiChar(APos^) = bjmNoOp then
            begin
              Inc(APos);
              Continue;
            end;
            BJWalkKey(APos, AEnd);
            APos := BJSkipValue(APos, AEnd);
          end;
      end;
  else
    BJWalkError(Format('unknown type marker "%s" (0x%.2x)', [m, Ord(m)]));
  end;
  Result := APos;
end;

{==============================================================================
  TBJData - construction and destruction
==============================================================================}

constructor TBJData.Create(AKind: TBJDataKind);
begin
  inherited Create;
  FKind := AKind;
  case AKind of
    bjkNull:       FMarker := bjmNull;
    bjkNoOp:       FMarker := bjmNoOp;
    bjkBoolean:    FMarker := bjmFalse;
    bjkInt:        FMarker := bjmInt8;
    bjkUInt:       FMarker := bjmUInt64;
    bjkFloat:      FMarker := bjmFloat64;
    bjkString:     FMarker := bjmString;
    bjkArray:      FMarker := bjmArrayStart;
    bjkObject:     FMarker := bjmObjectStart;
    bjkTypedArray: FMarker := bjmUInt8;
    bjkExtension:  FMarker := bjmExtension;
  end;
end;

destructor TBJData.Destroy;
var
  i: SizeInt;
begin
  { the child arrays themselves are released by FreeInstance, so only the
    child nodes have to be walked here }
  for i := 0 to FCount - 1 do
    FItems[i].Free;
  FCount := 0;
  inherited Destroy;
end;

{ releasing a node is as hot as building one, and the default cleanup walks
  the field RTTI table of every instance. A node has five managed fields and
  most nodes use only one of them, so the walk is replaced by direct tests }
procedure TBJData.FreeInstance;
begin
  if ClassType = TBJData then
  begin
    if Pointer(FStr) <> nil then
      FStr := '';
    if Pointer(FItems) <> nil then
      FItems := nil;
    if Pointer(FNames) <> nil then
      FNames := nil;
    if Pointer(FBin) <> nil then
      FBin := nil;
    if Pointer(FDims) <> nil then
      FDims := nil;
    FreeMem(Pointer(Self));
  end
  else
    inherited FreeInstance;
end;

class function TBJData.NewFast(AKind: TBJDataKind; AMarker: AnsiChar): TBJData;
begin
  Result := TBJData(NewInstance);
  Result.FKind := AKind;
  Result.FMarker := AMarker;
end;

class function TBJData.NewNull: TBJData;
begin
  Result := TBJData.Create(bjkNull);
end;

class function TBJData.NewNoOp: TBJData;
begin
  Result := TBJData.Create(bjkNoOp);
end;

class function TBJData.NewBool(AValue: Boolean): TBJData;
begin
  Result := TBJData.Create(bjkBoolean);
  Result.FInt := Ord(AValue);
  if AValue then
    Result.FMarker := bjmTrue
  else
    Result.FMarker := bjmFalse;
end;

class function TBJData.NewInt(AValue: Int64): TBJData;
begin
  Result := NewInt(AValue, BJIntMarkerFor(AValue));
end;

class function TBJData.NewInt(AValue: Int64; AMarker: AnsiChar): TBJData;
begin
  if not (BJIsIntMarker(AMarker) or (AMarker in [bjmByte, bjmChar])) then
    raise EBJData.CreateFmt('"%s" is not an integer type marker', [AMarker]);
  Result := TBJData.Create(bjkInt);
  Result.FMarker := AMarker;
  Result.FInt := AValue;
end;

class function TBJData.NewUInt(AValue: QWord): TBJData;
begin
  if AValue <= QWord(High(Int64)) then
    Result := NewInt(Int64(AValue), BJUIntMarkerFor(AValue))
  else
  begin
    Result := TBJData.Create(bjkUInt);
    Result.FMarker := bjmUInt64;
    Result.FInt := Int64(AValue);
  end;
end;

class function TBJData.NewFloat(AValue: Double): TBJData;
begin
  Result := NewFloat(AValue, bjmFloat64);
end;

class function TBJData.NewFloat(AValue: Double; AMarker: AnsiChar): TBJData;
begin
  if not BJIsFloatMarker(AMarker) then
    raise EBJData.CreateFmt('"%s" is not a floating-point type marker', [AMarker]);
  Result := TBJData.Create(bjkFloat);
  Result.FMarker := AMarker;
  Result.FFloat := AValue;
end;

class function TBJData.NewString(const AValue: string): TBJData;
begin
  Result := TBJData.Create(bjkString);
  Result.FStr := AValue;
end;

class function TBJData.NewChar(AValue: AnsiChar): TBJData;
begin
  if AValue > #127 then
    raise EBJData.Create('a BJData char must be in the ASCII range 0-127');
  Result := TBJData.Create(bjkString);
  Result.FMarker := bjmChar;
  Result.FStr := AValue;
end;

class function TBJData.NewHighPrec(const AValue: string): TBJData;
begin
  Result := TBJData.Create(bjkString);
  Result.FMarker := bjmHighPrec;
  Result.FStr := AValue;
end;

class function TBJData.NewArray: TBJData;
begin
  Result := TBJData.Create(bjkArray);
end;

class function TBJData.NewObject: TBJData;
begin
  Result := TBJData.Create(bjkObject);
end;

class function TBJData.NewTypedArray(AMarker: AnsiChar;
  const ADims: array of Int64): TBJData;
var
  i: Integer;
  n: Int64;
begin
  if not BJIsFixedMarker(AMarker) then
    raise EBJData.CreateFmt('"%s" cannot be used as a packed array type', [AMarker]);
  Result := TBJData.Create(bjkTypedArray);
  Result.FMarker := AMarker;
  SetLength(Result.FDims, Length(ADims));
  n := 1;
  for i := 0 to High(ADims) do
  begin
    if ADims[i] < 0 then
      raise EBJData.Create('array dimensions must be non-negative');
    Result.FDims[i] := ADims[i];
    n := n * ADims[i];
  end;
  SetLength(Result.FBin, n * BJMarkerSize(AMarker));
  if Length(Result.FBin) > 0 then
    FillChar(Result.FBin[0], Length(Result.FBin), 0);
end;

class function TBJData.NewBytes(const AValue: TBytes): TBJData;
begin
  Result := TBJData.Create(bjkTypedArray);
  Result.FMarker := bjmByte;
  SetLength(Result.FDims, 1);
  Result.FDims[0] := Length(AValue);
  Result.FBin := Copy(AValue, 0, Length(AValue));
end;

class function TBJData.NewExtension(ATypeId: Int64; const APayload: TBytes): TBJData;
begin
  if ATypeId < 0 then
    raise EBJData.Create('an extension type id must be non-negative');
  Result := TBJData.Create(bjkExtension);
  Result.FInt := ATypeId;
  Result.FBin := Copy(APayload, 0, Length(APayload));
end;

class function TBJData.NewComplex(ARe, AIm: Double; ASingle: Boolean): TBJData;
var
  buf: TBytes;
  f: array[0..1] of Single;
  d: array[0..1] of Double;
begin
  if ASingle then
  begin
    f[0] := ARe;
    f[1] := AIm;
    SetLength(buf, 8);
    Move(f[0], buf[0], 8);
    BJFromLE(@buf[0], 4, 2);
    Result := NewExtension(bjxComplex64, buf);
  end
  else
  begin
    d[0] := ARe;
    d[1] := AIm;
    SetLength(buf, 16);
    Move(d[0], buf[0], 16);
    BJFromLE(@buf[0], 8, 2);
    Result := NewExtension(bjxComplex128, buf);
  end;
end;

class function TBJData.NewUUID(const AValue: string): TBJData;
var
  s: string;
  i: Integer;
  buf: TBytes;
begin
  s := StringReplace(Trim(AValue), '-', '', [rfReplaceAll]);
  s := StringReplace(s, '{', '', [rfReplaceAll]);
  s := StringReplace(s, '}', '', [rfReplaceAll]);
  if Length(s) <> 32 then
    raise EBJData.CreateFmt('"%s" is not a valid UUID', [AValue]);
  SetLength(buf, 16);
  for i := 0 to 15 do
    buf[i] := StrToInt('$' + Copy(s, i * 2 + 1, 2));
  Result := NewExtension(bjxUUID, buf);
end;

class function TBJData.NewDateTime(AValue: TDateTime): TBJData;
var
  buf: TBytes;
  us: Int64;
begin
  us := Round((AValue - BJUnixEpoch) * 86400.0 * 1.0e6);
  SetLength(buf, 8);
  Move(us, buf[0], 8);
  BJFromLE(@buf[0], 8, 1);
  Result := NewExtension(bjxDateTimeUSec, buf);
end;

{==============================================================================
  TBJData - container access
==============================================================================}

procedure TBJData.NeedKind(AKind: TBJDataKind; const AWhat: string);
begin
  if FKind <> AKind then
    raise EBJData.CreateFmt('%s is not available on a %s node',
      [AWhat, BJKindName(FKind)]);
end;

procedure TBJData.NeedContainer;
begin
  if not (FKind in [bjkArray, bjkObject]) then
    raise EBJData.Create('this operation requires an array or object node');
end;

function TBJData.GetItem(AIndex: SizeInt): TBJData;
begin
  if (AIndex < 0) or (AIndex >= FCount) then
    raise EBJData.CreateFmt('child index %d is out of range (count=%d)',
      [AIndex, FCount]);
  Result := FItems[AIndex];
end;

procedure TBJData.SetItem(AIndex: SizeInt; AValue: TBJData);
begin
  if (AIndex < 0) or (AIndex >= FCount) then
    raise EBJData.CreateFmt('child index %d is out of range (count=%d)',
      [AIndex, FCount]);
  if FItems[AIndex] = AValue then
    Exit;
  FItems[AIndex].Free;
  FItems[AIndex] := AValue;
end;

function TBJData.GetName(AIndex: SizeInt): string;
begin
  NeedKind(bjkObject, 'a child name');
  if (AIndex < 0) or (AIndex >= FCount) then
    raise EBJData.CreateFmt('child index %d is out of range (count=%d)',
      [AIndex, FCount]);
  Result := FNames[AIndex];
end;

procedure TBJData.SetName(AIndex: SizeInt; const AValue: string);
begin
  NeedKind(bjkObject, 'a child name');
  if (AIndex < 0) or (AIndex >= FCount) then
    raise EBJData.CreateFmt('child index %d is out of range (count=%d)',
      [AIndex, FCount]);
  FNames[AIndex] := AValue;
end;

function TBJData.IndexOfName(const AKey: string): SizeInt;
var
  i: SizeInt;
begin
  Result := -1;
  if FKind <> bjkObject then
    Exit;
  for i := 0 to FCount - 1 do
    if FNames[i] = AKey then
      Exit(i);
end;

function TBJData.Has(const AKey: string): Boolean;
begin
  Result := IndexOfName(AKey) >= 0;
end;

function TBJData.GetValue(const AKey: string): TBJData;
var
  i: SizeInt;
begin
  i := IndexOfName(AKey);
  if i < 0 then
    Result := nil
  else
    Result := FItems[i];
end;

procedure TBJData.SetValue(const AKey: string; AValue: TBJData);
var
  i: SizeInt;
begin
  NeedKind(bjkObject, 'named access');
  i := IndexOfName(AKey);
  if i < 0 then
    Add(AKey, AValue)
  else if FItems[i] <> AValue then
  begin
    FItems[i].Free;
    FItems[i] := AValue;
  end;
end;

procedure TBJData.InsertSlot(AIndex: SizeInt);
var
  i: SizeInt;
begin
  if FCount >= Length(FItems) then
  begin
    if FCount < 4 then
      SetLength(FItems, 4)
    else
      SetLength(FItems, FCount * 2);
    if FKind = bjkObject then
      SetLength(FNames, Length(FItems));
  end;
  if (FKind = bjkObject) and (Length(FNames) < Length(FItems)) then
    SetLength(FNames, Length(FItems));
  for i := FCount downto AIndex + 1 do
  begin
    FItems[i] := FItems[i - 1];
    if FKind = bjkObject then
      FNames[i] := FNames[i - 1];
  end;
  Inc(FCount);
end;

procedure TBJData.Grow;
begin
  SetLength(FItems, Length(FItems) * 2 + 8);
  if FKind = bjkObject then
    SetLength(FNames, Length(FItems));
end;

procedure TBJData.Reserve(ACapacity: SizeInt);
begin
  if ACapacity > Length(FItems) then
  begin
    SetLength(FItems, ACapacity);
    if FKind = bjkObject then
      SetLength(FNames, ACapacity);
  end;
end;

function TBJData.AppendChild(AValue: TBJData): TBJData;
begin
  if FCount >= Length(FItems) then
    Grow;
  FItems[FCount] := AValue;
  Inc(FCount);
  Result := AValue;
end;

{ reserve the next child slot and return its index; the decoder fills the name
  and the node in place, which keeps both out of a managed local variable }
function TBJData.AppendSlot: SizeInt;
begin
  if FCount >= Length(FItems) then
    Grow;
  Result := FCount;
  Inc(FCount);
end;

function TBJData.AppendChild(const AKey: string; AValue: TBJData): TBJData;
begin
  if FCount >= Length(FItems) then
    Grow;
  FItems[FCount] := AValue;
  FNames[FCount] := AKey;
  Inc(FCount);
  Result := AValue;
end;

function TBJData.Add(AValue: TBJData): TBJData;
begin
  if FKind <> bjkArray then
    raise EBJData.Create('Add(value) requires an array node');
  if AValue = nil then
    AValue := TBJData.NewNull;
  InsertSlot(FCount);
  FItems[FCount - 1] := AValue;
  Result := AValue;
end;

function TBJData.Add(const AKey: string; AValue: TBJData): TBJData;
begin
  if FKind <> bjkObject then
    raise EBJData.Create('Add(key, value) requires an object node');
  if AValue = nil then
    AValue := TBJData.NewNull;
  InsertSlot(FCount);
  FItems[FCount - 1] := AValue;
  FNames[FCount - 1] := AKey;
  Result := AValue;
end;

function TBJData.AddNull: TBJData;
begin
  Result := Add(TBJData.NewNull);
end;

function TBJData.Insert(AIndex: SizeInt; AValue: TBJData): TBJData;
begin
  NeedContainer;
  if (AIndex < 0) or (AIndex > FCount) then
    raise EBJData.CreateFmt('insert index %d is out of range', [AIndex]);
  if AValue = nil then
    AValue := TBJData.NewNull;
  InsertSlot(AIndex);
  FItems[AIndex] := AValue;
  if FKind = bjkObject then
    FNames[AIndex] := '';
  Result := AValue;
end;

function TBJData.Extract(AIndex: SizeInt): TBJData;
var
  i: SizeInt;
begin
  Result := GetItem(AIndex);
  for i := AIndex to FCount - 2 do
  begin
    FItems[i] := FItems[i + 1];
    if FKind = bjkObject then
      FNames[i] := FNames[i + 1];
  end;
  Dec(FCount);
  FItems[FCount] := nil;
  if FKind = bjkObject then
    FNames[FCount] := '';
end;

procedure TBJData.Delete(AIndex: SizeInt);
begin
  Extract(AIndex).Free;
end;

procedure TBJData.Remove(const AKey: string);
var
  i: SizeInt;
begin
  i := IndexOfName(AKey);
  if i >= 0 then
    Delete(i);
end;

procedure TBJData.Clear;
var
  i: SizeInt;
begin
  for i := 0 to FCount - 1 do
    FItems[i].Free;
  FCount := 0;
  SetLength(FItems, 0);
  SetLength(FNames, 0);
end;

function TBJData.Clone: TBJData;
var
  i: SizeInt;
begin
  Result := TBJData.Create(FKind);
  Result.FMarker := FMarker;
  Result.FInt := FInt;
  Result.FFloat := FFloat;
  Result.FStr := FStr;
  Result.FBin := Copy(FBin, 0, Length(FBin));
  Result.FDims := Copy(FDims, 0, Length(FDims));
  Result.FColumnMajor := FColumnMajor;
  Result.FFromSoA := FFromSoA;
  if FCount > 0 then
  begin
    SetLength(Result.FItems, FCount);
    if FKind = bjkObject then
      SetLength(Result.FNames, FCount);
    for i := 0 to FCount - 1 do
    begin
      Result.FItems[i] := FItems[i].Clone;
      if FKind = bjkObject then
        Result.FNames[i] := FNames[i];
    end;
    Result.FCount := FCount;
  end;
end;

function TBJData.Path(const APath: string): TBJData;
var
  i, len: Integer;
  token: string;
  node: TBJData;

  function Step(ANode: TBJData; const AToken: string; AIsIndex: Boolean): TBJData;
  var
    idx: Integer;
  begin
    Result := nil;
    if ANode = nil then
      Exit;
    if AIsIndex then
    begin
      idx := StrToIntDef(AToken, -1);
      if (ANode.FKind in [bjkArray, bjkObject]) and (idx >= 0) and
         (idx < ANode.FCount) then
        Result := ANode.FItems[idx];
    end
    else if AToken <> '' then
      Result := ANode.GetValue(AToken);
  end;

begin
  node := Self;
  i := 1;
  len := Length(APath);
  token := '';
  while (i <= len) and (node <> nil) do
  begin
    case APath[i] of
      '.':
        begin
          if token <> '' then
            node := Step(node, token, False);
          token := '';
          Inc(i);
        end;
      '[':
        begin
          if token <> '' then
            node := Step(node, token, False);
          token := '';
          Inc(i);
          while (i <= len) and (APath[i] <> ']') do
          begin
            token := token + APath[i];
            Inc(i);
          end;
          if i <= len then
            Inc(i);                    { skip the closing bracket }
          node := Step(node, token, True);
          token := '';
        end;
    else
      token := token + APath[i];
      Inc(i);
    end;
  end;
  if (node <> nil) and (token <> '') then
    node := Step(node, token, False);
  Result := node;
end;

{==============================================================================
  TBJData - scalar value access
==============================================================================}

function TBJData.GetAsInt64: Int64;
begin
  case FKind of
    bjkInt, bjkUInt, bjkBoolean:
      Result := FInt;
    bjkFloat:
      Result := Round(FFloat);
    bjkString:
      Result := StrToInt64Def(Trim(FStr), 0);
    bjkNull, bjkNoOp:
      Result := 0;
  else
    raise EBJData.Create('this node cannot be read as an integer');
  end;
end;

function TBJData.GetAsQWord: QWord;
begin
  if FKind = bjkUInt then
    Result := QWord(FInt)
  else
    Result := QWord(GetAsInt64);
end;

function TBJData.GetAsDouble: Double;
begin
  case FKind of
    bjkFloat:
      Result := FFloat;
    bjkInt, bjkBoolean:
      Result := FInt;
    bjkUInt:
      Result := QWord(FInt);
    bjkString:
      Result := StrToFloatDef(Trim(FStr), 0.0, BJFormat);
    bjkNull, bjkNoOp:
      Result := 0.0;
  else
    raise EBJData.Create('this node cannot be read as a number');
  end;
end;

function TBJData.GetAsString: string;
begin
  case FKind of
    bjkString:
      Result := FStr;
    bjkInt:
      Result := IntToStr(FInt);
    bjkUInt:
      Result := UIntToStr(QWord(FInt));
    bjkFloat:
      Result := BJFloatToStr(FFloat);
    bjkBoolean:
      if FInt <> 0 then
        Result := 'true'
      else
        Result := 'false';
    bjkNull:
      Result := 'null';
    bjkNoOp:
      Result := '';
  else
    Result := ToJSON(0);
  end;
end;

function TBJData.GetAsBoolean: Boolean;
begin
  case FKind of
    bjkBoolean, bjkInt, bjkUInt:
      Result := FInt <> 0;
    bjkFloat:
      Result := FFloat <> 0.0;
    bjkString:
      Result := (FStr <> '') and (LowerCase(FStr) <> 'false');
    bjkNull, bjkNoOp:
      Result := False;
  else
    Result := True;
  end;
end;

function TBJData.IsNull: Boolean;
begin
  Result := FKind = bjkNull;
end;

function TBJData.IsContainer: Boolean;
begin
  Result := FKind in [bjkArray, bjkObject, bjkTypedArray];
end;

function TBJData.IsNumber: Boolean;
begin
  Result := FKind in [bjkInt, bjkUInt, bjkFloat];
end;

function TBJData.IsHighPrec: Boolean;
begin
  Result := (FKind = bjkString) and (FMarker = bjmHighPrec);
end;

{==============================================================================
  TBJData - packed (N-dimensional) array access
==============================================================================}

function TBJData.GetDimCount: SizeInt;
begin
  Result := Length(FDims);
end;

function TBJData.GetDim(AIndex: SizeInt): Int64;
begin
  if (AIndex < 0) or (AIndex >= Length(FDims)) then
    raise EBJData.CreateFmt('dimension index %d is out of range', [AIndex]);
  Result := FDims[AIndex];
end;

procedure TBJData.SetDims(const ADims: array of Int64);
var
  i: Integer;
  n: Int64;
begin
  n := 1;
  for i := 0 to High(ADims) do
    n := n * ADims[i];
  if (FKind = bjkTypedArray) and (n <> ElementCount) then
    raise EBJData.Create('the new dimensions do not match the element count');
  SetLength(FDims, Length(ADims));
  for i := 0 to High(ADims) do
    FDims[i] := ADims[i];
end;

function TBJData.ElementCount: Int64;
var
  i: Integer;
begin
  case FKind of
    bjkTypedArray:
      begin
        if Length(FDims) = 0 then
          Exit(0);
        Result := 1;
        for i := 0 to High(FDims) do
          Result := Result * FDims[i];
      end;
    bjkArray, bjkObject:
      Result := FCount;
  else
    Result := 1;
  end;
end;

function TBJData.ElemAsDouble(AIndex: Int64): Double;
var
  p: PByte;
  sz: Integer;
  w: Word;
  f: Single;
  d: Double;
begin
  NeedKind(bjkTypedArray, 'element access');
  sz := BJMarkerSize(FMarker);
  if (AIndex < 0) or ((AIndex + 1) * sz > Length(FBin)) then
    raise EBJData.CreateFmt('element index %d is out of range', [AIndex]);
  p := @FBin[AIndex * sz];
  case FMarker of
    bjmFloat16:
      begin
        Move(p^, w, 2);
        Result := BJHalfToDouble(w);
      end;
    bjmFloat32:
      begin
        Move(p^, f, 4);
        Result := f;
      end;
    bjmFloat64:
      begin
        Move(p^, d, 8);
        Result := d;
      end;
    bjmUInt64:
      Result := QWord(PQWord(p)^);
  else
    Result := ElemAsInt64(AIndex);
  end;
end;

function TBJData.ElemAsInt64(AIndex: Int64): Int64;
var
  p: PByte;
  sz: Integer;
begin
  NeedKind(bjkTypedArray, 'element access');
  sz := BJMarkerSize(FMarker);
  if (AIndex < 0) or ((AIndex + 1) * sz > Length(FBin)) then
    raise EBJData.CreateFmt('element index %d is out of range', [AIndex]);
  p := @FBin[AIndex * sz];
  case FMarker of
    bjmInt8:   Result := PShortInt(p)^;
    bjmUInt8, bjmByte, bjmChar: Result := p^;
    bjmInt16:  Result := PSmallInt(p)^;
    bjmUInt16: Result := PWord(p)^;
    bjmInt32:  Result := PLongInt(p)^;
    bjmUInt32: Result := PLongWord(p)^;
    bjmInt64, bjmUInt64: Result := PInt64(p)^;
    bjmFloat16, bjmFloat32, bjmFloat64: Result := Round(ElemAsDouble(AIndex));
  else
    Result := 0;
  end;
end;

procedure TBJData.SetElem(AIndex: Int64; const AValue: Double);
var
  p: PByte;
  sz: Integer;
  w: Word;
  f: Single;
begin
  NeedKind(bjkTypedArray, 'element access');
  sz := BJMarkerSize(FMarker);
  if (AIndex < 0) or ((AIndex + 1) * sz > Length(FBin)) then
    raise EBJData.CreateFmt('element index %d is out of range', [AIndex]);
  p := @FBin[AIndex * sz];
  case FMarker of
    bjmFloat16:
      begin
        w := BJDoubleToHalf(AValue);
        Move(w, p^, 2);
      end;
    bjmFloat32:
      begin
        f := AValue;
        Move(f, p^, 4);
      end;
    bjmFloat64:
      Move(AValue, p^, 8);
  else
    SetElem(AIndex, Round(AValue));
  end;
end;

procedure TBJData.SetElem(AIndex: Int64; const AValue: Int64);
var
  p: PByte;
  sz: Integer;
begin
  NeedKind(bjkTypedArray, 'element access');
  sz := BJMarkerSize(FMarker);
  if (AIndex < 0) or ((AIndex + 1) * sz > Length(FBin)) then
    raise EBJData.CreateFmt('element index %d is out of range', [AIndex]);
  p := @FBin[AIndex * sz];
  case FMarker of
    bjmInt8, bjmUInt8, bjmByte, bjmChar: p^ := Byte(AValue);
    bjmInt16, bjmUInt16: PWord(p)^ := Word(AValue);
    bjmInt32, bjmUInt32: PLongWord(p)^ := LongWord(AValue);
    bjmInt64, bjmUInt64: PInt64(p)^ := AValue;
    bjmFloat16, bjmFloat32, bjmFloat64: SetElem(AIndex, Double(AValue));
  end;
end;

function TBJData.ExpandTypedArray: TBJData;
var
  dimidx: array of Int64;
  offset: Int64;

  function BuildSlice(ALevel: Integer; var AOffset: Int64): TBJData;
  var
    i: Int64;
  begin
    Result := TBJData.NewArray;
    if ALevel = High(FDims) then
    begin
      for i := 0 to FDims[ALevel] - 1 do
      begin
        if BJIsFloatMarker(FMarker) then
          Result.Add(TBJData.NewFloat(ElemAsDouble(AOffset), FMarker))
        else
          Result.Add(TBJData.NewInt(ElemAsInt64(AOffset), FMarker));
        Inc(AOffset);
      end;
    end
    else
      for i := 0 to FDims[ALevel] - 1 do
        Result.Add(BuildSlice(ALevel + 1, AOffset));
  end;

  { a column-major payload is addressed through the first-index-fastest map }
  function ColumnIndex(const ASub: array of Int64): Int64;
  var
    k: Integer;
    stride: Int64;
  begin
    Result := 0;
    stride := 1;
    for k := 0 to High(FDims) do
    begin
      Result := Result + ASub[k] * stride;
      stride := stride * FDims[k];
    end;
  end;

  function BuildColSlice(ALevel: Integer): TBJData;
  var
    i: Int64;
  begin
    Result := TBJData.NewArray;
    for i := 0 to FDims[ALevel] - 1 do
    begin
      dimidx[ALevel] := i;
      if ALevel = High(FDims) then
      begin
        if BJIsFloatMarker(FMarker) then
          Result.Add(TBJData.NewFloat(ElemAsDouble(ColumnIndex(dimidx)), FMarker))
        else
          Result.Add(TBJData.NewInt(ElemAsInt64(ColumnIndex(dimidx)), FMarker));
      end
      else
        Result.Add(BuildColSlice(ALevel + 1));
    end;
  end;

begin
  NeedKind(bjkTypedArray, 'expansion');
  if Length(FDims) = 0 then
    Exit(TBJData.NewArray);
  if FColumnMajor then
  begin
    SetLength(dimidx, Length(FDims));
    Result := BuildColSlice(0);
  end
  else
  begin
    offset := 0;
    Result := BuildSlice(0, offset);
  end;
end;

function TBJData.AsBytes: TBytes;
var
  i: Integer;
begin
  Result := nil;
  case FKind of
    bjkTypedArray, bjkExtension:
      Result := Copy(FBin, 0, Length(FBin));
    bjkString:
      begin
        SetLength(Result, Length(FStr));
        if Length(FStr) > 0 then
          Move(FStr[1], Result[0], Length(FStr));
      end;
    bjkArray:
      begin
        SetLength(Result, FCount);
        for i := 0 to FCount - 1 do
          Result[i] := Byte(FItems[i].GetAsInt64);
      end;
  else
    raise EBJData.Create('this node cannot be read as a byte array');
  end;
end;

{==============================================================================
  TBJData - extension helpers
==============================================================================}

function TBJData.ExtTypeId: Int64;
begin
  NeedKind(bjkExtension, 'the extension type id');
  Result := FInt;
end;

function TBJData.ExtPayload: TBytes;
begin
  NeedKind(bjkExtension, 'the extension payload');
  Result := Copy(FBin, 0, Length(FBin));
end;

function TBJData.AsComplex(out ARe, AIm: Double): Boolean;
var
  f: array[0..1] of Single;
  d: array[0..1] of Double;
begin
  Result := False;
  ARe := 0;
  AIm := 0;
  if FKind <> bjkExtension then
    Exit;
  if (FInt = bjxComplex64) and (Length(FBin) >= 8) then
  begin
    Move(FBin[0], f[0], 8);
    ARe := f[0];
    AIm := f[1];
    Result := True;
  end
  else if (FInt = bjxComplex128) and (Length(FBin) >= 16) then
  begin
    Move(FBin[0], d[0], 16);
    ARe := d[0];
    AIm := d[1];
    Result := True;
  end;
end;

function TBJData.AsUUIDString: string;
var
  h: string;
begin
  Result := '';
  if (FKind <> bjkExtension) or (FInt <> bjxUUID) or (Length(FBin) < 16) then
    Exit;
  h := BJHexStr(Copy(FBin, 0, 16));
  Result := Copy(h, 1, 8) + '-' + Copy(h, 9, 4) + '-' + Copy(h, 13, 4) + '-' +
            Copy(h, 17, 4) + '-' + Copy(h, 21, 12);
end;

function TBJData.AsDateTime: TDateTime;
var
  us, sec: Int64;
  ns: LongWord;
  yr: SmallInt;
begin
  Result := 0;
  if FKind <> bjkExtension then
    Exit;
  case FInt of
    bjxEpochSec:
      if Length(FBin) >= 4 then
        Result := BJUnixEpoch + PLongWord(@FBin[0])^ / 86400.0;
    bjxEpochUSec, bjxDateTimeUSec, bjxTimeDeltaUSec:
      if Length(FBin) >= 8 then
      begin
        Move(FBin[0], us, 8);
        if FInt = bjxTimeDeltaUSec then
          Result := us / (86400.0 * 1.0e6)
        else
          Result := BJUnixEpoch + us / (86400.0 * 1.0e6);
      end;
    bjxEpochNSec:
      if Length(FBin) >= 12 then
      begin
        Move(FBin[0], sec, 8);
        Move(FBin[8], ns, 4);
        Result := BJUnixEpoch + (sec + ns / 1.0e9) / 86400.0;
      end;
    bjxDate:
      if Length(FBin) >= 4 then
      begin
        Move(FBin[0], yr, 2);
        Result := EncodeDate(yr, FBin[2], FBin[3]);
      end;
    bjxTimeSec:
      if Length(FBin) >= 3 then
        Result := EncodeTime(FBin[0], FBin[1], Min(Integer(FBin[2]), 59), 0);
  end;
end;

{==============================================================================
  TBJData - JSON rendering
==============================================================================}

function TBJData.ToJSON(AIndent: Integer): string;
var
  sb: TStringBuilder;

  procedure Pad(ALevel: Integer);
  begin
    if AIndent > 0 then
    begin
      sb.Append(LineEnding);
      sb.Append(StringOfChar(' ', ALevel * AIndent));
    end;
  end;

  procedure Dump(ANode: TBJData; ALevel: Integer);

    procedure DumpPacked(ALocal: TBJData; ALocalLevel: Integer);
    var
      pos: Int64;
      tmp: TBJData;

      procedure Slice(ADim, ASubLevel: Integer);
      var
        i: Int64;
      begin
        sb.Append('[');
        for i := 0 to ALocal.FDims[ADim] - 1 do
        begin
          if i > 0 then
            sb.Append(',');
          if ADim = High(ALocal.FDims) then
          begin
            if BJIsFloatMarker(ALocal.FMarker) then
              sb.Append(BJFloatToStr(ALocal.ElemAsDouble(pos)))
            else if ALocal.FMarker = bjmUInt64 then
              sb.Append(UIntToStr(QWord(ALocal.ElemAsInt64(pos))))
            else
              sb.Append(IntToStr(ALocal.ElemAsInt64(pos)));
            Inc(pos);
          end
          else
          begin
            Pad(ASubLevel + 1);
            Slice(ADim + 1, ASubLevel + 1);
          end;
        end;
        if ADim < High(ALocal.FDims) then
          Pad(ASubLevel);
        sb.Append(']');
      end;

    begin
      if Length(ALocal.FDims) = 0 then
      begin
        sb.Append('[]');
        Exit;
      end;
      if ALocal.FColumnMajor then
      begin
        tmp := ALocal.ExpandTypedArray;
        try
          Dump(tmp, ALocalLevel);
        finally
          tmp.Free;
        end;
        Exit;
      end;
      pos := 0;
      Slice(0, ALocalLevel);
    end;

    procedure DumpExtension(ALocal: TBJData);
    var
      re, im: Double;
    begin
      sb.Append('{"_ExtType_":');
      sb.Append(IntToStr(ALocal.FInt));
      if ALocal.AsComplex(re, im) then
      begin
        sb.Append(',"_ExtValue_":[');
        sb.Append(BJFloatToStr(re));
        sb.Append(',');
        sb.Append(BJFloatToStr(im));
        sb.Append(']');
      end
      else if ALocal.FInt = bjxUUID then
      begin
        sb.Append(',"_ExtValue_":"');
        sb.Append(ALocal.AsUUIDString);
        sb.Append('"');
      end
      else
      begin
        sb.Append(',"_ExtData_":"');
        sb.Append(BJHexStr(ALocal.FBin));
        sb.Append('"');
      end;
      sb.Append('}');
    end;

  var
    i: SizeInt;
  begin
    case ANode.FKind of
      bjkNull, bjkNoOp:
        sb.Append('null');
      bjkBoolean:
        if ANode.FInt <> 0 then
          sb.Append('true')
        else
          sb.Append('false');
      bjkInt:
        sb.Append(IntToStr(ANode.FInt));
      bjkUInt:
        sb.Append(UIntToStr(QWord(ANode.FInt)));
      bjkFloat:
        sb.Append(BJFloatToStr(ANode.FFloat));
      bjkString:
        if ANode.FMarker = bjmHighPrec then
          sb.Append(ANode.FStr)
        else
        begin
          sb.Append('"');
          if BJPlainText(ANode.FStr) then
            sb.Append(ANode.FStr)
          else
            sb.Append(BJJSONEscape(ANode.FStr));
          sb.Append('"');
        end;
      bjkTypedArray:
        DumpPacked(ANode, ALevel);
      bjkExtension:
        DumpExtension(ANode);
      bjkArray:
        begin
          if ANode.FCount = 0 then
          begin
            sb.Append('[]');
            Exit;
          end;
          sb.Append('[');
          for i := 0 to ANode.FCount - 1 do
          begin
            if i > 0 then
              sb.Append(',');
            Pad(ALevel + 1);
            Dump(ANode.FItems[i], ALevel + 1);
          end;
          Pad(ALevel);
          sb.Append(']');
        end;
      bjkObject:
        begin
          if ANode.FCount = 0 then
          begin
            sb.Append('{}');
            Exit;
          end;
          sb.Append('{');
          for i := 0 to ANode.FCount - 1 do
          begin
            if i > 0 then
              sb.Append(',');
            Pad(ALevel + 1);
            sb.Append('"');
            if BJPlainText(ANode.FNames[i]) then
              sb.Append(ANode.FNames[i])
            else
              sb.Append(BJJSONEscape(ANode.FNames[i]));
            sb.Append('":');
            if AIndent > 0 then
              sb.Append(' ');
            Dump(ANode.FItems[i], ALevel + 1);
          end;
          Pad(ALevel);
          sb.Append('}');
        end;
    end;
  end;

begin
  sb := TStringBuilder.Create;
  try
    Dump(Self, 0);
    Result := sb.ToString;
  finally
    sb.Free;
  end;
end;

{==============================================================================
  SoA schema description (used by both the reader and the writer)
==============================================================================}

type
  TBJSoAKind = (
    skFixed,      // fixed-length numeric/char/byte column
    skBool,       // 'T' in a schema: one T/F byte per record
    skNull,       // 'Z' in a schema: zero bytes per record
    skStrFixed,   // 'S'/'H' + length: fixed-width padded string
    skStrDict,    // [$S#n ... : one dictionary index per record
    skStrOffset,  // [$<int>] : one index per record + trailing offset table
    skArray,      // [ ... ] : fixed-length array of sub-columns
    skObject      // { ... } : nested record
  );

  TBJSoAField = class;
  TBJSoAFieldArray = array of TBJSoAField;

  TBJSoAField = class(TObject)
  public
    Name: string;
    Kind: TBJSoAKind;
    Marker: AnsiChar;           // element marker of a skFixed column
    IsHighPrec: Boolean;        // string column holds 'H' values
    Len: SizeInt;               // width of a skStrFixed column
    IdxMarker: AnsiChar;        // integer type of a dictionary/offset index
    Dict: TBJDataNames;         // dictionary entries
    Fields: TBJSoAFieldArray;   // sub-columns of skArray/skObject
    Nodes: TBJDataItems;        // scratch: nodes awaiting offset resolution
    Order: TBJDataDims;         // scratch: index stored for each pending node
    NodeCount: SizeInt;         // scratch: number of pending nodes
    destructor Destroy; override;
    procedure AddPending(ANode: TBJData; AIndex: Int64);
  end;

destructor TBJSoAField.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(Fields) do
    Fields[i].Free;
  inherited Destroy;
end;

procedure TBJSoAField.AddPending(ANode: TBJData; AIndex: Int64);
begin
  if NodeCount >= Length(Nodes) then
  begin
    SetLength(Nodes, Max(8, NodeCount * 2));
    SetLength(Order, Length(Nodes));
  end;
  Nodes[NodeCount] := ANode;
  Order[NodeCount] := AIndex;
  Inc(NodeCount);
end;

procedure BJFreeSchema(var ASchema: TBJSoAFieldArray);
var
  i: Integer;
begin
  for i := 0 to High(ASchema) do
    ASchema[i].Free;
  SetLength(ASchema, 0);
end;

{ depth-first list of the columns that use an offset table, in schema order }
procedure BJCollectOffsetFields(const ASchema: TBJSoAFieldArray;
  var AList: TBJSoAFieldArray);
var
  i: Integer;
begin
  for i := 0 to High(ASchema) do
  begin
    if ASchema[i].Kind = skStrOffset then
    begin
      SetLength(AList, Length(AList) + 1);
      AList[High(AList)] := ASchema[i];
    end
    else if ASchema[i].Kind in [skArray, skObject] then
      BJCollectOffsetFields(ASchema[i].Fields, AList);
  end;
end;

function BJDimProduct(const ADims: TBJDataDims): Int64;
var
  i: Integer;
begin
  if Length(ADims) = 0 then
    Exit(0);
  Result := 1;
  for i := 0 to High(ADims) do
  begin
    if ADims[i] < 0 then
      raise EBJData.Create('a negative dimension is not allowed');
    Result := Result * ADims[i];
  end;
end;

function BJIndexMarkerFor(ACount: Int64): AnsiChar;
begin
  if ACount <= 255 then
    Result := bjmUInt8
  else if ACount <= 65535 then
    Result := bjmUInt16
  else if ACount <= 4294967295 then
    Result := bjmUInt32
  else
    Result := bjmUInt64;
end;

{==============================================================================
  TBJReader - the decoder
==============================================================================}

const
  { direct-mapped cache of recently seen object keys; records in a document
    normally repeat the same handful of names, and sharing those strings
    removes one allocation, one copy and one release per key }
  BJKeyCacheSize = 1024;
  BJKeyCacheMaxLen = 64;

type
  TBJReader = class(TObject)
  private
    FBuf: PByte;
    FCur: PByte;
    FEnd: PByte;
    FSize: PtrUInt;
    FOptions: TBJDataParseOptions;
    FPending: TBJDataItems;      // containers under construction, not yet owned
    FPendingCount: SizeInt;
    FKeyHash: array[0..BJKeyCacheSize - 1] of LongWord;
    FKeyText: array[0..BJKeyCacheSize - 1] of string;
    function Offset: PtrUInt; inline;
    procedure FailEOF(ACount: PtrUInt);
    procedure FailMarker(const AFmt: string; AMarker: AnsiChar);
    procedure FailUnknown(AMarker: AnsiChar);
    procedure Need(ACount: PtrUInt); inline;
    procedure Fail(const AMsg: string);
    function AtEOF: Boolean; inline;
    function ReadChar: AnsiChar; inline;
    function PeekChar: AnsiChar; inline;
    procedure SkipChar; inline;
    procedure PushPending(ANode: TBJData); inline;
    procedure PopPending; inline;
    procedure Expect(AMarker: AnsiChar);
    function ReadStr(ALength: PtrUInt): string;
    procedure ReadStrInto(out AText: string; ALength: PtrUInt);
    procedure ReadKeyInto(out AText: string);
    function ReadIntValue(AMarker: AnsiChar): Int64;
    function ReadFloatValue(AMarker: AnsiChar): Double;
    function ReadSize: Int64;
    function ReadKey: string;
    function ReadDimArray(out ADims: TBJDataDims): Boolean;
    procedure ReadCountSpec(out ADims: TBJDataDims; out AColumnMajor: Boolean);
    function ReadScalar(AMarker: AnsiChar): TBJData;
    function ReadPacked(AMarker: AnsiChar; const ADims: TBJDataDims;
      AColumnMajor: Boolean): TBJData;
    function ReadArrayNode: TBJData;
    function ReadArrayOptimized: TBJData;
    function ReadObjectNode: TBJData;
    function ReadObjectOptimized: TBJData;
    function ReadExtensionNode: TBJData;
    function ReadFieldSpec: TBJSoAField;
    function ReadSchema(ATerminator: AnsiChar): TBJSoAFieldArray;
    function ReadSoAValue(AField: TBJSoAField; ARecord: Int64): TBJData;
    function ReadSoA(ARowMajor: Boolean): TBJData;
  public
    constructor Create(ABuffer: PByte; ASize: PtrUInt;
      AOptions: TBJDataParseOptions);
    procedure FreePending;
    function ReadValue: TBJData;
    property Position: PtrUInt read Offset;
  end;

constructor TBJReader.Create(ABuffer: PByte; ASize: PtrUInt;
  AOptions: TBJDataParseOptions);
begin
  inherited Create;
  FBuf := ABuffer;
  FCur := ABuffer;
  FEnd := ABuffer + ASize;
  FSize := ASize;
  FOptions := AOptions;
end;

function TBJReader.Offset: PtrUInt;
begin
  Result := FCur - FBuf;
end;

procedure TBJReader.Fail(const AMsg: string);
begin
  raise EBJData.CreateFmt('%s at byte offset %d', [AMsg, Offset]);
end;

procedure TBJReader.FailEOF(ACount: PtrUInt);
begin
  Fail(Format('unexpected end of input, %d more byte(s) needed', [ACount]));
end;

{ error messages are built in separate routines: a Format call in a decoding
  routine forces the compiler to wrap that routine in a finalization frame }
procedure TBJReader.FailMarker(const AFmt: string; AMarker: AnsiChar);
begin
  Fail(Format(AFmt, [AMarker]));
end;

procedure TBJReader.FailUnknown(AMarker: AnsiChar);
begin
  Fail(Format('unknown type marker "%s" (0x%.2x)', [AMarker, Ord(AMarker)]));
end;

procedure TBJReader.Need(ACount: PtrUInt);
begin
  if FCur + ACount > FEnd then
    FailEOF(ACount);
end;

function TBJReader.AtEOF: Boolean;
begin
  Result := FCur >= FEnd;
end;

function TBJReader.ReadChar: AnsiChar;
begin
  if FCur >= FEnd then
    FailEOF(1);
  Result := AnsiChar(FCur^);
  Inc(FCur);
end;

function TBJReader.PeekChar: AnsiChar;
begin
  if FCur >= FEnd then
    FailEOF(1);
  Result := AnsiChar(FCur^);
end;

procedure TBJReader.SkipChar;
begin
  if FCur >= FEnd then
    FailEOF(1);
  Inc(FCur);
end;

{ containers are registered while they are being filled: they are not yet
  owned by a parent, so this is what an aborted parse has to release }
procedure TBJReader.PushPending(ANode: TBJData);
begin
  if FPendingCount >= Length(FPending) then
    SetLength(FPending, Length(FPending) * 2 + 32);
  FPending[FPendingCount] := ANode;
  Inc(FPendingCount);
end;

procedure TBJReader.PopPending;
begin
  Dec(FPendingCount);
end;

procedure TBJReader.FreePending;
var
  i: SizeInt;
begin
  { deepest first: none of these nodes is a child of another one }
  for i := FPendingCount - 1 downto 0 do
    FPending[i].Free;
  FPendingCount := 0;
end;

procedure TBJReader.Expect(AMarker: AnsiChar);
begin
  if ReadChar <> AMarker then
    FailMarker('expected marker "%s"', AMarker);
end;

function TBJReader.ReadStr(ALength: PtrUInt): string;
begin
  Need(ALength);
  SetLength(Result, ALength);
  if ALength > 0 then
    Move(FCur^, Result[1], ALength);
  Inc(FCur, ALength);
end;

{ read a string straight into its destination: no temporary, no reference
  count pair and no implicit finalization frame in the caller }
procedure TBJReader.ReadStrInto(out AText: string; ALength: PtrUInt);
begin
  if FCur + ALength > FEnd then
    FailEOF(ALength);
  SetLength(AText, ALength);
  if ALength > 0 then
    Move(FCur^, AText[1], ALength);
  Inc(FCur, ALength);
end;

function TBJReader.ReadIntValue(AMarker: AnsiChar): Int64;
var
  sz: Integer;
  v8: Byte;
  v16: Word;
  v32: LongWord;
  v64: Int64;
begin
  sz := BJMarkerSize(AMarker);
  if sz = 0 then
    FailMarker('"%s" is not a fixed-length numeric marker', AMarker);
  Need(sz);
  case sz of
    1:
      begin
        v8 := FCur^;
        if AMarker = bjmInt8 then
          Result := ShortInt(v8)
        else
          Result := v8;
      end;
    2:
      begin
        Move(FCur^, v16, 2);
        BJFromLE(@v16, 2, 1);
        if AMarker = bjmInt16 then
          Result := SmallInt(v16)
        else
          Result := v16;
      end;
    4:
      begin
        Move(FCur^, v32, 4);
        BJFromLE(@v32, 4, 1);
        if AMarker = bjmInt32 then
          Result := LongInt(v32)
        else
          Result := v32;
      end;
  else
    begin
      Move(FCur^, v64, 8);
      BJFromLE(@v64, 8, 1);
      Result := v64;
    end;
  end;
  Inc(FCur, sz);
end;

function TBJReader.ReadFloatValue(AMarker: AnsiChar): Double;
var
  v16: Word;
  v32: Single;
  v64: Double;
begin
  case AMarker of
    bjmFloat16:
      begin
        Need(2);
        Move(FCur^, v16, 2);
        BJFromLE(@v16, 2, 1);
        Inc(FCur, 2);
        Result := BJHalfToDouble(v16);
      end;
    bjmFloat32:
      begin
        Need(4);
        Move(FCur^, v32, 4);
        BJFromLE(@v32, 4, 1);
        Inc(FCur, 4);
        Result := v32;
      end;
    bjmFloat64:
      begin
        Need(8);
        Move(FCur^, v64, 8);
        BJFromLE(@v64, 8, 1);
        Inc(FCur, 8);
        Result := v64;
      end;
  else
    begin
      Result := 0;
      FailMarker('"%s" is not a floating-point marker', AMarker);
    end;
  end;
end;

{ read a length/count: a numeric marker followed by a non-negative integer }
function TBJReader.ReadSize: Int64;
var
  m: AnsiChar;
begin
  m := ReadChar;
  if (m = bjmUInt8) or (m = bjmInt8) then
  begin
    if FCur >= FEnd then
      FailEOF(1);
    Result := FCur^;
    Inc(FCur);
    if (m = bjmInt8) and (Result > 127) then
      Fail('a negative length or count is not allowed');
    Exit;
  end;
  if not BJIsIntMarker(m) then
    FailMarker('"%s" cannot be used as a length or count', m);
  Result := ReadIntValue(m);
  if Result < 0 then
    Fail('a negative length or count is not allowed');
end;

{ read an object key: a length marker, the length and the UTF-8 bytes; a
  redundant 'S' marker (as written by some UBJSON encoders) is tolerated }
function TBJReader.ReadKey: string;
var
  m: AnsiChar;
  len: Int64;
begin
  m := ReadChar;
  if m = bjmString then
    m := ReadChar;
  if not BJIsIntMarker(m) then
    Fail(Format('"%s" is not a valid key length marker', [m]));
  len := ReadIntValue(m);
  if len < 0 then
    Fail('a negative key length is not allowed');
  Result := ReadStr(len);
end;

procedure TBJReader.ReadKeyInto(out AText: string);
var
  m: AnsiChar;
  len: Int64;
  h: LongWord;
  slot: Integer;
  p: PByte;
begin
  m := ReadChar;
  if (m = bjmUInt8) or (m = bjmInt8) then
  begin
    if FCur >= FEnd then
      FailEOF(1);
    len := FCur^;
    Inc(FCur);
    if (m = bjmInt8) and (len > 127) then
      Fail('a negative key length is not allowed');
  end
  else
  begin
    if m = bjmString then
      m := ReadChar;
    if not BJIsIntMarker(m) then
      FailMarker('"%s" is not a valid key length marker', m);
    len := ReadIntValue(m);
    if len < 0 then
      Fail('a negative key length is not allowed');
  end;
  if (len = 0) or (len > BJKeyCacheMaxLen) then
  begin
    ReadStrInto(AText, len);
    Exit;
  end;
  if FCur + len > FEnd then
    FailEOF(len);
  p := FCur;
  { a weak hash is fine here: every hit is confirmed with a byte comparison,
    so a collision only costs a re-read of the key }
  h := LongWord(len);
  if len >= 4 then
    h := h xor PLongWord(p)^ xor (PLongWord(@p[len - 4])^ * 2246822519)
  else
    h := h xor p^ xor (LongWord(p[len - 1]) shl 8);
  h := h * 2654435761;
  slot := (h shr 13) and (BJKeyCacheSize - 1);
  if (FKeyHash[slot] = h) and (Length(FKeyText[slot]) = len) and
     CompareMem(p, PAnsiChar(FKeyText[slot]), len) then
  begin
    AText := FKeyText[slot];
    Inc(FCur, len);
    Exit;
  end;
  ReadStrInto(AText, len);
  FKeyHash[slot] := h;
  FKeyText[slot] := AText;
end;

{ read the dimension list of an optimized array; the opening '[' has already
  been consumed. Returns True when the list was wrapped in an extra array,
  which marks a column-major payload }
function TBJReader.ReadDimArray(out ADims: TBJDataDims): Boolean;
var
  m, et: AnsiChar;
  cnt, i: Int64;
  n: Integer;
begin
  Result := False;
  SetLength(ADims, 0);
  m := PeekChar;
  if m = bjmArrayStart then         // [ [dims] ] : column-major
  begin
    SkipChar;
    ReadDimArray(ADims);
    Expect(bjmArrayEnd);
    Exit(True);
  end;
  if m = bjmCountMark then          // [#n dims...
  begin
    SkipChar;
    cnt := ReadSize;
    if (not AtEOF) and (PeekChar = bjmArrayStart) then
    begin                           // [#1 [dims] : column-major
      SkipChar;
      ReadDimArray(ADims);
      Exit(True);
    end;
    SetLength(ADims, cnt);
    for i := 0 to cnt - 1 do
      ADims[i] := ReadSize;
    Exit;
  end;
  if m = bjmTypeMark then           // [$t#n dims...
  begin
    SkipChar;
    et := ReadChar;
    if not BJIsIntMarker(et) then
      Fail(Format('"%s" is not a valid dimension type', [et]));
    Expect(bjmCountMark);
    cnt := ReadSize;
    SetLength(ADims, cnt);
    for i := 0 to cnt - 1 do
      ADims[i] := ReadIntValue(et);
    Exit;
  end;
  n := 0;                           // [dim dim ... ]
  while True do
  begin
    m := ReadChar;
    if m = bjmArrayEnd then
      Break;
    if not BJIsIntMarker(m) then
      Fail(Format('"%s" is not a valid dimension type', [m]));
    if n >= Length(ADims) then
      SetLength(ADims, Max(4, n * 2));
    ADims[n] := ReadIntValue(m);
    Inc(n);
  end;
  SetLength(ADims, n);
end;

{ read what follows a '#' marker: either a plain count or a dimension vector }
procedure TBJReader.ReadCountSpec(out ADims: TBJDataDims;
  out AColumnMajor: Boolean);
var
  m: AnsiChar;
begin
  AColumnMajor := False;
  m := ReadChar;
  if m = bjmArrayStart then
    AColumnMajor := ReadDimArray(ADims)
  else
  begin
    if not BJIsIntMarker(m) then
      Fail(Format('"%s" cannot be used as a container count', [m]));
    SetLength(ADims, 1);
    ADims[0] := ReadIntValue(m);
    if ADims[0] < 0 then
      Fail('a negative container count is not allowed');
  end;
end;

function TBJReader.ReadExtensionNode: TBJData;
var
  id, len: Int64;
  buf: TBytes;
begin
  id := ReadSize;
  len := ReadSize;
  SetLength(buf, len);
  if len > 0 then
  begin
    Need(len);
    Move(FCur^, buf[0], len);
    Inc(FCur, len);
  end;
  Result := TBJData.NewExtension(id, buf);
end;

function TBJReader.ReadScalar(AMarker: AnsiChar): TBJData;
var
  q: QWord;
  iv, len: Int64;
  fv: Double;
begin
  case AMarker of
    bjmNull:
      Result := TBJData.NewFast(bjkNull, bjmNull);
    bjmNoOp:
      Result := TBJData.NewFast(bjkNoOp, bjmNoOp);
    bjmTrue:
      begin
        Result := TBJData.NewFast(bjkBoolean, bjmTrue);
        Result.FInt := 1;
      end;
    bjmFalse:
      Result := TBJData.NewFast(bjkBoolean, bjmFalse);
    bjmUInt64:
      begin
        q := QWord(ReadIntValue(AMarker));
        if q <= QWord(High(Int64)) then
          Result := TBJData.NewFast(bjkInt, bjmUInt64)
        else
          Result := TBJData.NewFast(bjkUInt, bjmUInt64);
        Result.FInt := Int64(q);
      end;
    bjmInt8, bjmUInt8, bjmInt16, bjmUInt16, bjmInt32, bjmUInt32, bjmInt64,
    bjmByte:
      begin
        iv := ReadIntValue(AMarker);
        Result := TBJData.NewFast(bjkInt, AMarker);
        Result.FInt := iv;
      end;
    bjmChar:
      begin
        Need(1);
        Result := TBJData.NewFast(bjkString, bjmChar);
        Result.FStr := AnsiChar(FCur^);
        Inc(FCur);
      end;
    bjmFloat16, bjmFloat32, bjmFloat64:
      begin
        fv := ReadFloatValue(AMarker);
        Result := TBJData.NewFast(bjkFloat, AMarker);
        Result.FFloat := fv;
      end;
    bjmString:
      begin
        len := ReadSize;
        Need(len);
        Result := TBJData.NewFast(bjkString, bjmString);
        ReadStrInto(Result.FStr, len);
      end;
    bjmHighPrec:
      begin
        len := ReadSize;
        Need(len);
        Result := TBJData.NewFast(bjkString, bjmHighPrec);
        ReadStrInto(Result.FStr, len);
      end;
    bjmExtension:
      Result := ReadExtensionNode;
    bjmArrayStart:
      Result := ReadArrayNode;
    bjmObjectStart:
      Result := ReadObjectNode;
  else
    begin
      Result := nil;
      FailUnknown(AMarker);
    end;
  end;
end;

function TBJReader.ReadValue: TBJData;
var
  m: AnsiChar;
begin
  repeat
    m := ReadChar;
  until (m <> bjmNoOp) or (bjpKeepNoOp in FOptions);
  Result := ReadScalar(m);
end;

function TBJReader.ReadPacked(AMarker: AnsiChar; const ADims: TBJDataDims;
  AColumnMajor: Boolean): TBJData;
var
  n, nbytes: Int64;
  sz: Integer;
  tmp: TBJData;
begin
  sz := BJMarkerSize(AMarker);
  n := BJDimProduct(ADims);
  nbytes := n * sz;
  Need(nbytes);
  Result := TBJData.NewFast(bjkTypedArray, AMarker);
  Result.FDims := Copy(ADims, 0, Length(ADims));
  Result.FColumnMajor := AColumnMajor;
  SetLength(Result.FBin, nbytes);
  if nbytes > 0 then
  begin
    Move(FCur^, Result.FBin[0], nbytes);
    BJFromLE(@Result.FBin[0], sz, n);
    Inc(FCur, nbytes);
  end;
  if bjpExpandTypedArray in FOptions then
  begin
    tmp := Result;
    try
      Result := tmp.ExpandTypedArray;
    finally
      tmp.Free;
    end;
  end;
end;

{ the common case: a plain array without a count or a type; kept free of
  managed local variables so that the compiler does not wrap it in an
  implicit finalization frame }
function TBJReader.ReadArrayNode: TBJData;
var
  c: AnsiChar;
  idx: SizeInt;
begin
  c := PeekChar;
  if (c = bjmTypeMark) or (c = bjmCountMark) then
    Exit(ReadArrayOptimized);
  Result := TBJData.NewFast(bjkArray, bjmArrayStart);
  PushPending(Result);
  while True do
  begin
    c := PeekChar;
    if c = bjmArrayEnd then
    begin
      SkipChar;
      Break;
    end;
    idx := Result.AppendSlot;
    Result.FItems[idx] := ReadValue;
  end;
  PopPending;
end;

function TBJReader.ReadArrayOptimized: TBJData;
var
  c, et: AnsiChar;
  dims: TBJDataDims;
  colmajor: Boolean;
  n, i: Int64;
begin
  c := ReadChar;
  if c = bjmTypeMark then
  begin
    et := ReadChar;
    if et = bjmObjectStart then
      Exit(ReadSoA(True));                     // row-major SoA record
    Expect(bjmCountMark);
    ReadCountSpec(dims, colmajor);
    if BJIsFixedMarker(et) then
      Exit(ReadPacked(et, dims, colmajor));
    { lenient: a non-fixed optimized type (allowed by UBJSON, not by BJData) }
    n := BJDimProduct(dims);
    Result := TBJData.NewFast(bjkArray, bjmArrayStart);
    PushPending(Result);
    Result.Reserve(n);
    for i := 0 to n - 1 do
      Result.AppendChild(ReadScalar(et));
    PopPending;
  end
  else
  begin
    ReadCountSpec(dims, colmajor);
    n := BJDimProduct(dims);
    Result := TBJData.NewFast(bjkArray, bjmArrayStart);
    PushPending(Result);
    Result.Reserve(n);
    for i := 0 to n - 1 do
      Result.AppendChild(ReadValue);
    PopPending;
  end;
  if Length(dims) > 1 then
  begin
    Result.FDims := Copy(dims, 0, Length(dims));
    Result.FColumnMajor := colmajor;
  end;
end;

function TBJReader.ReadObjectNode: TBJData;
var
  c: AnsiChar;
  idx: SizeInt;
begin
  c := PeekChar;
  if (c = bjmTypeMark) or (c = bjmCountMark) then
    Exit(ReadObjectOptimized);
  Result := TBJData.NewFast(bjkObject, bjmObjectStart);
  PushPending(Result);
  while True do
  begin
    c := PeekChar;
    if c = bjmObjectEnd then
    begin
      SkipChar;
      Break;
    end;
    if c = bjmNoOp then
    begin
      SkipChar;
      Continue;
    end;
    idx := Result.AppendSlot;
    ReadKeyInto(Result.FNames[idx]);
    Result.FItems[idx] := ReadValue;
  end;
  PopPending;
end;

function TBJReader.ReadObjectOptimized: TBJData;
var
  c, et: AnsiChar;
  dims: TBJDataDims;
  colmajor: Boolean;
  n, i: Int64;
  idx: SizeInt;
begin
  c := ReadChar;
  if c = bjmTypeMark then
  begin
    et := ReadChar;
    if et = bjmObjectStart then
      Exit(ReadSoA(False));                    // column-major SoA record
    Expect(bjmCountMark);
    ReadCountSpec(dims, colmajor);
    n := BJDimProduct(dims);
    Result := TBJData.NewFast(bjkObject, bjmObjectStart);
    PushPending(Result);
    Result.Reserve(n);
    for i := 0 to n - 1 do
    begin
      idx := Result.AppendSlot;
      ReadKeyInto(Result.FNames[idx]);
      Result.FItems[idx] := ReadScalar(et);
    end;
    PopPending;
    Exit;
  end;
  ReadCountSpec(dims, colmajor);
  n := BJDimProduct(dims);
  Result := TBJData.NewFast(bjkObject, bjmObjectStart);
  PushPending(Result);
  Result.Reserve(n);
  for i := 0 to n - 1 do
  begin
    idx := Result.AppendSlot;
    ReadKeyInto(Result.FNames[idx]);
    Result.FItems[idx] := ReadValue;
  end;
  PopPending;
end;

{------------------------------------------------------------------------------
  Structure-of-Arrays (SoA) decoding
------------------------------------------------------------------------------}

function TBJReader.ReadFieldSpec: TBJSoAField;
var
  m, t: AnsiChar;
  cnt, i: Int64;
  n: Integer;
  sub: TBJSoAField;
begin
  Result := TBJSoAField.Create;
  try
    m := ReadChar;
    case m of
      bjmArrayStart:
        begin
          if PeekChar = bjmTypeMark then
          begin
            SkipChar;
            t := ReadChar;
            if (t = bjmString) or (t = bjmHighPrec) then
            begin                              // [$S#n <entries> : dictionary
              Result.Kind := skStrDict;
              Result.IsHighPrec := t = bjmHighPrec;
              Expect(bjmCountMark);
              cnt := ReadSize;
              SetLength(Result.Dict, cnt);
              for i := 0 to cnt - 1 do
                Result.Dict[i] := ReadKey;
              Result.IdxMarker := BJIndexMarkerFor(cnt);
            end
            else if BJIsIntMarker(t) then
            begin                              // [$<int>] : offset table
              Result.Kind := skStrOffset;
              Result.IdxMarker := t;
              Expect(bjmArrayEnd);
            end
            else
              Fail(Format('"%s" is not a valid string column type', [t]));
          end
          else
          begin                                // [t t t] : fixed-size array
            Result.Kind := skArray;
            n := 0;
            while PeekChar <> bjmArrayEnd do
            begin
              sub := ReadFieldSpec();
              if n >= Length(Result.Fields) then
                SetLength(Result.Fields, Max(4, n * 2));
              Result.Fields[n] := sub;
              Inc(n);
            end;
            SkipChar;
            SetLength(Result.Fields, n);
          end;
        end;
      bjmObjectStart:
        begin
          Result.Kind := skObject;
          Result.Fields := ReadSchema(bjmObjectEnd);
        end;
      bjmString, bjmHighPrec:
        begin
          Result.Kind := skStrFixed;
          Result.IsHighPrec := m = bjmHighPrec;
          Result.Len := ReadSize;
        end;
      bjmTrue:
        Result.Kind := skBool;
      bjmNull:
        Result.Kind := skNull;
    else
      begin
        if not BJIsFixedMarker(m) then
          Fail(Format('"%s" is not a valid SoA schema type', [m]));
        Result.Kind := skFixed;
        Result.Marker := m;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TBJReader.ReadSchema(ATerminator: AnsiChar): TBJSoAFieldArray;
var
  n: Integer;
  m: AnsiChar;
  key: string;
  fld: TBJSoAField;
begin
  Result := nil;
  n := 0;
  try
    while True do
    begin
      m := PeekChar;
      if m = ATerminator then
      begin
        SkipChar;
        Break;
      end;
      if m = bjmNoOp then
      begin
        SkipChar;
        Continue;
      end;
      key := ReadKey;
      fld := ReadFieldSpec();
      fld.Name := key;
      if n >= Length(Result) then
        SetLength(Result, Max(8, n * 2));
      Result[n] := fld;
      Inc(n);
    end;
    SetLength(Result, n);
  except
    SetLength(Result, n);
    BJFreeSchema(Result);
    raise;
  end;
end;

function TBJReader.ReadSoAValue(AField: TBJSoAField; ARecord: Int64): TBJData;
var
  i: Integer;
  idx: Int64;
  s: string;
  p: Integer;
begin
  case AField.Kind of
    skFixed:
      begin
        if BJIsFloatMarker(AField.Marker) then
          Result := TBJData.NewFloat(ReadFloatValue(AField.Marker), AField.Marker)
        else if AField.Marker = bjmChar then
        begin
          Need(1);
          Result := TBJData.Create(bjkString);
          Result.FMarker := bjmChar;
          Result.FStr := AnsiChar(FCur^);
          Inc(FCur);
        end
        else if AField.Marker = bjmUInt64 then
          Result := TBJData.NewUInt(QWord(ReadIntValue(AField.Marker)))
        else
          Result := TBJData.NewInt(ReadIntValue(AField.Marker), AField.Marker);
      end;
    skBool:
      Result := TBJData.NewBool(ReadChar = bjmTrue);
    skNull:
      Result := TBJData.NewNull;
    skStrFixed:
      begin
        s := ReadStr(AField.Len);
        p := Length(s);
        while (p > 0) and (s[p] = #0) do
          Dec(p);
        SetLength(s, p);
        if AField.IsHighPrec then
          Result := TBJData.NewHighPrec(s)
        else
          Result := TBJData.NewString(s);
      end;
    skStrDict:
      begin
        idx := ReadIntValue(AField.IdxMarker);
        if (idx < 0) or (idx >= Length(AField.Dict)) then
          Fail(Format('dictionary index %d is out of range', [idx]));
        if AField.IsHighPrec then
          Result := TBJData.NewHighPrec(AField.Dict[idx])
        else
          Result := TBJData.NewString(AField.Dict[idx]);
      end;
    skStrOffset:
      begin
        idx := ReadIntValue(AField.IdxMarker);
        if AField.IsHighPrec then
          Result := TBJData.NewHighPrec('')
        else
          Result := TBJData.NewString('');
        AField.AddPending(Result, idx);
      end;
    skArray:
      begin
        Result := TBJData.NewArray;
        PushPending(Result);
        for i := 0 to High(AField.Fields) do
          Result.Add(ReadSoAValue(AField.Fields[i], ARecord));
        PopPending;
      end;
    skObject:
      begin
        Result := TBJData.NewObject;
        PushPending(Result);
        for i := 0 to High(AField.Fields) do
          Result.Add(AField.Fields[i].Name,
            ReadSoAValue(AField.Fields[i], ARecord));
        PopPending;
      end;
  else
    begin
      Result := nil;
      Fail('unsupported SoA column type');
    end;
  end;
end;

function TBJReader.ReadSoA(ARowMajor: Boolean): TBJData;
var
  schema: TBJSoAFieldArray;
  offlist: TBJSoAFieldArray;
  dims: TBJDataDims;
  colmajor: Boolean;
  count, ri: Int64;
  nf, fi, k: Integer;
  values: array of TBJDataItems;
  offsets: TBJDataDims;
  buffer: string;
  fld: TBJSoAField;
  rec, col: TBJData;
  ok: Boolean;
begin
  Result := nil;
  schema := ReadSchema(bjmObjectEnd);
  ok := False;
  try
    Expect(bjmCountMark);
    ReadCountSpec(dims, colmajor);
    count := BJDimProduct(dims);
    nf := Length(schema);

    SetLength(values, nf);
    for fi := 0 to nf - 1 do
      SetLength(values[fi], count);

    if ARowMajor then
    begin
      for ri := 0 to count - 1 do
        for fi := 0 to nf - 1 do
          values[fi][ri] := ReadSoAValue(schema[fi], ri);
    end
    else
    begin
      for fi := 0 to nf - 1 do
        for ri := 0 to count - 1 do
          values[fi][ri] := ReadSoAValue(schema[fi], ri);
    end;

    { resolve the offset tables and string buffers that follow the payload }
    SetLength(offlist, 0);
    BJCollectOffsetFields(schema, offlist);
    for k := 0 to High(offlist) do
    begin
      fld := offlist[k];
      SetLength(offsets, fld.NodeCount + 1);
      for ri := 0 to fld.NodeCount do
        offsets[ri] := ReadIntValue(fld.IdxMarker);
      buffer := ReadStr(offsets[fld.NodeCount]);
      for ri := 0 to fld.NodeCount - 1 do
      begin
        if (fld.Order[ri] < 0) or (fld.Order[ri] >= fld.NodeCount) then
          Fail(Format('string index %d is out of range', [fld.Order[ri]]));
        if offsets[fld.Order[ri]] > offsets[fld.Order[ri] + 1] then
          Fail('the offset table is not monotonic');
        fld.Nodes[ri].FStr := Copy(buffer, offsets[fld.Order[ri]] + 1,
          offsets[fld.Order[ri] + 1] - offsets[fld.Order[ri]]);
      end;
    end;

    { assemble the document tree }
    if (not ARowMajor) and (bjpSoAAsColumns in FOptions) then
    begin
      Result := TBJData.NewObject;
      for fi := 0 to nf - 1 do
      begin
        col := TBJData.NewArray;
        Result.Add(schema[fi].Name, col);
        for ri := 0 to count - 1 do
        begin
          col.Add(values[fi][ri]);
          values[fi][ri] := nil;
        end;
      end;
    end
    else
    begin
      Result := TBJData.NewArray;
      for ri := 0 to count - 1 do
      begin
        rec := TBJData.NewObject;
        Result.Add(rec);
        for fi := 0 to nf - 1 do
        begin
          rec.Add(schema[fi].Name, values[fi][ri]);
          values[fi][ri] := nil;
        end;
      end;
    end;
    Result.FFromSoA := True;
    Result.FColumnMajor := not ARowMajor;
    if Length(dims) > 1 then
      Result.FDims := Copy(dims, 0, Length(dims));
    ok := True;
  finally
    if not ok then
    begin
      for fi := 0 to High(values) do
        for ri := 0 to High(values[fi]) do
          values[fi][ri].Free;
      Result.Free;
      Result := nil;
    end;
    BJFreeSchema(schema);
  end;
end;

{==============================================================================
  TBJWriter - the encoder
==============================================================================}

{ find the smallest fixed-length marker able to hold every value of a column;
  returns False when the values are not all numeric }
function BJCommonMarker(const AValues: TBJDataItems; ACount: Int64;
  out AMarker: AnsiChar): Boolean;
var
  i: Int64;
  v: TBJData;
  anyfloat, anyint, allbyte, allchar, anychar, anybig: Boolean;
  fmark: AnsiChar;
  minv, maxv: Int64;
begin
  Result := False;
  AMarker := bjmFloat64;
  if ACount <= 0 then
    Exit;
  anyfloat := False;
  anyint := False;
  anybig := False;
  anychar := False;
  allbyte := True;
  allchar := True;
  fmark := bjmFloat16;
  minv := High(Int64);
  maxv := Low(Int64);
  for i := 0 to ACount - 1 do
  begin
    v := AValues[i];
    if v = nil then
      Exit;
    case v.Kind of
      bjkFloat:
        begin
          anyfloat := True;
          allbyte := False;
          allchar := False;
          if v.Marker = bjmFloat64 then
            fmark := bjmFloat64
          else if (v.Marker = bjmFloat32) and (fmark <> bjmFloat64) then
            fmark := bjmFloat32;
        end;
      bjkInt:
        begin
          anyint := True;
          allbyte := allbyte and (v.Marker = bjmByte);
          allchar := False;
          if v.AsInt64 < minv then
            minv := v.AsInt64;
          if v.AsInt64 > maxv then
            maxv := v.AsInt64;
        end;
      bjkUInt:
        begin
          anyint := True;
          anybig := True;
          allbyte := False;
          allchar := False;
        end;
      bjkString:
        begin
          if v.Marker <> bjmChar then
            Exit;
          anychar := True;
          anyint := True;
          allbyte := False;
          if Length(v.AsString) <> 1 then
            Exit;
          if minv > 0 then
            minv := 0;
          if maxv < 127 then
            maxv := 127;
        end;
    else
      Exit;
    end;
  end;
  if anychar and not allchar then
    Exit;               { chars and numbers cannot share one payload type }
  if anyfloat then
  begin
    if anyint then
      AMarker := bjmFloat64
    else
      AMarker := fmark;
    Exit(True);
  end;
  if allchar then
  begin
    AMarker := bjmChar;
    Exit(True);
  end;
  if anybig then
  begin
    if minv < 0 then
      Exit;
    AMarker := bjmUInt64;
    Exit(True);
  end;
  if allbyte then
  begin
    AMarker := bjmByte;
    Exit(True);
  end;
  if minv >= 0 then
  begin
    if maxv <= 127 then
      AMarker := bjmInt8
    else if maxv <= 255 then
      AMarker := bjmUInt8
    else if maxv <= 32767 then
      AMarker := bjmInt16
    else if maxv <= 65535 then
      AMarker := bjmUInt16
    else if maxv <= 2147483647 then
      AMarker := bjmInt32
    else if maxv <= 4294967295 then
      AMarker := bjmUInt32
    else
      AMarker := bjmInt64;
  end
  else if (minv >= -128) and (maxv <= 127) then
    AMarker := bjmInt8
  else if (minv >= -32768) and (maxv <= 32767) then
    AMarker := bjmInt16
  else if (minv >= -2147483648) and (maxv <= 2147483647) then
    AMarker := bjmInt32
  else
    AMarker := bjmInt64;
  Result := True;
end;

const
  BJWriteBufferSize = 64 * 1024;

type
  TBJWriter = class(TObject)
  private
    FStream: TStream;
    FOptions: TBJDataWriteOptions;
    FOut: array[0..BJWriteBufferSize - 1] of Byte;
    FOutLen: Integer;
    procedure Flush;
    procedure W(const ABuffer; ACount: PtrUInt);
    procedure WChar(AMarker: AnsiChar); inline;
    procedure WIntAs(AMarker: AnsiChar; AValue: Int64);
    procedure WFloatAs(AMarker: AnsiChar; AValue: Double);
    procedure WSize(AValue: Int64);
    procedure WText(const AValue: string);
    procedure WDims(const ADims: TBJDataDims);
    procedure WPayload(AMarker: AnsiChar; ANode: TBJData);
    procedure WPacked(ANode: TBJData);
    procedure WArray(ANode: TBJData);
    procedure WObject(ANode: TBJData);
    function TryWriteSoA(ANode: TBJData): Boolean;
    procedure WSchema(const ASchema: TBJSoAFieldArray);
    procedure WFieldSpec(AField: TBJSoAField);
    procedure WSoAValue(AField: TBJSoAField; ANode: TBJData);
  public
    constructor Create(AStream: TStream; AOptions: TBJDataWriteOptions);
    destructor Destroy; override;
    procedure WValue(ANode: TBJData);
  end;

constructor TBJWriter.Create(AStream: TStream; AOptions: TBJDataWriteOptions);
begin
  inherited Create;
  FStream := AStream;
  FOptions := AOptions;
end;

destructor TBJWriter.Destroy;
begin
  Flush;
  inherited Destroy;
end;

procedure TBJWriter.Flush;
begin
  if FOutLen > 0 then
  begin
    FStream.WriteBuffer(FOut[0], FOutLen);
    FOutLen := 0;
  end;
end;

{ output goes through a fixed buffer: a BJData stream is written in very small
  pieces, and one stream call per marker byte dominates everything else }
procedure TBJWriter.W(const ABuffer; ACount: PtrUInt);
begin
  if ACount = 0 then
    Exit;
  if FOutLen + ACount > BJWriteBufferSize then
  begin
    Flush;
    if ACount >= BJWriteBufferSize then
    begin
      FStream.WriteBuffer(ABuffer, ACount);
      Exit;
    end;
  end;
  Move(ABuffer, FOut[FOutLen], ACount);
  Inc(FOutLen, ACount);
end;

procedure TBJWriter.WChar(AMarker: AnsiChar);
begin
  if FOutLen >= BJWriteBufferSize then
    Flush;
  FOut[FOutLen] := Byte(AMarker);
  Inc(FOutLen);
end;

procedure TBJWriter.WIntAs(AMarker: AnsiChar; AValue: Int64);
var
  v8: Byte;
  v16: Word;
  v32: LongWord;
  v64: Int64;
begin
  case BJMarkerSize(AMarker) of
    1:
      begin
        v8 := Byte(AValue);
        W(v8, 1);
      end;
    2:
      begin
        v16 := Word(AValue);
        BJFromLE(@v16, 2, 1);
        W(v16, 2);
      end;
    4:
      begin
        v32 := LongWord(AValue);
        BJFromLE(@v32, 4, 1);
        W(v32, 4);
      end;
    8:
      begin
        v64 := AValue;
        BJFromLE(@v64, 8, 1);
        W(v64, 8);
      end;
  else
    raise EBJData.CreateFmt('"%s" is not an integer marker', [AMarker]);
  end;
end;

procedure TBJWriter.WFloatAs(AMarker: AnsiChar; AValue: Double);
var
  v16: Word;
  v32: Single;
  v64: Double;
begin
  case AMarker of
    bjmFloat16:
      begin
        v16 := BJDoubleToHalf(AValue);
        BJFromLE(@v16, 2, 1);
        W(v16, 2);
      end;
    bjmFloat32:
      begin
        v32 := AValue;
        BJFromLE(@v32, 4, 1);
        W(v32, 4);
      end;
    bjmFloat64:
      begin
        v64 := AValue;
        BJFromLE(@v64, 8, 1);
        W(v64, 8);
      end;
  else
    raise EBJData.CreateFmt('"%s" is not a float marker', [AMarker]);
  end;
end;

{ write a length or count using the smallest possible integer type }
procedure TBJWriter.WSize(AValue: Int64);
var
  m: AnsiChar;
begin
  if AValue < 0 then
    raise EBJData.Create('a negative length or count cannot be written');
  m := BJIntMarkerFor(AValue);
  WChar(m);
  WIntAs(m, AValue);
end;

{ write a string body: length marker, length and the raw bytes }
procedure TBJWriter.WText(const AValue: string);
begin
  WSize(Length(AValue));
  if Length(AValue) > 0 then
    W(AValue[1], Length(AValue));
end;

{ write an optimized 1-D integer array holding the dimensions }
procedure TBJWriter.WDims(const ADims: TBJDataDims);
var
  i: Integer;
  m: AnsiChar;
  maxd: Int64;
begin
  maxd := 0;
  for i := 0 to High(ADims) do
    if ADims[i] > maxd then
      maxd := ADims[i];
  m := BJIntMarkerFor(maxd);
  WChar(bjmArrayStart);
  WChar(bjmTypeMark);
  WChar(m);
  WChar(bjmCountMark);
  WSize(Length(ADims));
  for i := 0 to High(ADims) do
    WIntAs(m, ADims[i]);
end;

{ write the raw payload of a scalar node using the given marker }
procedure TBJWriter.WPayload(AMarker: AnsiChar; ANode: TBJData);
var
  s: string;
begin
  if BJIsFloatMarker(AMarker) then
    WFloatAs(AMarker, ANode.AsDouble)
  else if AMarker = bjmChar then
  begin
    s := ANode.AsString;
    if s = '' then
      WChar(#0)
    else
      WChar(s[1]);
  end
  else
    WIntAs(AMarker, ANode.AsInt64);
end;

procedure TBJWriter.WPacked(ANode: TBJData);
var
  n: Int64;
{$IFDEF ENDIAN_BIG}
  tmp: TBytes;
{$ENDIF}
begin
  n := ANode.ElementCount;
  WChar(bjmArrayStart);
  WChar(bjmTypeMark);
  WChar(ANode.Marker);
  WChar(bjmCountMark);
  if Length(ANode.FDims) <= 1 then
    WSize(n)
  else if ANode.ColumnMajor then
  begin
    WChar(bjmArrayStart);
    WDims(ANode.FDims);
    WChar(bjmArrayEnd);
  end
  else
    WDims(ANode.FDims);
  if Length(ANode.FBin) > 0 then
  begin
{$IFDEF ENDIAN_BIG}
    tmp := Copy(ANode.FBin, 0, Length(ANode.FBin));
    BJFromLE(@tmp[0], BJMarkerSize(ANode.Marker), n);
    W(tmp[0], Length(tmp));
{$ELSE}
    W(ANode.FBin[0], Length(ANode.FBin));
{$ENDIF}
  end;
end;

procedure TBJWriter.WArray(ANode: TBJData);
var
  i: SizeInt;
  m: AnsiChar;
begin
  if (bjwSoA in FOptions) and TryWriteSoA(ANode) then
    Exit;
  WChar(bjmArrayStart);
  if (bjwType in FOptions) and (ANode.Count > 0) and
     BJCommonMarker(ANode.FItems, ANode.Count, m) then
  begin
    WChar(bjmTypeMark);
    WChar(m);
    WChar(bjmCountMark);
    if Length(ANode.FDims) > 1 then
    begin
      if ANode.ColumnMajor then
      begin
        WChar(bjmArrayStart);
        WDims(ANode.FDims);
        WChar(bjmArrayEnd);
      end
      else
        WDims(ANode.FDims);
    end
    else
      WSize(ANode.Count);
    for i := 0 to ANode.Count - 1 do
      WPayload(m, ANode.FItems[i]);
    Exit;
  end;
  if bjwCount in FOptions then
  begin
    WChar(bjmCountMark);
    WSize(ANode.Count);
    for i := 0 to ANode.Count - 1 do
      WValue(ANode.FItems[i]);
    Exit;
  end;
  for i := 0 to ANode.Count - 1 do
    WValue(ANode.FItems[i]);
  WChar(bjmArrayEnd);
end;

procedure TBJWriter.WObject(ANode: TBJData);
var
  i: SizeInt;
begin
  if (bjwSoA in FOptions) and TryWriteSoA(ANode) then
    Exit;
  WChar(bjmObjectStart);
  if bjwCount in FOptions then
  begin
    WChar(bjmCountMark);
    WSize(ANode.Count);
    for i := 0 to ANode.Count - 1 do
    begin
      WText(ANode.Names[i]);
      WValue(ANode.FItems[i]);
    end;
    Exit;
  end;
  for i := 0 to ANode.Count - 1 do
  begin
    WText(ANode.Names[i]);
    WValue(ANode.FItems[i]);
  end;
  WChar(bjmObjectEnd);
end;

procedure TBJWriter.WValue(ANode: TBJData);
begin
  if ANode = nil then
  begin
    WChar(bjmNull);
    Exit;
  end;
  case ANode.Kind of
    bjkNull:
      WChar(bjmNull);
    bjkNoOp:
      WChar(bjmNoOp);
    bjkBoolean:
      if ANode.AsBoolean then
        WChar(bjmTrue)
      else
        WChar(bjmFalse);
    bjkInt, bjkUInt:
      begin
        WChar(ANode.Marker);
        WIntAs(ANode.Marker, ANode.FInt);
      end;
    bjkFloat:
      begin
        WChar(ANode.Marker);
        WFloatAs(ANode.Marker, ANode.FFloat);
      end;
    bjkString:
      case ANode.Marker of
        bjmChar:
          begin
            WChar(bjmChar);
            if ANode.FStr = '' then
              WChar(#0)
            else
              WChar(ANode.FStr[1]);
          end;
        bjmHighPrec:
          begin
            WChar(bjmHighPrec);
            WText(ANode.FStr);
          end;
      else
        begin
          WChar(bjmString);
          WText(ANode.FStr);
        end;
      end;
    bjkTypedArray:
      WPacked(ANode);
    bjkExtension:
      begin
        WChar(bjmExtension);
        WSize(ANode.FInt);
        WSize(Length(ANode.FBin));
        if Length(ANode.FBin) > 0 then
          W(ANode.FBin[0], Length(ANode.FBin));
      end;
    bjkArray:
      WArray(ANode);
    bjkObject:
      WObject(ANode);
  end;
end;

{------------------------------------------------------------------------------
  Structure-of-Arrays (SoA) encoding
------------------------------------------------------------------------------}

{ derive the schema entry describing one column of ACount values; returns nil
  when the values cannot be stored in a packed SoA column }
function BJInferColumn(const AValues: TBJDataItems; ACount: Int64): TBJSoAField;
var
  i, j, k: Int64;
  v: TBJData;
  m: AnsiChar;
  allnull, allbool, allstr, allarr, allobj, ishp, samelen: Boolean;
  sublen: SizeInt;
  slen: SizeInt;
  total: Int64;
  uniq: TBJDataNames;
  nuniq: Integer;
  found: Boolean;
  sub: TBJDataItems;
  fld: TBJSoAField;
begin
  Result := nil;
  if ACount <= 0 then
    Exit;
  allnull := True;
  allbool := True;
  allstr := True;
  allarr := True;
  allobj := True;
  ishp := AValues[0].IsHighPrec;
  for i := 0 to ACount - 1 do
  begin
    v := AValues[i];
    if v = nil then
      Exit;
    allnull := allnull and (v.Kind = bjkNull);
    allbool := allbool and (v.Kind = bjkBoolean);
    allstr := allstr and (v.Kind = bjkString) and (v.Marker <> bjmChar) and
              (v.IsHighPrec = ishp);
    allarr := allarr and (v.Kind = bjkArray);
    allobj := allobj and (v.Kind = bjkObject);
  end;

  if allnull then
  begin
    Result := TBJSoAField.Create;
    Result.Kind := skNull;
    Exit;
  end;

  if allbool then
  begin
    Result := TBJSoAField.Create;
    Result.Kind := skBool;
    Exit;
  end;

  if BJCommonMarker(AValues, ACount, m) then
  begin
    Result := TBJSoAField.Create;
    Result.Kind := skFixed;
    Result.Marker := m;
    Exit;
  end;

  if allstr then
  begin
    samelen := True;
    total := 0;
    slen := Length(AValues[0].AsString);
    nuniq := 0;
    SetLength(uniq, 256);
    for i := 0 to ACount - 1 do
    begin
      k := Length(AValues[i].AsString);
      total := total + k;
      samelen := samelen and (k = slen);
      if nuniq >= 0 then
      begin
        found := False;
        for j := 0 to nuniq - 1 do
          if uniq[j] = AValues[i].AsString then
          begin
            found := True;
            Break;
          end;
        if not found then
        begin
          if nuniq >= 255 then
            nuniq := -1
          else
          begin
            uniq[nuniq] := AValues[i].AsString;
            Inc(nuniq);
          end;
        end;
      end;
    end;
    Result := TBJSoAField.Create;
    Result.IsHighPrec := ishp;
    if samelen and (slen > 0) and (slen <= 65535) then
    begin
      Result.Kind := skStrFixed;
      Result.Len := slen;
    end
    else if (nuniq > 0) and (nuniq * 2 <= ACount) then
    begin
      Result.Kind := skStrDict;
      SetLength(Result.Dict, nuniq);
      for j := 0 to nuniq - 1 do
        Result.Dict[j] := uniq[j];
      Result.IdxMarker := BJIndexMarkerFor(nuniq);
    end
    else
    begin
      Result.Kind := skStrOffset;
      Result.IdxMarker := BJIntMarkerFor(Max(total, ACount));
      if Result.IdxMarker = bjmInt8 then
        Result.IdxMarker := bjmUInt8;
    end;
    Exit;
  end;

  if allarr then
  begin
    sublen := AValues[0].Count;
    if sublen = 0 then
      Exit;
    for i := 1 to ACount - 1 do
      if AValues[i].Count <> sublen then
        Exit;
    Result := TBJSoAField.Create;
    Result.Kind := skArray;
    SetLength(Result.Fields, sublen);
    SetLength(sub, ACount);
    for k := 0 to sublen - 1 do
    begin
      for i := 0 to ACount - 1 do
        sub[i] := AValues[i].Items[k];
      fld := BJInferColumn(sub, ACount);
      if fld = nil then
      begin
        Result.Free;
        Exit(nil);
      end;
      Result.Fields[k] := fld;
    end;
    Exit;
  end;

  if allobj then
  begin
    sublen := AValues[0].Count;
    if sublen = 0 then
      Exit;
    for i := 1 to ACount - 1 do
    begin
      if AValues[i].Count <> sublen then
        Exit;
      for k := 0 to sublen - 1 do
        if AValues[i].Names[k] <> AValues[0].Names[k] then
          Exit;
    end;
    Result := TBJSoAField.Create;
    Result.Kind := skObject;
    SetLength(Result.Fields, sublen);
    SetLength(sub, ACount);
    for k := 0 to sublen - 1 do
    begin
      for i := 0 to ACount - 1 do
        sub[i] := AValues[i].Items[k];
      fld := BJInferColumn(sub, ACount);
      if fld = nil then
      begin
        Result.Free;
        Exit(nil);
      end;
      fld.Name := AValues[0].Names[k];
      Result.Fields[k] := fld;
    end;
  end;
end;

procedure TBJWriter.WFieldSpec(AField: TBJSoAField);
var
  i: Integer;
begin
  case AField.Kind of
    skFixed:
      WChar(AField.Marker);
    skBool:
      WChar(bjmTrue);
    skNull:
      WChar(bjmNull);
    skStrFixed:
      begin
        if AField.IsHighPrec then
          WChar(bjmHighPrec)
        else
          WChar(bjmString);
        WSize(AField.Len);
      end;
    skStrDict:
      begin
        WChar(bjmArrayStart);
        WChar(bjmTypeMark);
        if AField.IsHighPrec then
          WChar(bjmHighPrec)
        else
          WChar(bjmString);
        WChar(bjmCountMark);
        WSize(Length(AField.Dict));
        for i := 0 to High(AField.Dict) do
          WText(AField.Dict[i]);
      end;
    skStrOffset:
      begin
        WChar(bjmArrayStart);
        WChar(bjmTypeMark);
        WChar(AField.IdxMarker);
        WChar(bjmArrayEnd);
      end;
    skArray:
      begin
        WChar(bjmArrayStart);
        for i := 0 to High(AField.Fields) do
          WFieldSpec(AField.Fields[i]);
        WChar(bjmArrayEnd);
      end;
    skObject:
      begin
        WChar(bjmObjectStart);
        for i := 0 to High(AField.Fields) do
        begin
          WText(AField.Fields[i].Name);
          WFieldSpec(AField.Fields[i]);
        end;
        WChar(bjmObjectEnd);
      end;
  end;
end;

procedure TBJWriter.WSchema(const ASchema: TBJSoAFieldArray);
var
  i: Integer;
begin
  WChar(bjmObjectStart);
  for i := 0 to High(ASchema) do
  begin
    WText(ASchema[i].Name);
    WFieldSpec(ASchema[i]);
  end;
  WChar(bjmObjectEnd);
end;

procedure TBJWriter.WSoAValue(AField: TBJSoAField; ANode: TBJData);
var
  i, idx: Integer;
  s: string;
  sub: TBJData;
begin
  case AField.Kind of
    skFixed:
      WPayload(AField.Marker, ANode);
    skBool:
      if (ANode <> nil) and ANode.AsBoolean then
        WChar(bjmTrue)
      else
        WChar(bjmFalse);
    skNull:
      ;
    skStrFixed:
      begin
        s := '';
        if ANode <> nil then
          s := ANode.AsString;
        if Length(s) > AField.Len then
          SetLength(s, AField.Len)
        else
          s := s + StringOfChar(#0, AField.Len - Length(s));
        if AField.Len > 0 then
          W(s[1], AField.Len);
      end;
    skStrDict:
      begin
        s := '';
        if ANode <> nil then
          s := ANode.AsString;
        idx := 0;
        for i := 0 to High(AField.Dict) do
          if AField.Dict[i] = s then
          begin
            idx := i;
            Break;
          end;
        WIntAs(AField.IdxMarker, idx);
      end;
    skStrOffset:
      begin
        WIntAs(AField.IdxMarker, AField.NodeCount);
        AField.AddPending(ANode, AField.NodeCount);
      end;
    skArray:
      for i := 0 to High(AField.Fields) do
      begin
        sub := nil;
        if (ANode <> nil) and (i < ANode.Count) then
          sub := ANode.Items[i];
        WSoAValue(AField.Fields[i], sub);
      end;
    skObject:
      for i := 0 to High(AField.Fields) do
      begin
        sub := nil;
        if ANode <> nil then
          sub := ANode.Values[AField.Fields[i].Name];
        WSoAValue(AField.Fields[i], sub);
      end;
  end;
end;

function TBJWriter.TryWriteSoA(ANode: TBJData): Boolean;
var
  rowmajor: Boolean;
  count: Int64;
  nf, fi, k: Integer;
  ri: Int64;
  names: TBJDataNames;
  cols: array of TBJDataItems;
  schema, offlist: TBJSoAFieldArray;
  rec: TBJData;
  offset: Int64;
begin
  Result := False;
  SetLength(schema, 0);
  if ANode.Kind = bjkArray then
  begin
    count := ANode.Count;
    if (count = 0) or (ANode.Items[0].Kind <> bjkObject) then
      Exit;
    nf := ANode.Items[0].Count;
    if nf = 0 then
      Exit;
    rowmajor := not (ANode.ColumnMajor or (bjwColumnMajor in FOptions));
    SetLength(names, nf);
    for fi := 0 to nf - 1 do
      names[fi] := ANode.Items[0].Names[fi];
    SetLength(cols, nf);
    for fi := 0 to nf - 1 do
      SetLength(cols[fi], count);
    for ri := 0 to count - 1 do
    begin
      rec := ANode.Items[ri];
      if (rec.Kind <> bjkObject) or (rec.Count <> nf) then
        Exit;
      for fi := 0 to nf - 1 do
      begin
        if rec.Names[fi] <> names[fi] then
          Exit;
        cols[fi][ri] := rec.Items[fi];
      end;
    end;
  end
  else if ANode.Kind = bjkObject then
  begin
    // an object of equal-length arrays is only stored as a column-major SoA
    // record when it is explicitly marked as one: an object holding one array
    // and a table of records holding one field are different documents
    if not ANode.FromSoA then
      Exit;
    rowmajor := False;
    nf := ANode.Count;
    if nf = 0 then
      Exit;
    if ANode.Items[0].Kind <> bjkArray then
      Exit;
    count := ANode.Items[0].Count;
    if count = 0 then
      Exit;
    SetLength(names, nf);
    SetLength(cols, nf);
    for fi := 0 to nf - 1 do
    begin
      if (ANode.Items[fi].Kind <> bjkArray) or (ANode.Items[fi].Count <> count) then
        Exit;
      names[fi] := ANode.Names[fi];
      SetLength(cols[fi], count);
      for ri := 0 to count - 1 do
        cols[fi][ri] := ANode.Items[fi].Items[ri];
    end;
  end
  else
    Exit;

  SetLength(schema, nf);
  try
    for fi := 0 to nf - 1 do
    begin
      schema[fi] := BJInferColumn(cols[fi], count);
      if schema[fi] = nil then
        Exit;
      schema[fi].Name := names[fi];
    end;

    if rowmajor then
      WChar(bjmArrayStart)
    else
      WChar(bjmObjectStart);
    WChar(bjmTypeMark);
    WSchema(schema);
    WChar(bjmCountMark);
    if (Length(ANode.FDims) > 1) and (BJDimProduct(ANode.FDims) = count) then
      WDims(ANode.FDims)
    else
      WSize(count);

    if rowmajor then
    begin
      for ri := 0 to count - 1 do
        for fi := 0 to nf - 1 do
          WSoAValue(schema[fi], cols[fi][ri]);
    end
    else
    begin
      for fi := 0 to nf - 1 do
        for ri := 0 to count - 1 do
          WSoAValue(schema[fi], cols[fi][ri]);
    end;

    SetLength(offlist, 0);
    BJCollectOffsetFields(schema, offlist);
    for k := 0 to High(offlist) do
    begin
      offset := 0;
      for fi := 0 to offlist[k].NodeCount - 1 do
      begin
        WIntAs(offlist[k].IdxMarker, offset);
        if offlist[k].Nodes[fi] <> nil then
          offset := offset + Length(offlist[k].Nodes[fi].AsString);
      end;
      WIntAs(offlist[k].IdxMarker, offset);
      for fi := 0 to offlist[k].NodeCount - 1 do
        if offlist[k].Nodes[fi] <> nil then
          if Length(offlist[k].Nodes[fi].FStr) > 0 then
            W(offlist[k].Nodes[fi].FStr[1], Length(offlist[k].Nodes[fi].FStr));
    end;
    Result := True;
  finally
    BJFreeSchema(schema);
  end;
end;

{==============================================================================
  TBJValue / TBJIterator - lazy views over a buffer
==============================================================================}

const
  BJMaxViewDims = 16;

function TBJValue.PayloadPtr: PByte;
begin
  if FImplied <> #0 then
    Result := FPos
  else
    Result := FPos + 1;
end;

{ position of the first child, with the element type and the promised child
  count of an optimized container (-1 when the container ends with a marker) }
function TBJValue.ContainerBody(out AElem: AnsiChar; out ACount: Int64): PByte;
var
  p: PByte;
  m: AnsiChar;
  ndim: Integer;
  colmajor: Boolean;
begin
  AElem := #0;
  ACount := -1;
  m := Marker;
  if (m <> bjmArrayStart) and (m <> bjmObjectStart) then
    raise EBJData.CreateFmt('a %s is not a container', [BJKindName(Kind)]);
  p := FPos + 1;
  BJNeed(p, FEnd, 1);
  if AnsiChar(p^) = bjmTypeMark then
  begin
    Inc(p);
    BJNeed(p, FEnd, 1);
    AElem := AnsiChar(p^);
    Inc(p);
    if AElem = bjmObjectStart then
      raise EBJData.Create('a structure-of-arrays record cannot be browsed ' +
        'element by element, use ToData');
    BJNeed(p, FEnd, 1);
    if AnsiChar(p^) <> bjmCountMark then
      BJWalkError('an optimized container needs a count');
    Inc(p);
    ACount := BJWalkCount(p, FEnd, nil, ndim, colmajor);
  end
  else if AnsiChar(p^) = bjmCountMark then
  begin
    Inc(p);
    ACount := BJWalkCount(p, FEnd, nil, ndim, colmajor);
  end;
  Result := p;
end;

class function TBJValue.Create(ABuffer: PByte; ASize: PtrUInt): TBJValue;
begin
  Result.FPos := ABuffer;
  Result.FEnd := ABuffer + ASize;
  Result.FImplied := #0;
  while (Result.FPos < Result.FEnd) and (AnsiChar(Result.FPos^) = bjmNoOp) do
    Inc(Result.FPos);
end;

class function TBJValue.FromBytes(const ABuffer: TBytes): TBJValue;
begin
  if Length(ABuffer) = 0 then
    raise EBJData.Create('cannot view an empty buffer');
  Result := TBJValue.Create(@ABuffer[0], Length(ABuffer));
end;

function TBJValue.IsValid: Boolean;
begin
  Result := (FPos <> nil) and (FPos < FEnd);
end;

function TBJValue.Marker: AnsiChar;
begin
  if FImplied <> #0 then
    Result := FImplied
  else
  begin
    if not IsValid then
      raise EBJData.Create('this view does not point at a value');
    Result := AnsiChar(FPos^);
  end;
end;

function TBJValue.Kind: TBJDataKind;
begin
  if IsPacked then
    Result := bjkTypedArray
  else
    Result := BJKindOf(Marker);
end;

function TBJValue.IsNull: Boolean;
begin
  Result := IsValid and (Marker = bjmNull);
end;

function TBJValue.IsNumber: Boolean;
begin
  Result := IsValid and (BJKindOf(Marker) in [bjkInt, bjkUInt, bjkFloat]);
end;

function TBJValue.IsContainer: Boolean;
begin
  Result := IsValid and (FImplied = #0) and
            (AnsiChar(FPos^) in [bjmArrayStart, bjmObjectStart]);
end;

function TBJValue.IsPacked: Boolean;
begin
  Result := False;
  if (FImplied <> #0) or not IsValid or (AnsiChar(FPos^) <> bjmArrayStart) then
    Exit;
  if (FPos + 2 < FEnd) and (AnsiChar((FPos + 1)^) = bjmTypeMark) then
    Result := BJIsFixedMarker(AnsiChar((FPos + 2)^));
end;

function TBJValue.IsSoA: Boolean;
begin
  Result := False;
  if (FImplied <> #0) or not IsValid then
    Exit;
  if not (AnsiChar(FPos^) in [bjmArrayStart, bjmObjectStart]) then
    Exit;
  if (FPos + 2 < FEnd) and (AnsiChar((FPos + 1)^) = bjmTypeMark) then
    Result := AnsiChar((FPos + 2)^) = bjmObjectStart;
end;

function TBJValue.AsInt64: Int64;
var
  m: AnsiChar;
  p: PByte;
begin
  m := Marker;
  p := PayloadPtr;
  case m of
    bjmTrue:
      Result := 1;
    bjmFalse, bjmNull, bjmNoOp:
      Result := 0;
    bjmChar:
      Result := p^;
    bjmString, bjmHighPrec:
      Result := StrToInt64Def(Trim(AsString), 0);
    bjmFloat16, bjmFloat32, bjmFloat64:
      Result := Round(AsDouble);
  else
    Result := BJWalkInt(p, FEnd, m);
  end;
end;

function TBJValue.AsQWord: QWord;
begin
  Result := QWord(AsInt64);
end;

function TBJValue.AsDouble: Double;
var
  m: AnsiChar;
  p: PByte;
  w: Word;
  f: Single;
  d: Double;
begin
  m := Marker;
  p := PayloadPtr;
  case m of
    bjmFloat16:
      begin
        BJNeed(p, FEnd, 2);
        Move(p^, w, 2);
        BJFromLE(@w, 2, 1);
        Result := BJHalfToDouble(w);
      end;
    bjmFloat32:
      begin
        BJNeed(p, FEnd, 4);
        Move(p^, f, 4);
        BJFromLE(@f, 4, 1);
        Result := f;
      end;
    bjmFloat64:
      begin
        BJNeed(p, FEnd, 8);
        Move(p^, d, 8);
        BJFromLE(@d, 8, 1);
        Result := d;
      end;
    bjmUInt64:
      Result := QWord(BJWalkInt(p, FEnd, m));
    bjmString, bjmHighPrec:
      Result := StrToFloatDef(Trim(AsString), 0.0, BJFormat);
  else
    Result := AsInt64;
  end;
end;

function TBJValue.AsBoolean: Boolean;
var
  m: AnsiChar;
begin
  m := Marker;
  case m of
    bjmTrue:
      Result := True;
    bjmFalse, bjmNull, bjmNoOp:
      Result := False;
    bjmString, bjmHighPrec:
      Result := (TextLength > 0) and (LowerCase(AsString) <> 'false');
    bjmChar:
      Result := True;
    bjmFloat16, bjmFloat32, bjmFloat64:
      Result := AsDouble <> 0;
  else
    Result := AsInt64 <> 0;
  end;
end;

function TBJValue.TextLength: SizeInt;
var
  m: AnsiChar;
  p: PByte;
begin
  m := Marker;
  if m = bjmChar then
    Exit(1);
  if (m <> bjmString) and (m <> bjmHighPrec) then
    Exit(0);
  p := PayloadPtr;
  Result := BJWalkSize(p, FEnd);
end;

function TBJValue.TextPtr: PAnsiChar;
var
  m: AnsiChar;
  p: PByte;
begin
  m := Marker;
  p := PayloadPtr;
  if (m = bjmString) or (m = bjmHighPrec) then
    BJWalkSize(p, FEnd)
  else if m <> bjmChar then
    Exit(nil);
  Result := PAnsiChar(p);
end;

function TBJValue.TextEquals(const AText: string): Boolean;
var
  m: AnsiChar;
  p: PByte;
  n: SizeInt;
begin
  Result := False;
  m := Marker;
  p := PayloadPtr;
  if (m = bjmString) or (m = bjmHighPrec) then
    n := BJWalkSize(p, FEnd)
  else if m = bjmChar then
    n := 1
  else
    Exit;
  if n <> Length(AText) then
    Exit;
  Result := (n = 0) or CompareMem(p, PAnsiChar(AText), n);
end;

function TBJValue.AsString: string;
var
  m: AnsiChar;
  p: PByte;
  n: SizeInt;
begin
  m := Marker;
  p := PayloadPtr;
  case m of
    bjmString, bjmHighPrec:
      begin
        n := BJWalkSize(p, FEnd);
        BJNeed(p, FEnd, n);
        SetString(Result, PAnsiChar(p), n);
      end;
    bjmChar:
      begin
        BJNeed(p, FEnd, 1);
        Result := AnsiChar(p^);
      end;
    bjmTrue:
      Result := 'true';
    bjmFalse:
      Result := 'false';
    bjmNull:
      Result := 'null';
    bjmNoOp:
      Result := '';
    bjmFloat16, bjmFloat32, bjmFloat64:
      Result := BJFloatToStr(AsDouble);
    bjmUInt64:
      Result := UIntToStr(AsQWord);
    bjmArrayStart, bjmObjectStart:
      Result := ToJSON(0);
  else
    Result := IntToStr(AsInt64);
  end;
end;

function TBJValue.Size: PtrUInt;
var
  p: PByte;
begin
  if FImplied <> #0 then
  begin
    p := FPos;
    BJWalkTyped(p, FEnd, FImplied);
    Result := p - FPos;
  end
  else
    Result := BJSkipValue(FPos, FEnd) - FPos;
end;

function TBJValueEnumerator.GetEnumerator: TBJIterator;
begin
  Result.FNext := Self.ContainerBody(Result.FElem, Result.FLeft);
  Result.FEnd := Self.FEnd;
  Result.FIsObject := Self.Marker = bjmObjectStart;
  Result.FKeyPtr := nil;
  Result.FKeyLen := 0;
  Result.FCurrent.FPos := nil;
  Result.FCurrent.FEnd := Self.FEnd;
  Result.FCurrent.FImplied := #0;
end;

function TBJIterator.MoveNext: Boolean;
begin
  Result := False;
  if (FLeft = 0) or (FNext = nil) then
    Exit;
  if FLeft < 0 then
  begin
    while (FNext < FEnd) and (AnsiChar(FNext^) = bjmNoOp) do
      Inc(FNext);
    if FNext >= FEnd then
      Exit;
    if FIsObject then
    begin
      if AnsiChar(FNext^) = bjmObjectEnd then
      begin
        Inc(FNext);
        FLeft := 0;
        Exit;
      end;
    end
    else if AnsiChar(FNext^) = bjmArrayEnd then
    begin
      Inc(FNext);
      FLeft := 0;
      Exit;
    end;
  end
  else if FNext >= FEnd then
    Exit;
  if FIsObject then
  begin
    FKeyLen := BJWalkSize(FNext, FEnd);
    BJNeed(FNext, FEnd, FKeyLen);
    FKeyPtr := FNext;
    Inc(FNext, FKeyLen);
  end;
  FCurrent.FPos := FNext;
  if FElem <> #0 then
  begin
    FCurrent.FImplied := FElem;
    BJWalkTyped(FNext, FEnd, FElem);
  end
  else
  begin
    FCurrent.FImplied := #0;
    FNext := BJSkipValue(FNext, FEnd);
  end;
  if FLeft > 0 then
    Dec(FLeft);
  Result := True;
end;

function TBJIterator.Key: string;
begin
  SetString(Result, PAnsiChar(FKeyPtr), FKeyLen);
end;

function TBJIterator.KeyPtr: PAnsiChar;
begin
  Result := PAnsiChar(FKeyPtr);
end;

function TBJIterator.KeyLength: SizeInt;
begin
  Result := FKeyLen;
end;

function TBJIterator.KeyEquals(const AKey: string): Boolean;
begin
  Result := (FKeyLen = Length(AKey)) and
            ((FKeyLen = 0) or CompareMem(FKeyPtr, PAnsiChar(AKey), FKeyLen));
end;

function TBJValue.Count: SizeInt;
var
  elem: AnsiChar;
  n: Int64;
  it: TBJIterator;
begin
  if IsPacked then
    Exit(ElementCount);
  ContainerBody(elem, n);
  if n >= 0 then
    Exit(n);
  Result := 0;
  it := Self.GetEnumerator;
  while it.MoveNext do
    Inc(Result);
end;

function TBJValue.Item(AIndex: SizeInt): TBJValue;
var
  elem: AnsiChar;
  n: Int64;
  body: PByte;
  i: SizeInt;
  it: TBJIterator;
begin
  Result.FPos := nil;
  Result.FEnd := FEnd;
  Result.FImplied := #0;
  if AIndex < 0 then
    Exit;
  body := ContainerBody(elem, n);
  if (n >= 0) and (AIndex >= n) then
    Exit;
  if (elem <> #0) and BJIsFixedMarker(elem) then
  begin                                        { packed: constant time }
    Result.FPos := body + AIndex * BJMarkerSize(elem);
    Result.FImplied := elem;
    if Result.FPos >= FEnd then
      Result.FPos := nil;
    Exit;
  end;
  i := 0;
  it := Self.GetEnumerator;
  while it.MoveNext do
  begin
    if i = AIndex then
      Exit(it.Current);
    Inc(i);
  end;
end;

function TBJValue.Find(const AKey: string): TBJValue;
begin
  Result := FindKey(PAnsiChar(AKey), Length(AKey));
end;

{ look a key up without needing it as a string, so that a path can be walked
  without allocating one token per segment }
function TBJValue.FindKey(AKey: PAnsiChar; ALength: SizeInt): TBJValue;
var
  it: TBJIterator;
begin
  Result.FPos := nil;
  Result.FEnd := FEnd;
  Result.FImplied := #0;
  if not IsValid or (FImplied <> #0) or (AnsiChar(FPos^) <> bjmObjectStart) then
    Exit;
  it := Self.GetEnumerator;
  while it.MoveNext do
    if (it.FKeyLen = ALength) and
       ((ALength = 0) or CompareMem(it.FKeyPtr, AKey, ALength)) then
      Exit(it.Current);
end;

function TBJValue.Path(const APath: string): TBJValue;
var
  i, len, start: Integer;
  idx: Int64;
  node: TBJValue;
  base: PAnsiChar;
begin
  node := Self;
  base := PAnsiChar(APath);
  i := 1;
  len := Length(APath);
  start := 1;
  while (i <= len) and node.IsValid do
  begin
    case APath[i] of
      '.':
        begin
          if i > start then
            node := node.FindKey(base + start - 1, i - start);
          Inc(i);
          start := i;
        end;
      '[':
        begin
          if i > start then
            node := node.FindKey(base + start - 1, i - start);
          Inc(i);
          idx := 0;
          while (i <= len) and (APath[i] <> ']') do
          begin
            if (APath[i] >= '0') and (APath[i] <= '9') then
              idx := idx * 10 + (Ord(APath[i]) - Ord('0'))
            else
              idx := -1;
            Inc(i);
          end;
          if i <= len then
            Inc(i);
          start := i;
          if node.IsValid then
            node := node.Item(idx);
        end;
    else
      Inc(i);
    end;
  end;
  if node.IsValid and (len >= start) then
    node := node.FindKey(base + start - 1, len - start + 1);
  Result := node;
end;

function TBJValue.ElemMarker: AnsiChar;
var
  n: Int64;
begin
  ContainerBody(Result, n);
end;

function TBJValue.ElementCount: Int64;
var
  elem: AnsiChar;
begin
  ContainerBody(elem, Result);
  if Result < 0 then
    Result := Count;
end;

function TBJValue.DimCount: Integer;
var
  dims: TBJDataDims;
  colmajor: Boolean;
  p: PByte;
  elem: AnsiChar;
begin
  Result := 0;
  if not IsContainer then
    Exit;
  p := FPos + 1;
  BJNeed(p, FEnd, 1);
  if AnsiChar(p^) = bjmTypeMark then
  begin
    Inc(p);
    elem := AnsiChar(p^);
    Inc(p);
    if elem = bjmObjectStart then
      Exit;
    Inc(p);                                    { the '#' }
  end
  else if AnsiChar(p^) = bjmCountMark then
    Inc(p)
  else
    Exit;
  SetLength(dims, BJMaxViewDims);
  BJWalkCount(p, FEnd, dims, Result, colmajor);
end;

function TBJValue.Dim(AIndex: Integer): Int64;
var
  dims: TBJDataDims;
  colmajor: Boolean;
  p: PByte;
  elem: AnsiChar;
  ndim: Integer;
begin
  Result := 0;
  if not IsContainer then
    Exit;
  p := FPos + 1;
  BJNeed(p, FEnd, 1);
  if AnsiChar(p^) = bjmTypeMark then
  begin
    Inc(p);
    elem := AnsiChar(p^);
    Inc(p);
    if elem = bjmObjectStart then
      Exit;
    Inc(p);
  end
  else if AnsiChar(p^) = bjmCountMark then
    Inc(p)
  else
    Exit;
  SetLength(dims, BJMaxViewDims);
  BJWalkCount(p, FEnd, dims, ndim, colmajor);
  if (AIndex >= 0) and (AIndex < ndim) and (AIndex < BJMaxViewDims) then
    Result := dims[AIndex];
end;

function TBJValue.ColumnMajor: Boolean;
var
  dims: TBJDataDims;
  p: PByte;
  elem: AnsiChar;
  ndim: Integer;
begin
  Result := False;
  if not IsContainer then
    Exit;
  p := FPos + 1;
  BJNeed(p, FEnd, 1);
  if AnsiChar(p^) = bjmTypeMark then
  begin
    Inc(p);
    elem := AnsiChar(p^);
    Inc(p);
    if elem = bjmObjectStart then
      Exit;
    Inc(p);
  end
  else if AnsiChar(p^) = bjmCountMark then
    Inc(p)
  else
    Exit;
  SetLength(dims, BJMaxViewDims);
  BJWalkCount(p, FEnd, dims, ndim, Result);
end;

{ the packed payload, in the little-endian order of the file }
function TBJValue.DataPtr: Pointer;
var
  elem: AnsiChar;
  n: Int64;
begin
  Result := ContainerBody(elem, n);
  if (elem = #0) or not BJIsFixedMarker(elem) then
    Result := nil;
end;

function TBJValue.DataSize: PtrUInt;
var
  elem: AnsiChar;
  n: Int64;
begin
  Result := 0;
  ContainerBody(elem, n);
  if (elem <> #0) and BJIsFixedMarker(elem) and (n > 0) then
    Result := n * BJMarkerSize(elem);
end;

function TBJValue.ElemAsInt64(AIndex: Int64): Int64;
begin
  Result := Item(AIndex).AsInt64;
end;

function TBJValue.ElemAsDouble(AIndex: Int64): Double;
begin
  Result := Item(AIndex).AsDouble;
end;

function TBJValue.ToData(AOptions: TBJDataParseOptions): TBJData;
var
  rd: TBJReader;
  p: PByte;
begin
  if not IsValid then
    raise EBJData.Create('this view does not point at a value');
  if FImplied <> #0 then
  begin                                        { an element of a typed array }
    p := FPos;
    if BJIsFloatMarker(FImplied) then
      Result := TBJData.NewFloat(AsDouble, FImplied)
    else if FImplied = bjmChar then
      Result := TBJData.NewChar(AnsiChar(p^))
    else if BJIsFixedMarker(FImplied) then
      Result := TBJData.NewInt(AsInt64, FImplied)
    else
    begin
      rd := TBJReader.Create(FPos, FEnd - FPos, AOptions);
      try
        Result := rd.ReadScalar(FImplied);
      finally
        rd.Free;
      end;
    end;
    Exit;
  end;
  rd := TBJReader.Create(FPos, FEnd - FPos, AOptions);
  try
    try
      Result := rd.ReadValue;
    except
      rd.FreePending;
      raise;
    end;
  finally
    rd.Free;
  end;
end;

function TBJValue.ToJSON(AIndent: Integer): string;
var
  doc: TBJData;
begin
  doc := ToData;
  try
    Result := doc.ToJSON(AIndent);
  finally
    doc.Free;
  end;
end;

class function TBJData.View(const ABuffer: TBytes): TBJValue;
begin
  Result := TBJValue.FromBytes(ABuffer);
end;

{==============================================================================
  TBJData - parsing and serialization entry points
==============================================================================}

class function TBJData.Parse(const ABuffer; ALength: PtrUInt;
  AOptions: TBJDataParseOptions): TBJData;
var
  rd: TBJReader;
begin
  rd := TBJReader.Create(PByte(@ABuffer), ALength, AOptions);
  try
    try
      Result := rd.ReadValue;
    except
      rd.FreePending;
      raise;
    end;
  finally
    rd.Free;
  end;
end;

class function TBJData.ParseBytes(const ABuffer: TBytes;
  AOptions: TBJDataParseOptions): TBJData;
begin
  if Length(ABuffer) = 0 then
    raise EBJData.Create('cannot parse an empty buffer');
  Result := Parse(ABuffer[0], Length(ABuffer), AOptions);
end;

class function TBJData.ParseStream(AStream: TStream;
  AOptions: TBJDataParseOptions): TBJData;
var
  buf: TBytes;
  n: Int64;
begin
  n := AStream.Size - AStream.Position;
  SetLength(buf, n);
  if n > 0 then
    AStream.ReadBuffer(buf[0], n);
  Result := ParseBytes(buf, AOptions);
end;

class function TBJData.ParseFile(const AFileName: string;
  AOptions: TBJDataParseOptions): TBJData;
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    Result := ParseStream(fs, AOptions);
  finally
    fs.Free;
  end;
end;

procedure TBJData.SaveToStream(AStream: TStream; AOptions: TBJDataWriteOptions);
var
  wr: TBJWriter;
begin
  wr := TBJWriter.Create(AStream, AOptions);
  try
    wr.WValue(Self);
    wr.Flush;
  finally
    wr.Free;
  end;
end;

procedure TBJData.SaveToFile(const AFileName: string;
  AOptions: TBJDataWriteOptions);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(AFileName, fmCreate);
  try
    SaveToStream(fs, AOptions);
  finally
    fs.Free;
  end;
end;

function TBJData.ToBytes(AOptions: TBJDataWriteOptions): TBytes;
var
  ms: TBytesStream;
  n: Int64;
begin
  Result := nil;
  ms := TBytesStream.Create;
  try
    SaveToStream(ms, AOptions);
    n := ms.Position;
    { hand the buffer over instead of copying it: once the stream has been
      released the reference is unique and the trailing slack is cut off
      without moving the payload }
    Result := ms.Bytes;
  finally
    ms.Free;
  end;
  SetLength(Result, n);
end;

initialization
  BJFormat := DefaultFormatSettings;
  BJFormat.DecimalSeparator := '.';
  BJFormat.ThousandSeparator := #0;

end.
