bjdata.pas - Binary JData for Object Pascal
===========================================

A single-unit [Binary JData (BJData)](https://neurojson.org/bjdata/draft4)
parser and writer for Free Pascal, Lazarus and Delphi-compatible compilers.
There are no dependencies beyond `Classes`, `SysUtils` and `Math`: drop
`bjdata.pas` into a project and add `bjdata` to the `uses` clause. Lazarus
users can instead open `bjdatapkg.lpk` and add the package to a project.

Everything is reachable through one class, `TBJData`, which is both the
in-memory document tree and the entry point for reading and writing.

```pascal
uses bjdata;

var
  doc, grid: TBJData;
begin
  doc := TBJData.ParseFile('input.bjd');
  try
    WriteLn(doc.ToJSON(2));                       // pretty-print as JSON
    WriteLn(doc.Path('subject.age').AsInt64);     // dotted/indexed lookup

    grid := TBJData.NewTypedArray('D', [128, 128, 64]);   // packed 3-d double
    grid.SetElem(0, 3.5);
    doc.Values['volume'] := grid;                 // the tree owns the node

    doc.SaveToFile('output.bjd');
  finally
    doc.Free;                                     // frees the whole tree
  end;
end;
```

Supported format features
-------------------------

| Feature | Read | Write |
|---|---|---|
| `Z N T F i U I u l m L M h d D H C B S` values | yes | yes |
| Little-endian numerics, IEEE `NaN`/`±Inf` | yes | yes |
| Unoptimized, count-optimized (`#`) and type-optimized (`$`) containers | yes | yes |
| Packed N-dimensional arrays, row- **and** column-major | yes | yes |
| Structure-of-arrays, row-major (`[$`) and column-major (`{$`) | yes | yes |
| SoA columns: fixed numeric, `T`, `Z`, fixed strings, dictionary strings, offset-table strings, nested objects, fixed arrays | yes | yes |
| Extension type `E`, including the reserved ids 1-10 | yes | yes |

Non-fixed optimized container types (`[$S`, `[$T`, …) are accepted when
reading, because UBJSON allows them, but are never written: BJData restricts
`$` to fixed-length types.

Document model
--------------

`TBJData.Kind` tells a node apart:

| Kind | Holds | Accessors |
|---|---|---|
| `bjkNull`, `bjkNoOp` | nothing | `IsNull` |
| `bjkBoolean` | `T`/`F` | `AsBoolean` |
| `bjkInt`, `bjkUInt` | integers, `Marker` keeps the width | `AsInt64`, `AsQWord` |
| `bjkFloat` | `h`/`d`/`D` | `AsDouble` |
| `bjkString` | `S`, `C` (char) and `H` (high-precision) | `AsString`, `IsHighPrec` |
| `bjkArray`, `bjkObject` | child nodes | `Count`, `Items[]`, `Names[]`, `Values[]` |
| `bjkTypedArray` | a packed numeric payload | `Dim[]`, `DimCount`, `ElemAsDouble`, `ElemAsInt64`, `SetElem`, `AsBytes`, `ExpandTypedArray` |
| `bjkExtension` | a type id and a byte payload | `ExtTypeId`, `ExtPayload`, `AsComplex`, `AsUUIDString`, `AsDateTime` |

A node owns its children; freeing the root frees the tree. `Add`, `Insert` and
the `Values[]` setter take ownership of the node passed to them, `Extract`
gives it back.

Parsing options
---------------

| Option | Effect |
|---|---|
| `bjpKeepNoOp` | keep `N` markers as `bjkNoOp` nodes instead of skipping them |
| `bjpExpandTypedArray` | decode a packed array into nested plain arrays |
| `bjpSoAAsColumns` | decode a column-major SoA record as an object of columns; by default both SoA layouts decode to an array of records |

Writing options
---------------

| Option | Effect |
|---|---|
| `bjwCount` | emit the `#` count for arrays and objects |
| `bjwType` | emit `$type` for arrays whose elements share a fixed type |
| `bjwSoA` | store uniform arrays of objects as SoA records |
| `bjwColumnMajor` | prefer the column-major layout for SoA records |

The default, `[bjwCount, bjwType]`, produces the most compact output that the
other BJData implementations read today.

Two notes on `bjwSoA`:

* An array of objects that share a key set and column types is packed into a
  row-major SoA record; anything else falls back to the plain encoding, so the
  option is always safe to enable.
* An *object* of equal-length arrays is only written as a column-major SoA
  record when its `FromSoA` property is set (which the parser does for records
  it decoded). Inferring it would be lossy, since `{"x":[1,2,3]}` and a table
  of three records with one `x` field are different documents.

Packed array layout
-------------------

`ColumnMajor` selects how the payload of a `bjkTypedArray` is interpreted and
written. Element accessors (`ElemAsDouble`, `SetElem`) always address the
payload in storage order, while `ToJSON` and `ExpandTypedArray` present the
array in row-major (C) order for either layout.

Building and testing
--------------------

```
make test        # build and run the regression suite
make tools       # build bjd2json
make cross       # additionally cross-check against the python bjdata module
```

`test/bjdtest.lpr` holds 94 checks covering the examples of the specification,
round-trips and error handling. `test/crosscheck.py` encodes a set of documents
with the reference [pybj](https://github.com/NeuroJSON/pybj) library, decodes
them with `bjd2json`, re-encodes them with every combination of writer options
and decodes the result with pybj again.

`tools/bjd2json` converts a `.bjd` file to JSON and can re-encode it with a
different set of optimizations:

```
bjd2json -i 2 input.bjd                  # pretty-print
bjd2json -O cts -o packed.bjd input.bjd  # re-encode with SoA enabled
```

Interoperability
----------------

The output has been verified against the reference implementations:

* **pybj 0.6.0** - all values, packed row-major N-d arrays and byte arrays
  round-trip in both directions.
* **nlohmann/json (BJData Draft-4 branch)** - flat SoA records in both layouts,
  including dictionary, offset-table and fixed-width string columns, decode
  identically.

Two constructs of the specification are not understood by those two libraries
today, so they are only emitted on request: column-major packed N-d arrays
(written only when `ColumnMajor` is set) and SoA schemas containing nested
objects or arrays (written only when the data requires them).

License
-------

Apache License, Version 2.0.
