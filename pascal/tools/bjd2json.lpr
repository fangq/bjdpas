program bjd2json;

//  bjd2json - convert a Binary JData (.bjd) file to JSON, or re-encode it
//  with a different set of optimizations.
//
//    bjd2json [options] <input.bjd> [output.json]
//
//  Options:
//    -i <n>     indent the JSON output by n spaces (default: compact)
//    -x         expand packed N-dimensional arrays into nested arrays
//    -k         keep no-op markers
//    -c         decode a column-major SoA record as an object of columns
//    -o <file>  re-encode the document as BJData and write it to <file>
//    -O <flags> encoder flags for -o, any of: c (count), t (type),
//               s (SoA), m (column-major); default "ct"
//    -h         show this help

{$mode objfpc}{$H+}

uses
  SysUtils, Classes, bjdata;

procedure Usage;
begin
  WriteLn('usage: bjd2json [-i n] [-x] [-k] [-c] [-o out.bjd] [-O ctsm] ',
          '<input.bjd> [output.json]');
  WriteLn;
  WriteLn('  -i <n>     indent the JSON output by n spaces');
  WriteLn('  -x         expand packed N-dimensional arrays');
  WriteLn('  -k         keep no-op markers');
  WriteLn('  -c         decode a column-major SoA record as an object of columns');
  WriteLn('  -o <file>  re-encode the document as BJData into <file>');
  WriteLn('  -O <flags> encoder flags: c=count, t=type, s=SoA, m=column-major');
end;

var
  i, indent: Integer;
  inname, outname, reencode, flags, arg: string;
  popt: TBJDataParseOptions;
  wopt: TBJDataWriteOptions;
  doc: TBJData;
  json: TStringList;
begin
  indent := 0;
  inname := '';
  outname := '';
  reencode := '';
  flags := 'ct';
  popt := [];
  i := 1;
  while i <= ParamCount do
  begin
    arg := ParamStr(i);
    if arg = '-i' then
    begin
      Inc(i);
      indent := StrToIntDef(ParamStr(i), 0);
    end
    else if arg = '-x' then
      Include(popt, bjpExpandTypedArray)
    else if arg = '-k' then
      Include(popt, bjpKeepNoOp)
    else if arg = '-c' then
      Include(popt, bjpSoAAsColumns)
    else if arg = '-o' then
    begin
      Inc(i);
      reencode := ParamStr(i);
    end
    else if arg = '-O' then
    begin
      Inc(i);
      flags := ParamStr(i);
    end
    else if (arg = '-h') or (arg = '--help') then
    begin
      Usage;
      Halt(0);
    end
    else if inname = '' then
      inname := arg
    else
      outname := arg;
    Inc(i);
  end;

  if inname = '' then
  begin
    Usage;
    Halt(1);
  end;

  wopt := [];
  if Pos('c', flags) > 0 then
    Include(wopt, bjwCount);
  if Pos('t', flags) > 0 then
    Include(wopt, bjwType);
  if Pos('s', flags) > 0 then
    Include(wopt, bjwSoA);
  if Pos('m', flags) > 0 then
    Include(wopt, bjwColumnMajor);

  try
    doc := TBJData.ParseFile(inname, popt);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'bjd2json: ', E.Message);
      Halt(2);
    end;
  end;

  try
    if outname = '' then
      WriteLn(doc.ToJSON(indent))
    else
    begin
      json := TStringList.Create;
      try
        json.Text := doc.ToJSON(indent);
        json.SaveToFile(outname);
      finally
        json.Free;
      end;
    end;
    if reencode <> '' then
      doc.SaveToFile(reencode, wopt);
  finally
    doc.Free;
  end;
end.
