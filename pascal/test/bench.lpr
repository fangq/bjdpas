program bench;

//  bench - time the bjdata decoder and encoder on a .bjd/.jdb file
//
//    bench [-n repeats] [-q] <file.bjd> [more files...]

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, DateUtils, {$IFDEF UNIX}BaseUnix, Unix,{$ENDIF} bjdata;

{ Now() only resolves milliseconds, which is not enough for the faster
  operations on the smaller files. The value is kept in integer microseconds
  so that no precision is lost before the difference is taken }
function Clock: Int64;
{$IFDEF UNIX}
var
  tv: TTimeVal;
begin
  fpgettimeofday(@tv, nil);
  Result := Int64(tv.tv_sec) * 1000000 + tv.tv_usec;
end;
{$ELSE}
begin
  Result := Round(Now * 86400.0 * 1000000.0);
end;
{$ENDIF}

function Rate(AMegaBytes, ASeconds: Double): Double;
begin
  if ASeconds > 0 then
    Result := AMegaBytes / ASeconds
  else
    Result := 0;
end;

var
  Repeats: Integer = 3;
  Quiet: Boolean = False;
  DoDecode: Boolean = True;
  DoEncode: Boolean = True;
  DoJSON: Boolean = True;
  DoScan: Boolean = False;

{ walk the document without building anything: this is the byte-processing
  floor of the format, i.e. what is left to gain if node construction were
  free. Only the constructs used by the benchmark files are handled. }
var
  ScanP, ScanE: PByte;
  ScanNodes: Int64;

procedure ScanFail(const AMsg: string);
begin
  raise Exception.Create(AMsg);
end;

function ScanByte: Byte; inline;
begin
  if ScanP >= ScanE then
    ScanFail('eof');
  Result := ScanP^;
  Inc(ScanP);
end;

function ScanInt(AMarker: AnsiChar): Int64;
var
  n: Integer;
begin
  n := BJMarkerSize(AMarker);
  if (n = 0) or (ScanP + n > ScanE) then
    ScanFail('bad size marker');
  case n of
    1: if AMarker = 'i' then Result := PShortInt(ScanP)^ else Result := ScanP^;
    2: if AMarker = 'I' then Result := PSmallInt(ScanP)^ else Result := PWord(ScanP)^;
    4: if AMarker = 'l' then Result := PLongInt(ScanP)^ else Result := PLongWord(ScanP)^;
  else
    Result := PInt64(ScanP)^;
  end;
  Inc(ScanP, n);
end;

function ScanSize: Int64;
begin
  Result := ScanInt(AnsiChar(ScanByte));
end;

procedure ScanValue(AMarker: AnsiChar); forward;

procedure ScanDims(out ACount: Int64);
var
  m: AnsiChar;
  k, i: Int64;
begin
  ACount := 1;
  m := AnsiChar(ScanByte);
  if m <> '[' then
  begin
    ACount := ScanInt(m);
    Exit;
  end;
  m := AnsiChar(ScanP^);
  if m = '$' then
  begin
    Inc(ScanP);
    m := AnsiChar(ScanByte);
    if AnsiChar(ScanByte) <> '#' then
      ScanFail('bad dim vector');
    k := ScanSize;
    for i := 1 to k do
      ACount := ACount * ScanInt(m);
  end
  else
  begin
    ACount := 1;
    while AnsiChar(ScanP^) <> ']' do
      ACount := ACount * ScanSize;
    Inc(ScanP);
  end;
end;

procedure ScanValue(AMarker: AnsiChar);
var
  n, i, cnt: Int64;
  et: AnsiChar;
begin
  Inc(ScanNodes);
  case AMarker of
    'Z', 'N', 'T', 'F':
      ;
    'i', 'U', 'I', 'u', 'l', 'm', 'L', 'M', 'h', 'd', 'D', 'C', 'B':
      begin
        n := BJMarkerSize(AMarker);
        if ScanP + n > ScanE then
          ScanFail('eof');
        Inc(ScanP, n);
      end;
    'S', 'H':
      begin
        n := ScanSize;
        if ScanP + n > ScanE then
          ScanFail('eof');
        Inc(ScanP, n);
      end;
    'E':
      begin
        ScanSize;
        n := ScanSize;
        Inc(ScanP, n);
      end;
    '[':
      begin
        if AnsiChar(ScanP^) = '$' then
        begin
          Inc(ScanP);
          et := AnsiChar(ScanByte);
          if AnsiChar(ScanByte) <> '#' then
            ScanFail('count expected');
          ScanDims(cnt);
          Inc(ScanP, cnt * BJMarkerSize(et));
          Inc(ScanNodes, cnt);
        end
        else if AnsiChar(ScanP^) = '#' then
        begin
          Inc(ScanP);
          ScanDims(cnt);
          for i := 1 to cnt do
            ScanValue(AnsiChar(ScanByte));
        end
        else
          while AnsiChar(ScanP^) <> ']' do
            ScanValue(AnsiChar(ScanByte))
        ;
        if (ScanP < ScanE) and (AnsiChar(ScanP^) = ']') then
          Inc(ScanP);
      end;
    '{':
      begin
        if AnsiChar(ScanP^) = '#' then
        begin
          Inc(ScanP);
          ScanDims(cnt);
          for i := 1 to cnt do
          begin
            n := ScanSize;
            Inc(ScanP, n);
            ScanValue(AnsiChar(ScanByte));
          end;
        end
        else
        begin
          while AnsiChar(ScanP^) <> '}' do
          begin
            n := ScanSize;
            Inc(ScanP, n);
            ScanValue(AnsiChar(ScanByte));
          end;
          Inc(ScanP);
        end;
      end;
  else
    ScanFail('marker ' + AMarker);
  end;
end;

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
  t0: Int64;
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
      t0 := Clock;
      doc.Free;
      dt := (Clock - t0) / 1.0e6;
      if dt < bestfree then
        bestfree := dt;
    end;
    t0 := Clock;
    doc := TBJData.ParseBytes(buf);
    dt := (Clock - t0) / 1.0e6;
    if dt < best then
      best := dt;
    if dt > worst then
      worst := dt;
  end;
  if DoDecode then
    WriteLn(Format('%-14s %8.2f MB  decode %7.3f s  (%6.1f MB/s)  [free %6.3f s]',
      [ExtractFileName(AName), mb, best, Rate(mb, best), bestfree]));
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
    t0 := Clock;
    enc := doc.ToBytes([bjwCount, bjwType]);
    dt := (Clock - t0) / 1.0e6;
    if dt < best then
      best := dt;
  end;
  WriteLn(Format('%-14s %8.2f MB  encode %7.3f s  (%6.1f MB/s)  [out %.2f MB]',
    [' ', mb, best, Rate(mb, best), Length(enc) / (1024 * 1024)]));

  if DoScan then
  begin
    best := 1.0e30;
    for i := 1 to Repeats do
    begin
      t0 := Clock;
      ScanP := @buf[0];
      ScanE := ScanP + Length(buf);
      ScanNodes := 0;
      ScanValue(AnsiChar(ScanByte));
      dt := (Clock - t0) / 1.0e6;
      if dt < best then
        best := dt;
    end;
    WriteLn(Format('%-14s %8.2f MB  scan   %7.3f s  (%6.1f MB/s)  [%d values]',
      [' ', mb, best, Rate(mb, best), ScanNodes]));
  end;

  if not Quiet then
  begin
    best := 1.0e30;
    for i := 1 to Repeats do
    begin
      t0 := Clock;
      doc.ToJSON(0);
      dt := (Clock - t0) / 1.0e6;
      if dt < best then
        best := dt;
    end;
    WriteLn(Format('%-14s %8.2f MB  tojson %7.3f s  (%6.1f MB/s)',
      [' ', mb, best, Rate(mb, best)]));
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
    else if ParamStr(i) = '-s' then
      DoScan := True
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
