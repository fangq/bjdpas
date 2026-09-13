program bench;

//  bench - time the bjdata decoder and encoder on a .bjd/.jdb file
//
//    bench [-n repeats] [-q] <file.bjd> [more files...]

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, DateUtils, bjdata;

var
  Repeats: Integer = 3;
  Quiet: Boolean = False;
  DoDecode: Boolean = True;
  DoEncode: Boolean = True;
  DoJSON: Boolean = True;

function LoadFile(const AName: string): TBytes;
var
  fs: TFileStream;
begin
  Result := nil;
  fs := TFileStream.Create(AName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(Result[0], fs.Size);
  finally
    fs.Free;
  end;
end;

procedure Run(const AName: string);
var
  buf, enc: TBytes;
  doc: TBJData;
  i: Integer;
  t0: TDateTime;
  best, worst, bestfree, dt: Double;
  mb: Double;
begin
  buf := LoadFile(AName);
  mb := Length(buf) / (1024 * 1024);

  best := 1.0e30;
  worst := 0;
  bestfree := 1.0e30;
  doc := nil;
  for i := 1 to Repeats do
  begin
    if doc <> nil then
    begin
      t0 := Now;
      doc.Free;
      dt := MilliSecondSpan(t0, Now) / 1000.0;
      if dt < bestfree then
        bestfree := dt;
    end;
    t0 := Now;
    doc := TBJData.ParseBytes(buf);
    dt := MilliSecondSpan(t0, Now) / 1000.0;
    if dt < best then
      best := dt;
    if dt > worst then
      worst := dt;
  end;
  if DoDecode then
    WriteLn(Format('%-14s %8.2f MB  decode %7.3f s  (%6.1f MB/s)  [free %6.3f s]',
      [ExtractFileName(AName), mb, best, mb / best, bestfree]));
  if not DoEncode then
  begin
    if DoJSON then
      ;
    doc.Free;
    Exit;
  end;

  best := 1.0e30;
  for i := 1 to Repeats do
  begin
    t0 := Now;
    enc := doc.ToBytes([bjwCount, bjwType]);
    dt := MilliSecondSpan(t0, Now) / 1000.0;
    if dt < best then
      best := dt;
  end;
  WriteLn(Format('%-14s %8.2f MB  encode %7.3f s  (%6.1f MB/s)  [out %.2f MB]',
    [' ', mb, best, mb / best, Length(enc) / (1024 * 1024)]));

  if not Quiet then
  begin
    best := 1.0e30;
    for i := 1 to Repeats do
    begin
      t0 := Now;
      doc.ToJSON(0);
      dt := MilliSecondSpan(t0, Now) / 1000.0;
      if dt < best then
        best := dt;
    end;
    WriteLn(Format('%-14s %8.2f MB  tojson %7.3f s  (%6.1f MB/s)',
      [' ', mb, best, mb / best]));
  end;

  doc.Free;
end;

var
  i: Integer;
  files: array of string;
begin
  SetLength(files, 0);
  i := 1;
  while i <= ParamCount do
  begin
    if ParamStr(i) = '-n' then
    begin
      Inc(i);
      Repeats := StrToIntDef(ParamStr(i), 3);
    end
    else if ParamStr(i) = '-q' then
      Quiet := True
    else if ParamStr(i) = '-d' then
    begin
      DoEncode := False;
      Quiet := True;
    end
    else
    begin
      SetLength(files, Length(files) + 1);
      files[High(files)] := ParamStr(i);
    end;
    Inc(i);
  end;
  if Length(files) = 0 then
  begin
    WriteLn('usage: bench [-n repeats] [-q] <file.bjd> [...]');
    Halt(1);
  end;
  for i := 0 to High(files) do
    Run(files[i]);
end.
