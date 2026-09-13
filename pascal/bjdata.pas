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
  public
    constructor Create(AKind: TBJDataKind = bjkNull);
    destructor Destroy; override;

    {---- constructors for each value type ----}
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
function BJIntMarkerFor(AValue: Int64): AnsiChar;
function BJUIntMarkerFor(AValue: QWord): AnsiChar;
function BJHalfToDouble(AValue: Word): Double;
function BJDoubleToHalf(AValue: Double): Word;
function BJKindName(AKind: TBJDataKind): string;
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

function BJJSONEscape(const AValue: string): string;
var
  i: Integer;
  c: AnsiChar;
begin
  Result := '';
  for i := 1 to Length(AValue) do
  begin
    c := AValue[i];
    case c of
      '"':  Result := Result + '\"';
      '\':  Result := Result + '\\';
      #8:   Result := Result + '\b';
      #9:   Result := Result + '\t';
      #10:  Result := Result + '\n';
      #12:  Result := Result + '\f';
      #13:  Result := Result + '\r';
    else
      if c < ' ' then
        Result := Result + '\u' + LowerCase(IntToHex(Ord(c), 4))
      else
        Result := Result + c;
    end;
  end;
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
begin
  Clear;
  inherited Destroy;
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

type
  TBJReader = class(TObject)
  private
    FBuf: PByte;
    FSize: PtrUInt;
    FPos: PtrUInt;
    FOptions: TBJDataParseOptions;
    procedure Need(ACount: PtrUInt);
    procedure Fail(const AMsg: string);
    function AtEOF: Boolean;
    function ReadChar: AnsiChar;
    function PeekChar: AnsiChar;
    procedure SkipChar;
    procedure Expect(AMarker: AnsiChar);
    function ReadStr(ALength: PtrUInt): string;
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
    function ReadObjectNode: TBJData;
    function ReadFieldSpec: TBJSoAField;
    function ReadSchema(ATerminator: AnsiChar): TBJSoAFieldArray;
    function ReadSoAValue(AField: TBJSoAField; ARecord: Int64): TBJData;
    function ReadSoA(ARowMajor: Boolean): TBJData;
  public
    constructor Create(ABuffer: PByte; ASize: PtrUInt;
      AOptions: TBJDataParseOptions);
    function ReadValue: TBJData;
    property Position: PtrUInt read FPos;
  end;

constructor TBJReader.Create(ABuffer: PByte; ASize: PtrUInt;
  AOptions: TBJDataParseOptions);
begin
  inherited Create;
  FBuf := ABuffer;
  FSize := ASize;
  FPos := 0;
  FOptions := AOptions;
end;

procedure TBJReader.Fail(const AMsg: string);
begin
  raise EBJData.CreateFmt('%s at byte offset %d', [AMsg, FPos]);
end;

procedure TBJReader.Need(ACount: PtrUInt);
begin
  if FPos + ACount > FSize then
    Fail(Format('unexpected end of input, %d more byte(s) needed', [ACount]));
end;

function TBJReader.AtEOF: Boolean;
begin
  Result := FPos >= FSize;
end;

function TBJReader.ReadChar: AnsiChar;
begin
  Need(1);
  Result := AnsiChar(FBuf[FPos]);
  Inc(FPos);
end;

function TBJReader.PeekChar: AnsiChar;
begin
  Need(1);
  Result := AnsiChar(FBuf[FPos]);
end;

procedure TBJReader.SkipChar;
begin
  Need(1);
  Inc(FPos);
end;

procedure TBJReader.Expect(AMarker: AnsiChar);
var
  c: AnsiChar;
begin
  c := ReadChar;
  if c <> AMarker then
    Fail(Format('expected marker "%s" but found "%s"', [AMarker, c]));
end;

function TBJReader.ReadStr(ALength: PtrUInt): string;
begin
  Need(ALength);
  SetLength(Result, ALength);
  if ALength > 0 then
    Move(FBuf[FPos], Result[1], ALength);
  Inc(FPos, ALength);
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
    Fail(Format('"%s" is not a fixed-length numeric marker', [AMarker]));
  Need(sz);
  case sz of
    1:
      begin
        v8 := FBuf[FPos];
        if AMarker = bjmInt8 then
          Result := ShortInt(v8)
        else
          Result := v8;
      end;
    2:
      begin
        Move(FBuf[FPos], v16, 2);
        BJFromLE(@v16, 2, 1);
        if AMarker = bjmInt16 then
          Result := SmallInt(v16)
        else
          Result := v16;
      end;
    4:
      begin
        Move(FBuf[FPos], v32, 4);
        BJFromLE(@v32, 4, 1);
        if AMarker = bjmInt32 then
          Result := LongInt(v32)
        else
          Result := v32;
      end;
  else
    begin
      Move(FBuf[FPos], v64, 8);
      BJFromLE(@v64, 8, 1);
      Result := v64;
    end;
  end;
  Inc(FPos, sz);
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
        Move(FBuf[FPos], v16, 2);
        BJFromLE(@v16, 2, 1);
        Inc(FPos, 2);
        Result := BJHalfToDouble(v16);
      end;
    bjmFloat32:
      begin
        Need(4);
        Move(FBuf[FPos], v32, 4);
        BJFromLE(@v32, 4, 1);
        Inc(FPos, 4);
        Result := v32;
      end;
    bjmFloat64:
      begin
        Need(8);
        Move(FBuf[FPos], v64, 8);
        BJFromLE(@v64, 8, 1);
        Inc(FPos, 8);
        Result := v64;
      end;
  else
    begin
      Result := 0;
      Fail(Format('"%s" is not a floating-point marker', [AMarker]));
    end;
  end;
end;

{ read a length/count: a numeric marker followed by a non-negative integer }
function TBJReader.ReadSize: Int64;
var
  m: AnsiChar;
begin
  m := ReadChar;
  if not BJIsIntMarker(m) then
    Fail(Format('"%s" cannot be used as a length or count', [m]));
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

function TBJReader.ReadScalar(AMarker: AnsiChar): TBJData;
var
  len: Int64;
  id: Int64;
  buf: TBytes;
  q: QWord;
begin
  case AMarker of
    bjmNull:
      Result := TBJData.NewNull;
    bjmNoOp:
      Result := TBJData.NewNoOp;
    bjmTrue:
      Result := TBJData.NewBool(True);
    bjmFalse:
      Result := TBJData.NewBool(False);
    bjmUInt64:
      begin
        q := QWord(ReadIntValue(AMarker));
        Result := TBJData.NewUInt(q);
        Result.FMarker := bjmUInt64;
      end;
    bjmInt8, bjmUInt8, bjmInt16, bjmUInt16, bjmInt32, bjmUInt32, bjmInt64,
    bjmByte:
      Result := TBJData.NewInt(ReadIntValue(AMarker), AMarker);
    bjmChar:
      begin
        Need(1);
        Result := TBJData.Create(bjkString);
        Result.FMarker := bjmChar;
        Result.FStr := AnsiChar(FBuf[FPos]);
        Inc(FPos);
      end;
    bjmFloat16, bjmFloat32, bjmFloat64:
      Result := TBJData.NewFloat(ReadFloatValue(AMarker), AMarker);
    bjmString:
      begin
        len := ReadSize;
        Result := TBJData.NewString(ReadStr(len));
      end;
    bjmHighPrec:
      begin
        len := ReadSize;
        Result := TBJData.NewHighPrec(ReadStr(len));
      end;
    bjmExtension:
      begin
        id := ReadSize;
        len := ReadSize;
        SetLength(buf, len);
        if len > 0 then
        begin
          Need(len);
          Move(FBuf[FPos], buf[0], len);
          Inc(FPos, len);
        end;
        Result := TBJData.NewExtension(id, buf);
      end;
    bjmArrayStart:
      Result := ReadArrayNode;
    bjmObjectStart:
      Result := ReadObjectNode;
  else
    begin
      Result := nil;
      Fail(Format('unknown type marker "%s" (0x%.2x)',
        [AMarker, Ord(AMarker)]));
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
  Result := TBJData.Create(bjkTypedArray);
  Result.FMarker := AMarker;
  Result.FDims := Copy(ADims, 0, Length(ADims));
  Result.FColumnMajor := AColumnMajor;
  SetLength(Result.FBin, nbytes);
  if nbytes > 0 then
  begin
    Move(FBuf[FPos], Result.FBin[0], nbytes);
    BJFromLE(@Result.FBin[0], sz, n);
    Inc(FPos, nbytes);
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

function TBJReader.ReadArrayNode: TBJData;
var
  c, et: AnsiChar;
  dims: TBJDataDims;
  colmajor: Boolean;
  n, i: Int64;
begin
  c := PeekChar;
  if c = bjmTypeMark then
  begin
    SkipChar;
    et := ReadChar;
    if et = bjmObjectStart then
      Exit(ReadSoA(True));                     // row-major SoA record
    Expect(bjmCountMark);
    ReadCountSpec(dims, colmajor);
    if BJIsFixedMarker(et) then
      Exit(ReadPacked(et, dims, colmajor));
    { lenient: a non-fixed optimized type (allowed by UBJSON, not by BJData) }
    n := BJDimProduct(dims);
    Result := TBJData.NewArray;
    try
      for i := 0 to n - 1 do
        Result.Add(ReadScalar(et));
    except
      Result.Free;
      raise;
    end;
    if Length(dims) > 1 then
    begin
      Result.FDims := Copy(dims, 0, Length(dims));
      Result.FColumnMajor := colmajor;
    end;
    Exit;
  end;
  if c = bjmCountMark then
  begin
    SkipChar;
    ReadCountSpec(dims, colmajor);
    n := BJDimProduct(dims);
    Result := TBJData.NewArray;
    try
      for i := 0 to n - 1 do
        Result.Add(ReadValue);
    except
      Result.Free;
      raise;
    end;
    if Length(dims) > 1 then
    begin
      Result.FDims := Copy(dims, 0, Length(dims));
      Result.FColumnMajor := colmajor;
    end;
    Exit;
  end;
  Result := TBJData.NewArray;
  try
    while True do
    begin
      c := PeekChar;
      if c = bjmArrayEnd then
      begin
        SkipChar;
        Break;
      end;
      Result.Add(ReadValue);
    end;
  except
    Result.Free;
    raise;
  end;
end;

function TBJReader.ReadObjectNode: TBJData;
var
  c, et: AnsiChar;
  dims: TBJDataDims;
  colmajor: Boolean;
  n, i: Int64;
  key: string;
begin
  c := PeekChar;
  if c = bjmTypeMark then
  begin
    SkipChar;
    et := ReadChar;
    if et = bjmObjectStart then
      Exit(ReadSoA(False));                    // column-major SoA record
    Expect(bjmCountMark);
    ReadCountSpec(dims, colmajor);
    n := BJDimProduct(dims);
    Result := TBJData.NewObject;
    try
      for i := 0 to n - 1 do
      begin
        key := ReadKey;
        Result.Add(key, ReadScalar(et));
      end;
    except
      Result.Free;
      raise;
    end;
    Exit;
  end;
  Result := TBJData.NewObject;
  try
    if c = bjmCountMark then
    begin
      SkipChar;
      ReadCountSpec(dims, colmajor);
      n := BJDimProduct(dims);
      for i := 0 to n - 1 do
      begin
        key := ReadKey;
        Result.Add(key, ReadValue);
      end;
      Exit;
    end;
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
      key := ReadKey;
      Result.Add(key, ReadValue);
    end;
  except
    Result.Free;
    raise;
  end;
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
          Result.FStr := AnsiChar(FBuf[FPos]);
          Inc(FPos);
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
        for i := 0 to High(AField.Fields) do
          Result.Add(ReadSoAValue(AField.Fields[i], ARecord));
      end;
    skObject:
      begin
        Result := TBJData.NewObject;
        for i := 0 to High(AField.Fields) do
          Result.Add(AField.Fields[i].Name,
            ReadSoAValue(AField.Fields[i], ARecord));
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

type
  TBJWriter = class(TObject)
  private
    FStream: TStream;
    FOptions: TBJDataWriteOptions;
    procedure W(const ABuffer; ACount: PtrUInt);
    procedure WChar(AMarker: AnsiChar);
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
    procedure WValue(ANode: TBJData);
  end;

constructor TBJWriter.Create(AStream: TStream; AOptions: TBJDataWriteOptions);
begin
  inherited Create;
  FStream := AStream;
  FOptions := AOptions;
end;

procedure TBJWriter.W(const ABuffer; ACount: PtrUInt);
begin
  if ACount > 0 then
    FStream.WriteBuffer(ABuffer, ACount);
end;

procedure TBJWriter.WChar(AMarker: AnsiChar);
begin
  FStream.WriteBuffer(AMarker, 1);
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
  TBJData - parsing and serialization entry points
==============================================================================}

class function TBJData.Parse(const ABuffer; ALength: PtrUInt;
  AOptions: TBJDataParseOptions): TBJData;
var
  rd: TBJReader;
begin
  rd := TBJReader.Create(PByte(@ABuffer), ALength, AOptions);
  try
    Result := rd.ReadValue;
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
  ms: TMemoryStream;
begin
  Result := nil;
  ms := TMemoryStream.Create;
  try
    SaveToStream(ms, AOptions);
    SetLength(Result, ms.Size);
    if ms.Size > 0 then
      Move(ms.Memory^, Result[0], ms.Size);
  finally
    ms.Free;
  end;
end;

initialization
  BJFormat := DefaultFormatSettings;
  BJFormat.DecimalSeparator := '.';
  BJFormat.ThousandSeparator := #0;

end.
