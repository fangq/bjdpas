program bjdtest;

{  regression tests for the bjdata unit; every case is checked against the
   examples given in the Binary JData specification (Draft 4) or against a
   round-trip through the encoder and the decoder.                          }

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, Math, bjdata;

var
  TestCount: Integer = 0;
  FailCount: Integer = 0;

procedure Check(ACondition: Boolean; const AName: string);
begin
  Inc(TestCount);
  Flush(Output);
  if ACondition then
    WriteLn('  ok   ', AName)
  else
  begin
    Inc(FailCount);
    WriteLn('  FAIL ', AName);
  end;
end;

procedure CheckEq(const AGot, AWant, AName: string);
begin
  Inc(TestCount);
  Flush(Output);
  if AGot = AWant then
    WriteLn('  ok   ', AName)
  else
  begin
    Inc(FailCount);
    WriteLn('  FAIL ', AName);
    WriteLn('       want: ', AWant);
    WriteLn('       got:  ', AGot);
  end;
end;

// a tiny helper used to hand-assemble the binary examples of the spec
type
  TBuf = class(TMemoryStream)
  public
    procedure Hex(const AHex: string);
    procedure Txt(const AText: string);
    procedure U8(AValue: Byte);
    procedure U32(AValue: LongWord);
    procedure F64(AValue: Double);
    function Bytes: TBytes;
  end;

procedure TBuf.Hex(const AHex: string);
var
  i: Integer;
  b: Byte;
  s: string;
begin
  s := StringReplace(AHex, ' ', '', [rfReplaceAll]);
  i := 1;
  while i < Length(s) do
  begin
    b := StrToInt('$' + Copy(s, i, 2));
    WriteBuffer(b, 1);
    Inc(i, 2);
  end;
end;

procedure TBuf.Txt(const AText: string);
begin
  if AText <> '' then
    WriteBuffer(AText[1], Length(AText));
end;

procedure TBuf.U8(AValue: Byte);
begin
  WriteBuffer(AValue, 1);
end;

procedure TBuf.U32(AValue: LongWord);
begin
  WriteBuffer(AValue, 4);
end;

procedure TBuf.F64(AValue: Double);
begin
  WriteBuffer(AValue, 8);
end;

function TBuf.Bytes: TBytes;
begin
  Result := nil;
  SetLength(Result, Size);
  if Size > 0 then
    Move(Memory^, Result[0], Size);
end;

function ParseHex(const AHex: string; AOptions: TBJDataParseOptions = []): TBJData;
var
  b: TBuf;
begin
  b := TBuf.Create;
  try
    b.Hex(AHex);
    Result := TBJData.ParseBytes(b.Bytes, AOptions);
  finally
    b.Free;
  end;
end;

function MkBytes(const AValues: array of Byte): TBytes;
var
  i: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AValues));
  for i := 0 to High(AValues) do
    Result[i] := AValues[i];
end;

function HexOf(const ABuf: TBytes): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(ABuf) do
    Result := Result + IntToHex(ABuf[i], 2);
end;

// round-trip a document through the encoder and decoder and return the JSON
function RoundTrip(ANode: TBJData; AOptions: TBJDataWriteOptions): string;
var
  back: TBJData;
begin
  back := TBJData.ParseBytes(ANode.ToBytes(AOptions));
  try
    Result := back.ToJSON(0);
  finally
    back.Free;
  end;
end;

{------------------------------------------------------------------------------}

procedure TestScalars;
var
  d: TBJData;
begin
  WriteLn('scalar values');

  d := ParseHex('5A');                            // Z
  CheckEq(d.ToJSON(0), 'null', 'null marker');
  d.Free;

  d := ParseHex('54');                            // T
  CheckEq(d.ToJSON(0), 'true', 'true marker');
  d.Free;

  d := ParseHex('46');                            // F
  CheckEq(d.ToJSON(0), 'false', 'false marker');
  d.Free;

  d := ParseHex('6910');                          // i 16
  CheckEq(d.ToJSON(0), '16', 'int8');
  d.Free;

  d := ParseHex('69F0');                          // i -16
  CheckEq(d.ToJSON(0), '-16', 'negative int8');
  d.Free;

  d := ParseHex('55FF');                          // U 255
  CheckEq(d.ToJSON(0), '255', 'uint8');
  d.Free;

  d := ParseHex('49FF7F');                        // I 32767, little-endian
  CheckEq(d.ToJSON(0), '32767', 'int16 is little-endian');
  d.Free;

  d := ParseHex('750080');                        // u 32768
  CheckEq(d.ToJSON(0), '32768', 'uint16');
  d.Free;

  d := ParseHex('6CFFFFFF7F');                    // l 2147483647
  CheckEq(d.ToJSON(0), '2147483647', 'int32');
  d.Free;

  d := ParseHex('4CFFFFFFFFFFFFFF7F');            // L int64 max
  CheckEq(d.ToJSON(0), '9223372036854775807', 'int64');
  d.Free;

  d := ParseHex('4D0000000000000080');            // M 2^63
  CheckEq(d.ToJSON(0), '9223372036854775808', 'uint64 beyond int64 range');
  d.Free;

  d := ParseHex('6400004040');                    // d 3.0
  CheckEq(d.ToJSON(0), '3', 'float32');
  d.Free;

  d := ParseHex('44000000000000F03F');            // D 1.0
  CheckEq(d.ToJSON(0), '1', 'float64');
  d.Free;

  d := ParseHex('680042');                        // h 3.0
  CheckEq(d.ToJSON(0), '3', 'float16');
  d.Free;

  d := ParseHex('4361');                          // C 'a'
  CheckEq(d.ToJSON(0), '"a"', 'char');
  d.Free;

  d := ParseHex('427B');                          // B 123
  CheckEq(d.ToJSON(0), '123', 'byte');
  d.Free;

  d := ParseHex('536904616E6479');                // S i 4 andy
  CheckEq(d.ToJSON(0), '"andy"', 'string');
  d.Free;

  d := ParseHex('48690A2D312E3933452B313930');    // H i 10 -1.93E+190
  CheckEq(d.ToJSON(0), '-1.93E+190', 'high-precision number');
  d.Free;

  // NaN and infinity use their IEEE-754 form, unlike in UBJSON
  d := TBJData.NewFloat(NaN);
  CheckEq(RoundTrip(d, [bjwCount, bjwType]), '"_NaN_"', 'NaN round-trip');
  d.Free;
  d := TBJData.NewFloat(Infinity);
  CheckEq(RoundTrip(d, [bjwCount, bjwType]), '"_Inf_"', 'infinity round-trip');
  d.Free;
end;

procedure TestContainers;
var
  d: TBJData;
begin
  WriteLn('containers');

  // {i8passcodeZ}
  d := ParseHex('7B' + '6908' + '70617373636F6465' + '5A' + '7D');
  CheckEq(d.ToJSON(0), '{"passcode":null}', 'object with a null value');
  d.Free;

  // unoptimized array: [ Z T F l 4782345193... ]
  d := ParseHex('5B' + '5A' + '54' + '46' + '5D');
  CheckEq(d.ToJSON(0), '[null,true,false]', 'unoptimized array');
  d.Free;

  // count-optimized array: [#i3 i1 i2 i3
  d := ParseHex('5B2369036901690269 03');
  CheckEq(d.ToJSON(0), '[1,2,3]', 'count-optimized array');
  d.Free;

  // type+count optimized: [$i#i3
  d := ParseHex('5B246923690301 0203');
  CheckEq(d.ToJSON(0), '[1,2,3]', 'type-optimized array');
  d.Free;

  // count-optimized object: {#i2
  d := ParseHex('7B2369026901616905' + '690162' + '6906');
  CheckEq(d.ToJSON(0), '{"a":5,"b":6}', 'count-optimized object');
  d.Free;

  // type+count optimized object: {$i#i2
  d := ParseHex('7B24692369026901 6105 690162 06');
  CheckEq(d.ToJSON(0), '{"a":5,"b":6}', 'type-optimized object');
  d.Free;

  // the byte array of the spec: [$B#i4 222 173 190 239
  d := ParseHex('5B2442236904DEADBEEF');
  CheckEq(d.ToJSON(0), '[222,173,190,239]', 'packed byte array');
  Check(d.Kind = bjkNDArray, 'packed byte array kind');
  Check(Length(d.AsBytes) = 4, 'packed byte array payload');
  d.Free;

  // no-op markers are skipped
  d := ParseHex('5B' + '4E' + '6901' + '4E' + '6902' + '5D');
  CheckEq(d.ToJSON(0), '[1,2]', 'no-op markers are skipped');
  d.Free;

  // empty containers
  d := ParseHex('5B5D');
  CheckEq(d.ToJSON(0), '[]', 'empty array');
  d.Free;
  d := ParseHex('7B7D');
  CheckEq(d.ToJSON(0), '{}', 'empty object');
  d.Free;
end;

procedure TestNDArray;
const
  RowData = '01090600 02090301 08000906 06040207 08050102 03030206';
  ColData = '01060208 08030904 09050003 06020301 09020007 01020606';
  Expect  = '[[[1,9,6,0],[2,9,3,1],[8,0,9,6]],[[6,4,2,7],[8,5,1,2],[3,3,2,6]]]';
var
  d, e: TBJData;
begin
  WriteLn('N-dimensional packed arrays');

  // [$U#[$U#i3 2 3 4] : row-major 2x3x4 uint8 array
  d := ParseHex('5B2455235B2455236903020304' + RowData);
  Check(d.Kind = bjkNDArray, 'row-major packed array kind');
  Check((d.DimCount = 3) and (d.Dim[0] = 2) and (d.Dim[1] = 3) and (d.Dim[2] = 4),
    'row-major dimensions');
  Check(not d.ColumnMajor, 'row-major flag');
  CheckEq(d.ToJSON(0), Expect, 'row-major payload');
  CheckEq(RoundTrip(d, [bjwCount, bjwType]), Expect, 'row-major round-trip');
  d.Free;

  // the same array written with an unoptimized dimension vector
  d := ParseHex('5B2455235B5502550355045D' + RowData);
  CheckEq(d.ToJSON(0), Expect, 'unoptimized dimension vector');
  d.Free;

  // and with a count-optimized dimension vector
  d := ParseHex('5B2455235B2369035502550355 04' + RowData);
  CheckEq(d.ToJSON(0), Expect, 'count-optimized dimension vector');
  d.Free;

  // [$U#[[$U#i3 2 3 4]] : column-major
  d := ParseHex('5B2455235B5B2455236903020304' + '5D' + ColData);
  Check(d.ColumnMajor, 'column-major flag');
  CheckEq(d.ToJSON(0), Expect, 'column-major payload maps to the same array');
  CheckEq(RoundTrip(d, [bjwCount, bjwType]), Expect, 'column-major round-trip');
  d.Free;

  // expansion into a plain nested array
  d := ParseHex('5B2455235B2455236903020304' + RowData, [bjpExpandNDArray]);
  Check(d.Kind = bjkArray, 'expanded array kind');
  CheckEq(d.ToJSON(0), Expect, 'expanded array content');
  d.Free;

  // a float64 3x2 array built through the API
  e := TBJData.NewNDArray('D', [3, 2]);
  e.SetElem(0, 1.5);
  e.SetElem(5, -2.25);
  CheckEq(e.ToJSON(0), '[[1.5,0],[0,0],[0,-2.25]]', 'API-built packed array');
  CheckEq(RoundTrip(e, [bjwCount, bjwType]), '[[1.5,0],[0,0],[0,-2.25]]',
    'API-built packed array round-trip');
  e.Free;
end;

procedure TestExtensions;
var
  d: TBJData;
  re, im: Double;
begin
  WriteLn('extension types');

  // E U 8 U 8 <3.0f, 4.0f>
  d := ParseHex('45550855080000404000008040');
  Check(d.Kind = bjkExtension, 'extension kind');
  Check(d.ExtTypeId = 8, 'complex64 type id');
  Check(d.AsComplex(re, im) and (re = 3.0) and (im = 4.0), 'complex64 value');
  // the encoder picks the smallest marker for the type id and the length,
  // so int8 is used where the spec example shows uint8; both are valid
  CheckEq(HexOf(d.ToBytes([])), '45690869080000404000008040',
    'complex64 byte-exact round-trip');
  d.Free;

  // E U 10 U 16 550e8400-e29b-41d4-a716-446655440000
  d := ParseHex('4555' + '0A' + '5510' + '550e8400e29b41d4a716446655440000');
  CheckEq(d.AsUUIDString, '550e8400-e29b-41d4-a716-446655440000', 'uuid value');
  d.Free;

  d := TBJData.NewComplex(1.25, -0.5);
  Check(d.ExtTypeId = 9, 'complex128 type id');
  Check(d.AsComplex(re, im) and (re = 1.25) and (im = -0.5), 'complex128 value');
  d.Free;

  d := TBJData.NewUUID('{550E8400-E29B-41D4-A716-446655440000}');
  CheckEq(d.AsUUIDString, '550e8400-e29b-41d4-a716-446655440000',
    'uuid built from a braced string');
  d.Free;

  d := TBJData.NewDateTime(EncodeDate(2024, 1, 15) + EncodeTime(10, 30, 0, 0));
  Check(Abs(d.AsDateTime - (EncodeDate(2024, 1, 15) + EncodeTime(10, 30, 0, 0)))
    < 1.0e-9, 'datetime round-trip');
  d.Free;
end;

procedure TestSoARead;
var
  b: TBuf;
  d: TBJData;
begin
  WriteLn('structure-of-arrays decoding');

  // Example 1 of the spec: 2 records of {id:uint32, pos:{x,y}, val:[3xD], on:T}
  b := TBuf.Create;
  try
    b.Hex('5B247B');                    // [ $ {
    b.Hex('6902'); b.Txt('id');   b.Hex('6D');
    b.Hex('6903'); b.Txt('pos');  b.Hex('7B');
      b.Hex('6901'); b.Txt('x'); b.Hex('44');
      b.Hex('6901'); b.Txt('y'); b.Hex('44');
    b.Hex('7D');
    b.Hex('6903'); b.Txt('val');  b.Hex('5B444444 5D');
    b.Hex('6902'); b.Txt('on');   b.Hex('54');
    b.Hex('7D');                        // end of schema
    b.Hex('23 6902');                   // # i 2
    b.U32(1); b.F64(1.0); b.F64(2.0); b.F64(0.1); b.F64(0.2); b.F64(0.3); b.U8(Ord('T'));
    b.U32(2); b.F64(3.0); b.F64(4.0); b.F64(0.4); b.F64(0.5); b.F64(0.6); b.U8(Ord('F'));
    d := TBJData.ParseBytes(b.Bytes);
  finally
    b.Free;
  end;
  CheckEq(d.ToJSON(0),
    '[{"id":1,"pos":{"x":1,"y":2},"val":[0.1,0.2,0.3],"on":true},' +
    '{"id":2,"pos":{"x":3,"y":4},"val":[0.4,0.5,0.6],"on":false}]',
    'row-major SoA with nested object and array columns');
  Check(d.FromSoA, 'SoA origin flag');
  CheckEq(RoundTrip(d, [bjwCount, bjwType, bjwSoA]),
    '[{"id":1,"pos":{"x":1,"y":2},"val":[0.1,0.2,0.3],"on":true},' +
    '{"id":2,"pos":{"x":3,"y":4},"val":[0.4,0.5,0.6],"on":false}]',
    'row-major SoA re-encoded as SoA');
  d.Free;

  // Example 2 of the spec: dictionary, offset table and fixed-width strings
  b := TBuf.Create;
  try
    b.Hex('5B247B');
    b.Hex('6902'); b.Txt('id');     b.Hex('6D');
    b.Hex('6906'); b.Txt('status'); b.Hex('5B24532369 03');
      b.Hex('6906'); b.Txt('active');
      b.Hex('6908'); b.Txt('inactive');
      b.Hex('6907'); b.Txt('pending');
    b.Hex('6904'); b.Txt('name');   b.Hex('5B246C5D');   // [$l]
    b.Hex('6904'); b.Txt('code');   b.Hex('536904');     // S i 4
    b.Hex('7D');
    b.Hex('236903');                                     // # i 3
    b.U32(1); b.U8(0); b.U32(0); b.Txt('U001');
    b.U32(2); b.U8(2); b.U32(1); b.Txt('U002');
    b.U32(3); b.U8(0); b.U32(2); b.Txt('U003');
    b.U32(0); b.U32(5); b.U32(8); b.U32(32);             // offset table
    b.Txt('AliceBobDr. Christopher Williams');
    d := TBJData.ParseBytes(b.Bytes);
  finally
    b.Free;
  end;
  CheckEq(d.ToJSON(0),
    '[{"id":1,"status":"active","name":"Alice","code":"U001"},' +
    '{"id":2,"status":"pending","name":"Bob","code":"U002"},' +
    '{"id":3,"status":"active","name":"Dr. Christopher Williams","code":"U003"}]',
    'row-major SoA with dictionary and offset-table strings');
  d.Free;

  // the same three records stored column-major
  b := TBuf.Create;
  try
    b.Hex('7B247B');                                     // { $ {
    b.Hex('6901'); b.Txt('x'); b.Hex('44');
    b.Hex('6901'); b.Txt('n'); b.Hex('54');
    b.Hex('7D');
    b.Hex('236903');
    b.F64(1.0); b.F64(2.0); b.F64(3.0);
    b.U8(Ord('T')); b.U8(Ord('F')); b.U8(Ord('T'));
    d := TBJData.ParseBytes(b.Bytes);
  finally
    b.Free;
  end;
  CheckEq(d.ToJSON(0),
    '[{"x":1,"n":true},{"x":2,"n":false},{"x":3,"n":true}]',
    'column-major SoA decoded as an array of records');
  Check(d.ColumnMajor, 'column-major SoA flag');
  CheckEq(RoundTrip(d, [bjwCount, bjwType, bjwSoA]),
    '[{"x":1,"n":true},{"x":2,"n":false},{"x":3,"n":true}]',
    'column-major SoA re-encoded in the same layout');
  d.Free;

  // and decoded as an object of columns when asked for
  b := TBuf.Create;
  try
    b.Hex('7B247B');
    b.Hex('6901'); b.Txt('x'); b.Hex('44');
    b.Hex('6901'); b.Txt('n'); b.Hex('54');
    b.Hex('7D');
    b.Hex('236903');
    b.F64(1.0); b.F64(2.0); b.F64(3.0);
    b.U8(Ord('T')); b.U8(Ord('F')); b.U8(Ord('T'));
    d := TBJData.ParseBytes(b.Bytes, [bjpSoAAsColumns]);
  finally
    b.Free;
  end;
  CheckEq(d.ToJSON(0), '{"x":[1,2,3],"n":[true,false,true]}',
    'column-major SoA decoded as an object of columns');
  Check(d.FromSoA, 'object of columns keeps the SoA flag');
  CheckEq(RoundTrip(d, [bjwCount, bjwType, bjwSoA]),
    '[{"x":1,"n":true},{"x":2,"n":false},{"x":3,"n":true}]',
    'object of columns re-encoded as a column-major SoA record');
  // without the SoA flag a plain object of arrays must stay an object
  d.FromSoA := False;
  CheckEq(RoundTrip(d, [bjwCount, bjwType, bjwSoA]),
    '{"x":[1,2,3],"n":[true,false,true]}',
    'a plain object of arrays is never turned into an SoA record');
  d.Free;
end;

procedure TestSoAWrite;
var
  arr, rec, back: TBJData;
  i: Integer;
  bin: TBytes;
const
  Names: array[0..3] of string = ('Alice', 'Bob', 'Dr. Christopher Williams', 'Eve');
  Status: array[0..3] of string = ('active', 'pending', 'active', 'active');
begin
  WriteLn('structure-of-arrays encoding');

  arr := TBJData.NewArray;
  for i := 0 to 3 do
  begin
    rec := arr.Add(TBJData.NewObject);
    rec.Add('id', TBJData.NewInt(i + 1));
    rec.Add('status', TBJData.NewString(Status[i]));
    rec.Add('name', TBJData.NewString(Names[i]));
    rec.Add('score', TBJData.NewFloat(1.5 * i));
    rec.Add('ok', TBJData.NewBool(Odd(i)));
  end;

  bin := arr.ToBytes([bjwCount, bjwType, bjwSoA]);
  Check(Length(bin) > 0, 'SoA encoding produced output');
  Check((bin[0] = Ord('[')) and (bin[1] = Ord('$')) and (bin[2] = Ord('{')),
    'SoA encoding starts with a row-major schema header');

  back := TBJData.ParseBytes(bin);
  try
    CheckEq(back.ToJSON(0), arr.ToJSON(0), 'SoA encode/decode round-trip');
  finally
    back.Free;
  end;

  // the same table stored column-major
  bin := arr.ToBytes([bjwCount, bjwType, bjwSoA, bjwColumnMajor]);
  Check(bin[0] = Ord('{'), 'column-major SoA header');
  back := TBJData.ParseBytes(bin);
  try
    CheckEq(back.ToJSON(0), arr.ToJSON(0), 'column-major SoA round-trip');
  finally
    back.Free;
  end;

  // SoA is smaller than the generic object encoding for this table
  Check(Length(arr.ToBytes([bjwCount, bjwType, bjwSoA])) <
        Length(arr.ToBytes([bjwCount, bjwType])), 'SoA encoding is more compact');

  // a table that cannot be packed falls back to the generic encoding
  arr.Items[2].Values['score'] := TBJData.NewObject;
  bin := arr.ToBytes([bjwCount, bjwType, bjwSoA]);
  Check(bin[1] <> Ord('$'), 'non-uniform table falls back to a plain array');
  back := TBJData.ParseBytes(bin);
  try
    CheckEq(back.ToJSON(0), arr.ToJSON(0), 'fallback round-trip');
  finally
    back.Free;
  end;
  arr.Free;
end;

procedure TestRoundTrip;
var
  doc, sub: TBJData;
  json: string;
begin
  WriteLn('document round-trips');

  doc := TBJData.NewObject;
  doc.Add('nil', TBJData.NewNull);
  doc.Add('yes', TBJData.NewBool(True));
  doc.Add('i8', TBJData.NewInt(-7));
  doc.Add('u64', TBJData.NewUInt(High(QWord)));
  doc.Add('pi', TBJData.NewFloat(3.141592653589793));
  doc.Add('half', TBJData.NewFloat(0.5, 'h'));
  doc.Add('text', TBJData.NewString('hello, 世界'));
  doc.Add('ch', TBJData.NewChar(';'));
  doc.Add('huge', TBJData.NewHighPrec('3.14159265358979323846'));
  doc.Add('bin', TBJData.NewBytes(MkBytes([1, 2, 3, 250])));
  sub := doc.Add('list', TBJData.NewArray);
  sub.Add(TBJData.NewInt(1));
  sub.Add(TBJData.NewString('two'));
  sub.Add(TBJData.NewArray);
  doc.Add('grid', TBJData.NewNDArray('l', [2, 2]));
  doc.Values['grid'].SetElem(3, Int64(70000));

  json := doc.ToJSON(0);
  CheckEq(RoundTrip(doc, [bjwCount, bjwType]), json, 'full document, optimized');
  CheckEq(RoundTrip(doc, [bjwCount]), json, 'full document, count only');
  CheckEq(RoundTrip(doc, []), json, 'full document, unoptimized');
  CheckEq(RoundTrip(doc, [bjwCount, bjwType, bjwSoA]), json,
    'full document, SoA enabled');

  Check(doc.Path('list[1]') <> nil, 'path lookup finds an array element');
  CheckEq(doc.Path('list[1]').AsString, 'two', 'path lookup value');
  Check(doc.Path('grid') <> nil, 'path lookup finds a packed array');
  Check(doc.Path('nope.deeper') = nil, 'path lookup of a missing key');

  sub := doc.Clone;
  CheckEq(sub.ToJSON(0), json, 'clone equality');
  sub.Free;

  doc.Free;
end;

procedure TestEdgeCases;
var
  d: TBJData;
  ok: Boolean;
  i: Integer;
  v: Double;
begin
  WriteLn('edge cases');

  // truncated input must raise rather than read past the buffer
  ok := False;
  try
    d := ParseHex('5B240923');
    d.Free;
  except
    on E: EBJData do
      ok := True;
  end;
  Check(ok, 'a truncated stream raises EBJData');

  ok := False;
  try
    d := ParseHex('536905616263');                // S i 5 abc
    d.Free;
  except
    on E: EBJData do
      ok := True;
  end;
  Check(ok, 'a short string payload raises EBJData');

  ok := False;
  try
    d := ParseHex('51');                          // unknown marker
    d.Free;
  except
    on E: EBJData do
      ok := True;
  end;
  Check(ok, 'an unknown marker raises EBJData');

  // half-precision round-trip over a range of values
  ok := True;
  for i := -2048 to 2048 do
  begin
    v := i / 16.0;
    if BJHalfToDouble(BJDoubleToHalf(v)) <> v then
      ok := False;
  end;
  Check(ok, 'float16 round-trips exactly for representable values');
  Check(BJHalfToDouble($7C00) = Infinity, 'float16 infinity');
  Check(IsNan(BJHalfToDouble($7E00)), 'float16 NaN');
  Check(BJDoubleToHalf(1.0) = $3C00, 'float16 encoding of 1.0');
  Check(BJDoubleToHalf(-2.0) = $C000, 'float16 encoding of -2.0');

  // the smallest integer type is selected when writing
  d := TBJData.NewInt(200);
  CheckEq(HexOf(d.ToBytes([])), '55C8', 'a value of 200 is stored as uint8');
  d.Free;
  d := TBJData.NewInt(-200);
  CheckEq(HexOf(d.ToBytes([])), '4938FF', 'a value of -200 is stored as int16');
  d.Free;

  // a uniform array of small integers becomes a packed array
  d := TBJData.NewArray;
  d.Add(TBJData.NewInt(1));
  d.Add(TBJData.NewInt(2));
  d.Add(TBJData.NewInt(300));
  CheckEq(HexOf(d.ToBytes([bjwCount, bjwType])), '5B2449236903010002002C01',
    'mixed-width integers share the smallest common type');
  d.Free;
end;

// parse every prefix of a document: a truncated stream must raise instead of
// crashing, and must not leave anything behind (run under -gh to check)
procedure TestTruncation;
var
  doc: TBJData;
  full, part: TBytes;
  i, raised, parsed: Integer;
  b: TBuf;
begin
  WriteLn('truncated input');

  b := TBuf.Create;
  try
    // a document touching most of the decoder: packed array, SoA, strings,
    // extension, nested containers
    b.Hex('7B');
    b.Hex('6903'); b.Txt('arr'); b.Hex('5B2455235B2455236902 0203' + '010203040506');
    b.Hex('6903'); b.Txt('str'); b.Hex('5369056865' + '6C6C6F');
    b.Hex('6903'); b.Txt('ext'); b.Hex('45690869080000404000008040');
    b.Hex('6903'); b.Txt('soa'); b.Hex('5B247B');
    b.Hex('6901'); b.Txt('x'); b.Hex('44');
    b.Hex('6901'); b.Txt('n'); b.Hex('54');
    b.Hex('6904'); b.Txt('name'); b.Hex('5B24555D');
    b.Hex('7D'); b.Hex('236902');
    b.F64(1.0); b.U8(Ord('T')); b.U8(0);
    b.F64(2.0); b.U8(Ord('F')); b.U8(1);
    b.U8(0); b.U8(3); b.U8(6); b.Txt('AmyBob');
    b.Hex('6903'); b.Txt('obj'); b.Hex('7B690161' + '5A' + '7D');
    b.Hex('7D');
    full := b.Bytes;
  finally
    b.Free;
  end;

  doc := TBJData.ParseBytes(full);
  CheckEq(doc.ToJSON(0),
    '{"arr":[[1,2,3],[4,5,6]],"str":"hello","ext":{"_ExtType_":8,' +
    '"_ExtValue_":[3,4]},"soa":[{"x":1,"n":true,"name":"Amy"},' +
    '{"x":2,"n":false,"name":"Bob"}],"obj":{"a":null}}',
    'reference document for the truncation sweep');
  doc.Free;

  raised := 0;
  parsed := 0;
  for i := 1 to Length(full) - 1 do
  begin
    part := Copy(full, 0, i);
    try
      doc := TBJData.ParseBytes(part);
      doc.Free;
      Inc(parsed);
    except
      on E: EBJData do
        Inc(raised);
      on E: Exception do
      begin
        WriteLn('       unexpected ', E.ClassName, ' at length ', i, ': ', E.Message);
        Inc(parsed);
      end;
    end;
  end;
  Check(raised + parsed = Length(full) - 1, 'every prefix was handled');
  Check(raised > Length(full) div 2,
    Format('%d of %d truncated prefixes were rejected', [raised, raised + parsed]));

  // the same sweep with a corrupted byte at each position
  raised := 0;
  for i := 0 to Length(full) - 1 do
  begin
    part := Copy(full, 0, Length(full));
    part[i] := Byte(not part[i]);
    try
      doc := TBJData.ParseBytes(part);
      doc.Free;
    except
      on E: EBJData do
        Inc(raised);
      on E: Exception do
        WriteLn('       unexpected ', E.ClassName, ' at byte ', i, ': ', E.Message);
    end;
  end;
  Check(raised > 0, Format('%d corrupted documents were rejected', [raised]));
end;

// render a document using only the lazy cursor; the result must match what
// the tree produces, which exercises skipping and iteration over every
// construct the format has
function CursorJSON(const AValue: TBJValue): string;
var
  it: TBJIterator;
  first: Boolean;
  doc: TBJData;
begin
  if AValue.IsSoA or (AValue.IsNDArray and (AValue.DimCount > 1)) then
  begin
    doc := AValue.ToData;
    try
      Exit(doc.ToJSON(0));
    finally
      doc.Free;
    end;
  end;
  case AValue.Kind of
    bjkNull, bjkNoOp:
      Result := 'null';
    bjkBoolean:
      if AValue.AsBoolean then
        Result := 'true'
      else
        Result := 'false';
    bjkInt:
      Result := IntToStr(AValue.AsInt64);
    bjkUInt:
      Result := UIntToStr(AValue.AsQWord);
    bjkFloat:
      Result := BJFloatToStr(AValue.AsDouble);
    bjkString:
      if AValue.Marker = 'H' then
        Result := AValue.AsString
      else
        Result := '"' + BJJSONEscape(AValue.AsString) + '"';
    bjkExtension:
      begin
        doc := AValue.ToData;
        try
          Result := doc.ToJSON(0);
        finally
          doc.Free;
        end;
      end;
    bjkArray, bjkNDArray:
      begin
        Result := '[';
        first := True;
        it := AValue.GetEnumerator;
        while it.MoveNext do
        begin
          if not first then
            Result := Result + ',';
          Result := Result + CursorJSON(it.Current);
          first := False;
        end;
        Result := Result + ']';
      end;
    bjkObject:
      begin
        Result := '{';
        first := True;
        it := AValue.GetEnumerator;
        while it.MoveNext do
        begin
          if not first then
            Result := Result + ',';
          Result := Result + '"' + BJJSONEscape(it.Key) + '":' +
            CursorJSON(it.Current);
          first := False;
        end;
        Result := Result + '}';
      end;
  end;
end;

procedure CheckCursor(const ABytes: TBytes; const AName: string);
var
  doc: TBJData;
  want: string;
begin
  doc := TBJData.ParseBytes(ABytes);
  try
    want := doc.ToJSON(0);
  finally
    doc.Free;
  end;
  CheckEq(CursorJSON(TBJData.View(ABytes)), want, 'cursor walk: ' + AName);
  doc := TBJData.View(ABytes).ToData;
  try
    CheckEq(doc.ToJSON(0), want, 'cursor ToData: ' + AName);
  finally
    doc.Free;
  end;
end;

// a value may be shrunk in place and the freed bytes filled with no-ops,
// which the decoder has to skip wherever a value or a pair can start
procedure TestNoOpPadding;
var
  doc, back: TBJData;
  buf: TBytes;
  i, at: Integer;
  v: TBJValue;
  cold: Double;

  function PadAt(const ASource: TBytes): TBytes;
  var
    k: Integer;
  begin
    Result := Copy(ASource, 0, Length(ASource));
    for k := 0 to High(Result) - 3 do
      if (Result[k] = Ord('S')) and (Result[k + 1] = Ord('i')) and
         (Result[k + 2] = 5) then
      begin
        Result[k + 2] := 2;
        Result[k + 3] := Ord('h');
        Result[k + 4] := Ord('i');
        Result[k + 5] := Ord('N');
        Result[k + 6] := Ord('N');
        Result[k + 7] := Ord('N');
        Exit;
      end;
  end;

begin
  WriteLn('in-place editing');

  doc := TBJData.NewObject;
  doc.Add('temp', TBJData.NewFloat(20.5));
  doc.Add('name', TBJData.NewString('hello'));
  doc.Add('n', TBJData.NewInt(7));

  buf := PadAt(doc.ToBytes([]));
  back := TBJData.ParseBytes(buf);
  try
    CheckEq(back.ToJSON(0), '{"temp":20.5,"name":"hi","n":7}',
      'no-op padding inside an unbounded object');
  finally
    back.Free;
  end;

  buf := PadAt(doc.ToBytes([bjwCount]));
  back := TBJData.ParseBytes(buf);
  try
    CheckEq(back.ToJSON(0), '{"temp":20.5,"name":"hi","n":7}',
      'no-op padding inside a counted object');
  finally
    back.Free;
  end;
  CheckEq(TBJData.View(buf).Find('n').AsString, '7',
    'the cursor steps over no-op padding');
  doc.Free;

  // and in arrays, counted or not
  doc := TBJData.NewArray;
  doc.Add(TBJData.NewString('hello'));
  doc.Add(TBJData.NewInt(3));
  buf := PadAt(doc.ToBytes([]));
  back := TBJData.ParseBytes(buf);
  try
    CheckEq(back.ToJSON(0), '["hi",3]', 'no-op padding inside an array');
  finally
    back.Free;
  end;
  buf := PadAt(doc.ToBytes([bjwCount]));
  back := TBJData.ParseBytes(buf);
  try
    CheckEq(back.ToJSON(0), '["hi",3]', 'no-op padding inside a counted array');
  finally
    back.Free;
  end;
  Check(TBJData.View(buf).Count = 2, 'padding does not add a child');
  doc.Free;

  // overwriting a fixed-width value in place keeps the document valid
  doc := TBJData.NewObject;
  doc.Add('a', TBJData.NewInt(1));
  doc.Add('temp', TBJData.NewFloat(20.5));
  doc.Add('z', TBJData.NewInt(2));
  buf := doc.ToBytes([bjwCount]);
  doc.Free;
  at := -1;
  for i := 0 to High(buf) - 8 do
    if buf[i] = Ord('D') then
    begin
      at := i + 1;
      Break;
    end;
  Check(at > 0, 'found the float payload');
  cold := -273.15;
  PDouble(@buf[at])^ := cold;
  back := TBJData.ParseBytes(buf);
  try
    CheckEq(back.ToJSON(0), '{"a":1,"temp":-273.15,"z":2}',
      'a fixed-width value can be overwritten in place');
  finally
    back.Free;
  end;
  v := TBJData.View(buf);
  Check(v.Find('temp').AsDouble = cold, 'the cursor sees the new value');
  Check(v.Find('z').AsInt64 = 2, 'the values after it are untouched');
end;

procedure TestPatch;
var
  doc, back: TBJData;
  buf, before: TBytes;
  v: TBJValue;
  i: Integer;
  d: Double;

  function Json(const ABytes: TBytes): string;
  var
    n: TBJData;
  begin
    n := TBJData.ParseBytes(ABytes);
    try
      Result := n.ToJSON(0);
    finally
      n.Free;
    end;
  end;

  function Unchanged(const A, B: TBytes): Boolean;
  var
    k: Integer;
  begin
    Result := Length(A) = Length(B);
    if Result then
      for k := 0 to High(A) do
        if A[k] <> B[k] then
          Exit(False);
  end;

begin
  WriteLn('patching in place');

  doc := TBJData.NewObject;
  doc.Add('i8', TBJData.NewInt(10, 'i'));
  doc.Add('u8', TBJData.NewInt(200, 'U'));
  doc.Add('i32', TBJData.NewInt(70000, 'l'));
  doc.Add('f64', TBJData.NewFloat(1.5));
  doc.Add('f32', TBJData.NewFloat(1.5, 'd'));
  doc.Add('f16', TBJData.NewFloat(1.5, 'h'));
  doc.Add('flag', TBJData.NewBool(True));
  doc.Add('text', TBJData.NewString('hello world'));
  doc.Add('tail', TBJData.NewInt(99));
  buf := doc.ToBytes([bjwCount]);
  doc.Free;

  v := TBJData.View(buf);
  Check(v.Find('i8').TryPatch(Int64(-5)), 'patch an int8');
  Check(v.Find('u8').TryPatch(Int64(255)), 'patch a uint8');
  Check(v.Find('i32').TryPatch(Int64(-70000)), 'patch an int32');
  d := 2.25;
  Check(v.Find('f64').TryPatch(d), 'patch a float64');
  Check(v.Find('f32').TryPatch(d), 'patch a float32');
  Check(v.Find('f16').TryPatch(d), 'patch a float16');
  Check(v.Find('flag').TryPatch(False), 'patch a boolean');
  Check(v.Find('text').TryPatchText('hi'), 'patch a shorter string');
  CheckEq(Json(buf),
    '{"i8":-5,"u8":255,"i32":-70000,"f64":2.25,"f32":2.25,"f16":2.25,' +
    '"flag":false,"text":"hi","tail":99}', 'the patched document re-reads');
  CheckEq(CursorJSON(TBJData.View(buf)), Json(buf),
    'and the cursor agrees with the tree');

  { a change that does not fit must leave the buffer alone }
  before := Copy(buf, 0, Length(buf));
  Check(not v.Find('i8').TryPatch(Int64(1000)), 'an int8 cannot hold 1000');
  Check(not v.Find('u8').TryPatch(Int64(-1)), 'a uint8 cannot hold -1');
  Check(not v.Find('text').TryPatchText('a much longer string'),
    'a longer string is refused');
  d := 1.5;
  Check(not v.Find('i8').TryPatch(d), 'a fractional value is refused by an int slot');
  Check(not v.Find('tail').TryPatchText('x'), 'text cannot be written over a number');
  Check(Unchanged(before, buf), 'a refused patch leaves every byte as it was');

  { a whole value can be replaced by null, padding what it used to occupy }
  Check(v.Find('text').TryPatchNull, 'replace a string with null');
  CheckEq(Json(buf),
    '{"i8":-5,"u8":255,"i32":-70000,"f64":2.25,"f32":2.25,"f16":2.25,' +
    '"flag":false,"text":null,"tail":99}', 'the document after nulling');

  { same-size text keeps its length header }
  doc := TBJData.NewObject;
  doc.Add('code', TBJData.NewString('AAAA'));
  doc.Add('n', TBJData.NewInt(1));
  buf := doc.ToBytes([bjwCount]);
  doc.Free;
  v := TBJData.View(buf);
  Check(v.Find('code').TryPatchText('ZZZZ'), 'patch a string of equal length');
  CheckEq(Json(buf), '{"code":"ZZZZ","n":1}', 'equal length text patch');

  { elements of an N-d array can be written through a view }
  doc := TBJData.NewNDArray('D', [2, 3]);
  buf := doc.ToBytes([bjwCount, bjwType]);
  doc.Free;
  v := TBJData.View(buf);
  d := -7.5;
  Check(v.Item(v.Offset([1, 1])).TryPatch(d), 'patch one element by subscript');
  d := 3.25;
  Check(v.Item(0).TryPatch(d), 'patch one element by position');
  back := TBJData.ParseBytes(buf);
  try
    CheckEq(back.ToJSON(0), '[[3.25,0,0],[0,-7.5,0]]',
      'the N-d array after patching');
  finally
    back.Free;
  end;
  Check(not v.Item(0).TryPatchText('x'),
    'text cannot be written into an N-d array element');

  { patching works the same inside an unbounded container }
  doc := TBJData.NewObject;
  doc.Add('text', TBJData.NewString('hello world'));
  doc.Add('n', TBJData.NewInt(1));
  buf := doc.ToBytes([]);
  doc.Free;
  v := TBJData.View(buf);
  Check(v.Find('text').TryPatchText('bye'), 'patch inside an unbounded object');
  CheckEq(Json(buf), '{"text":"bye","n":1}', 'unbounded object after patching');

  { and inside an array, counted or not }
  for i := 0 to 1 do
  begin
    doc := TBJData.NewArray;
    doc.Add(TBJData.NewString('first value'));
    doc.Add(TBJData.NewInt(2));
    if i = 0 then
      buf := doc.ToBytes([])
    else
      buf := doc.ToBytes([bjwCount]);
    doc.Free;
    v := TBJData.View(buf);
    Check(v.Item(0).TryPatchText('x'), Format('patch inside an array (%d)', [i]));
    CheckEq(Json(buf), '["x",2]', Format('array after patching (%d)', [i]));
  end;
end;

procedure TestCursor;
var
  doc, sub: TBJData;
  v, rec: TBJValue;
  it: TBJIterator;
  bytes: TBytes;
  n, i: Integer;
  total: Double;
  b: TBuf;
begin
  WriteLn('lazy cursor');

  doc := TBJData.NewObject;
  doc.Add('name', TBJData.NewString('probe'));
  doc.Add('count', TBJData.NewInt(1234));
  doc.Add('ratio', TBJData.NewFloat(0.25));
  doc.Add('on', TBJData.NewBool(True));
  doc.Add('none', TBJData.NewNull);
  sub := doc.Add('list', TBJData.NewArray);
  for i := 1 to 5 do
    sub.Add(TBJData.NewInt(i * 100));
  sub := doc.Add('deep', TBJData.NewObject);
  sub.Add('inner', TBJData.NewArray).Add(TBJData.NewString('x'));
  doc.Add('grid', TBJData.NewNDArray('D', [2, 3]));
  doc.Values['grid'].SetElem(5, 2.5);
  bytes := doc.ToBytes([bjwCount, bjwType]);

  v := TBJData.View(bytes);
  Check(v.IsValid, 'view is valid');
  Check(v.Kind = bjkObject, 'view kind');
  Check(v.Count = 8, 'view child count');
  Check(v.Find('name').TextEquals('probe'), 'zero-copy key/text comparison');
  Check(v.Find('count').AsInt64 = 1234, 'view integer');
  Check(v.Find('ratio').AsDouble = 0.25, 'view float');
  Check(v.Find('on').AsBoolean, 'view boolean');
  Check(v.Find('none').IsNull, 'view null');
  Check(not v.Find('nope').IsValid, 'missing key gives an invalid view');
  Check(v.Find('list').Count = 5, 'view array count');
  Check(v.Find('list').Item(3).AsInt64 = 400, 'view array index');
  Check(v.Path('deep.inner[0]').TextEquals('x'), 'view path lookup');
  Check(v.Path('list[4]').AsInt64 = 500, 'view path index');

  n := 0;
  total := 0;
  for rec in v.Find('list') do
  begin
    Inc(n);
    total := total + rec.AsDouble;
  end;
  Check((n = 5) and (total = 1500), 'for..in over an array');

  n := 0;
  it := v.GetEnumerator;
  while it.MoveNext do
  begin
    Inc(n);
    if it.KeyEquals('count') then
      Check(it.Current.AsInt64 = 1234, 'iterator key and value');
  end;
  Check(n = 8, 'iterator visited every pair');

  rec := v.Find('grid');
  Check(rec.IsNDArray, 'packed array is recognised');
  Check(rec.Kind = bjkNDArray, 'packed array kind');
  Check(rec.ElemMarker = 'D', 'packed element type');
  Check(rec.ElementCount = 6, 'packed element count');
  Check((rec.DimCount = 2) and (rec.Dim[0] = 2) and (rec.Dim[1] = 3),
    'packed dimensions');
  Check(rec.ElemAsDouble(5) = 2.5, 'packed element access');
  Check(rec.DataSize = 48, 'packed payload size');
  Check(PDouble(rec.DataPtr)[5] = 2.5, 'packed payload is addressed in place');
  doc.Free;

  CheckCursor(bytes, 'mixed document');

  // the same document in every encoding the writer can produce
  doc := TBJData.ParseBytes(bytes);
  try
    CheckCursor(doc.ToBytes([]), 'unoptimized');
    CheckCursor(doc.ToBytes([bjwCount]), 'counted');
    CheckCursor(doc.ToBytes([bjwCount, bjwType]), 'typed');
    CheckCursor(doc.ToBytes([bjwCount, bjwType, bjwColumnMajor]), 'column-major');
  finally
    doc.Free;
  end;

  // a column-major N-d array has a nested dimension vector; the cursor has to
  // measure it correctly to reach whatever follows it
  doc := TBJData.NewObject;
  doc.Add('grid', TBJData.NewNDArray('D', [2, 3, 4]));
  doc.Values['grid'].ColumnMajor := True;
  doc.Values['grid'].SetElem(23, 9.5);
  doc.Add('after', TBJData.NewInt(1234));
  doc.Add('tail', TBJData.NewString('end'));
  bytes := doc.ToBytes([bjwCount, bjwType]);
  doc.Free;
  v := TBJData.View(bytes);
  rec := v.Find('grid');
  Check(rec.DimCount = 3, 'cursor reads a nested dimension vector');
  Check((rec.Dim[0] = 2) and (rec.Dim[1] = 3) and (rec.Dim[2] = 4),
    'column-major dimensions through the cursor');
  Check(rec.ColumnMajor, 'column-major flag through the cursor');
  Check(rec.ElementCount = 24, 'column-major element count');
  Check(rec.ElemAsDouble(23) = 9.5, 'column-major element access');
  Check(rec.ElemAsDouble(rec.Offset([1, 2, 3])) = 9.5, 'subscripts map to the payload');
  Check(v.Find('after').AsInt64 = 1234,
    'the cursor steps over a column-major array to the next key');
  Check(v.Find('tail').TextEquals('end'), 'and to the one after that');
  CheckCursor(bytes, 'column-major array followed by more keys');

  // the same for a row-major array, and for the subscript mapping
  doc := TBJData.NewObject;
  doc.Add('grid', TBJData.NewNDArray('l', [2, 3, 4]));
  doc.Values['grid'].SetElem(doc.Values['grid'].Offset([1, 2, 3]), Int64(77));
  doc.Add('after', TBJData.NewInt(5678));
  bytes := doc.ToBytes([bjwCount, bjwType]);
  Check(doc.Values['grid'].Offset([1, 2, 3]) = 23, 'row-major subscript mapping');
  Check(doc.Values['grid'].Offset([0, 0, 1]) = 1, 'row-major is last index fastest');
  doc.Values['grid'].ColumnMajor := True;
  Check(doc.Values['grid'].Offset([0, 0, 1]) = 6,
    'column-major is first index fastest');
  Check(doc.Values['grid'].Offset([1, 0, 0]) = 1, 'column-major stride');
  doc.Free;
  v := TBJData.View(bytes);
  Check(v.Find('grid').ElemAsInt64(23) = 77, 'row-major element through the cursor');
  Check(v.Find('after').AsInt64 = 5678,
    'the cursor steps over a row-major array to the next key');
  CheckCursor(bytes, 'row-major array followed by another key');

  // spec constructs: packed N-d arrays, extensions, high precision, char
  b := TBuf.Create;
  try
    b.Hex('5B');
    b.Hex('5B2455235B2455236903020304');
    b.Hex('01090600 02090301 08000906 06040207 08050102 03030206');
    b.Hex('45690869080000404000008040');
    b.Hex('48690A2D312E3933452B313930');
    b.Hex('4361');
    b.Hex('427B');
    b.Hex('4D0000000000000080');
    b.Hex('5B2442236904DEADBEEF');
    b.Hex('5D');
    CheckCursor(b.Bytes, 'spec constructs');
  finally
    b.Free;
  end;

  // a document holding SoA records next to ordinary values: the cursor has to
  // know how long an SoA record is in order to reach what follows it
  b := TBuf.Create;
  try
    b.Hex('7B');
    b.Hex('6905'); b.Txt('first'); b.Hex('6907');
    b.Hex('6903'); b.Txt('tab'); b.Hex('5B247B');
    b.Hex('6902'); b.Txt('id'); b.Hex('6D');
    b.Hex('6906'); b.Txt('status'); b.Hex('5B24532369 03');
    b.Hex('6906'); b.Txt('active');
    b.Hex('6908'); b.Txt('inactive');
    b.Hex('6907'); b.Txt('pending');
    b.Hex('6904'); b.Txt('name'); b.Hex('5B246C5D');
    b.Hex('6904'); b.Txt('code'); b.Hex('536904');
    b.Hex('7D');
    b.Hex('236903');
    b.U32(1); b.U8(0); b.U32(0); b.Txt('U001');
    b.U32(2); b.U8(2); b.U32(1); b.Txt('U002');
    b.U32(3); b.U8(0); b.U32(2); b.Txt('U003');
    b.U32(0); b.U32(5); b.U32(8); b.U32(32);
    b.Txt('AliceBobDr. Christopher Williams');
    b.Hex('6904'); b.Txt('last'); b.Hex('53690474616B65');
    b.Hex('7D');
    bytes := b.Bytes;
  finally
    b.Free;
  end;
  v := TBJData.View(bytes);
  Check(v.Find('first').AsInt64 = 7, 'value before an SoA record');
  Check(v.Find('tab').IsSoA, 'SoA record is recognised');
  Check(v.Find('last').TextEquals('take'),
    'the cursor skips over an SoA record to reach the next key');
  CheckCursor(bytes, 'document containing an SoA record');

  // truncated input must be reported, not walked past
  n := 0;
  for i := 1 to Length(bytes) - 1 do
  begin
    try
      CursorJSON(TBJData.View(Copy(bytes, 0, i)));
    except
      on E: EBJData do
        Inc(n);
      on E: Exception do
        WriteLn('       unexpected ', E.ClassName, ' at ', i, ': ', E.Message);
    end;
  end;
  Check(n > Length(bytes) div 2,
    Format('%d truncated prefixes rejected by the cursor', [n]));
end;

begin
  WriteLn('bjdata.pas ', BJDataVersion, ' test suite');
  WriteLn;
  TestScalars;
  TestContainers;
  TestNDArray;
  TestExtensions;
  TestSoARead;
  TestSoAWrite;
  TestRoundTrip;
  TestEdgeCases;
  TestTruncation;
  TestNoOpPadding;
  TestCursor;
  TestPatch;
  WriteLn;
  WriteLn(Format('%d test(s), %d failure(s)', [TestCount, FailCount]));
  if FailCount > 0 then
    Halt(1);
end.
