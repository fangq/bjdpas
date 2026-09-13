program ndarray;

//  Working with N-dimensional arrays.
//
//  BJData writes an N-d array as an optimized container whose count marker is
//  followed by a dimension vector instead of a single number:
//
//    [[] [$] [type] [#] [[] <dimensions> ...payload...     row-major
//    [[] [$] [type] [#] [[] [[] <dimensions> []] ...       column-major
//
//  The payload is one contiguous block, so reading it costs a memcpy rather
//  than a node per element.

{$mode objfpc}{$H+}

uses
  SysUtils, bjdata;

const
  Nx = 2;
  Ny = 3;
  Nz = 4;

procedure Dump(const ATitle: string; const ABytes: TBytes; ALimit: Integer);
var
  i: Integer;
  s: string;
begin
  s := '';
  for i := 0 to High(ABytes) do
  begin
    if i >= ALimit then
    begin
      s := s + '...';
      Break;
    end;
    if ABytes[i] in [32..126] then
      s := s + ' ' + AnsiChar(ABytes[i])
    else
      s := s + IntToHex(ABytes[i], 2);
    s := s + ' ';
  end;
  WriteLn(ATitle, ' (', Length(ABytes), ' bytes)');
  WriteLn('  ', s);
end;

var
  vol, back, slice: TBJData;
  v: TBJValue;
  raw: TBytes;
  i, j, k: Integer;
  p: PDouble;
  total: Double;
  expected: string;
  body: TBytes;
begin
  {--- 1. build a 2x3x4 array of float64 -------------------------------}
  vol := TBJData.NewTypedArray('D', [Nx, Ny, Nz]);
  for i := 0 to Nx - 1 do
    for j := 0 to Ny - 1 do
      for k := 0 to Nz - 1 do
        vol.SetElem(vol.Offset([i, j, k]), Double(i * 100 + j * 10 + k));

  WriteLn('dimensions      : ', vol.DimCount, 'd, ',
    vol.Dim[0], ' x ', vol.Dim[1], ' x ', vol.Dim[2],
    ', ', vol.ElementCount, ' elements');
  WriteLn('element [1,2,3] : ', vol.ElemAsDouble(vol.Offset([1, 2, 3])):0:0);
  WriteLn('as JSON         : ', vol.ToJSON(0));

  raw := vol.ToBytes([bjwCount, bjwType]);
  Dump('row-major bytes', raw, 14);
  WriteLn('  header reads: [ $ D # [ $ i # i 3  2 3 4 ] then ',
    Nx * Ny * Nz, ' doubles');
  WriteLn;

  {--- 2. read it back ---------------------------------------------------}
  expected := vol.ToJSON(0);
  back := TBJData.ParseBytes(raw);
  try
    WriteLn('round-trip      : ', back.DimCount, 'd ',
      back.Dim[0], 'x', back.Dim[1], 'x', back.Dim[2],
      ', [1,2,3] = ', back.ElemAsDouble(back.Offset([1, 2, 3])):0:0);
    { walking it by subscript }
    total := 0;
    for i := 0 to back.Dim[0] - 1 do
      for j := 0 to back.Dim[1] - 1 do
        for k := 0 to back.Dim[2] - 1 do
          total := total + back.ElemAsDouble(back.Offset([i, j, k]));
    WriteLn('sum of elements : ', total:0:0);
  finally
    back.Free;
  end;

  {--- 3. the same array in column-major order ---------------------------}
  vol.ColumnMajor := True;
  { the payload has to be rewritten, the layout only says how to read it }
  for i := 0 to Nx - 1 do
    for j := 0 to Ny - 1 do
      for k := 0 to Nz - 1 do
        vol.SetElem(vol.Offset([i, j, k]), Double(i * 100 + j * 10 + k));
  Dump('column-major bytes', vol.ToBytes([bjwCount, bjwType]), 15);
  WriteLn('  header reads: [ $ D # [ [ $ i # i 3  2 3 4 ] ...');
  WriteLn('  same values  : [1,2,3] = ',
    vol.ElemAsDouble(vol.Offset([1, 2, 3])):0:0,
    ', JSON is identical: ', vol.ToJSON(0) = expected);
  WriteLn;

  {--- 4. reading without building a tree --------------------------------}
  raw := vol.ToBytes([bjwCount, bjwType]);
  vol.Free;
  v := TBJData.View(raw);
  WriteLn('view            : ', v.DimCount, 'd, ', v.ElementCount,
    ' elements of "', v.ElemMarker, '", column-major = ', v.ColumnMajor);
  WriteLn('view [1,2,3]    : ', v.ElemAsDouble(v.Offset([1, 2, 3])):0:0);

  { the payload can be used where it lies, with no copy at all }
  p := PDouble(v.DataPtr);
  total := 0;
  for i := 0 to v.ElementCount - 1 do
    total := total + p[i];
  WriteLn('sum through DataPtr, no copy: ', total:0:0,
    ' (', v.DataSize, ' bytes in place)');
  WriteLn;

  {--- 5. the count-only form: [ # [ dims ] with tagged elements --------}
  { the specification defines the dimension vector for a typed array, where
    every element has the same width. A reader here also accepts the shape on
    a plain counted array, whose elements carry their own markers and may
    therefore differ in type; the writer does not produce it, because it is
    not part of the specification. }
  raw := nil;
  SetLength(raw, 13);
  i := 0;
  raw[i] := Ord('['); Inc(i);
  raw[i] := Ord('#'); Inc(i);
  raw[i] := Ord('['); Inc(i);         // the count is a dimension vector
  raw[i] := Ord('$'); Inc(i);
  raw[i] := Ord('i'); Inc(i);         // of int8 values
  raw[i] := Ord('#'); Inc(i);
  raw[i] := Ord('i'); Inc(i);
  raw[i] := 2;        Inc(i);         // two dimensions
  raw[i] := 2;        Inc(i);         // 2 rows
  raw[i] := 3;        Inc(i);         // 3 columns
  raw[i] := Ord('U'); Inc(i);         // ... followed by 6 tagged values,
  raw[i] := 7;        Inc(i);         //     of which only the first two
  raw[i] := Ord('T');                 //     are shown here
  Dump('hand-written [#[ header', raw, 13);
  WriteLn('  reads as: [ # [ $ i # i 2  2 3 ] then 6 values of any type');

  { the same header with all six values, so that it can be parsed }
  slice := TBJData.NewArray;
  for i := 0 to 5 do
    if Odd(i) then
      slice.Add(TBJData.NewInt(i))
    else
      slice.Add(TBJData.NewFloat(i / 2));
  body := slice.ToBytes([]);                     // [ v1 v2 ... v6 ]
  slice.Free;
  SetLength(raw, 10 + Length(body) - 2);         // header + values, no [ or ]
  Move(body[1], raw[10], Length(body) - 2);
  back := TBJData.ParseBytes(raw);
  try
    WriteLn('  parsed       : ', back.DimCount, 'd ',
      back.Dim[0], 'x', back.Dim[1], ', ', back.Count, ' values, ',
      back.ToJSON(0));
    WriteLn('  element [1,2] = ', back.Items[back.Offset([1, 2])].AsString);
  finally
    back.Free;
  end;
end.
