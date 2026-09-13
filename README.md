bjdpas
======

An Object Pascal implementation of **Binary JData (BJData)**, a
quasi-human-readable binary JSON format derived from UBJSON Draft 12 with
native support for N-dimensional arrays, unsigned and half-precision numeric
types, a byte type, structure-of-arrays containers and binary extension types.

* Specification: <https://neurojson.org/bjdata/draft4>
* Upstream project: <https://github.com/NeuroJSON/bjdata>

[`src/bjdata.pas`](src/bjdata.pas) is the whole library: one unit, one class,
no dependencies beyond `Classes`, `SysUtils` and `Math`. It builds with Free
Pascal, installs into Lazarus as a package, and reads and writes every
construct of Draft 4.

```pascal
uses bjdata;

doc := TBJData.ParseFile('input.bjd');
WriteLn(doc.ToJSON(2));
doc.Values['volume'] := TBJData.NewNDArray('D', [128, 128, 64]);
doc.SaveToFile('output.bjd');
doc.Free;
```

A large file can also be read without building a tree at all:

```pascal
for rec in TBJData.View(buf) do
  if rec.Find('type').TextEquals('PushEvent') then
    WriteLn(rec.Path('actor.id').AsInt64);
```

See [`src/README.md`](src/README.md) for the document model, the lazy cursor,
in-place editing, N-dimensional arrays, performance and how to build and test.

| | |
|---|---|
| Library | [`src/bjdata.pas`](src/bjdata.pas), package [`src/bjdatapkg.lpk`](src/bjdatapkg.lpk) |
| Tests | `make -C src test` - 198 checks |
| Example | `make -C src example` - N-dimensional arrays end to end |
| Tool | `make -C src tools` - `bjd2json`, dump or re-encode a `.bjd` file |

License: Apache License, Version 2.0 (see [LICENSE](LICENSE)), matching the
BJData specification and the reference implementations.
