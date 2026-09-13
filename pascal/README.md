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

Reading without building a tree
-------------------------------

`TBJData.View` returns a `TBJValue`, a cursor over the buffer that allocates
nothing. Navigating it decodes straight from the bytes, whole subtrees are
stepped over without being looked at, and strings and packed payloads can be
read where they lie. The buffer has to stay alive and unchanged for as long as
any view of it is used.

```pascal
var
  buf: TBytes;
  root, rec: TBJValue;
begin
  buf := ReadWholeFile('events.bjd');
  for rec in TBJData.View(buf) do                  // no allocation per record
    if rec.Find('type').TextEquals('PushEvent') then
      WriteLn(rec.Path('actor.id').AsInt64);
end;
```

`TBJValue` answers `Kind`, `Marker`, `AsInt64`, `AsDouble`, `AsString`,
`AsBoolean`, `Count`, `Item`, `Find`, `Path` and `for..in`, plus `TextPtr` /
`TextLength` / `TextEquals` for comparing strings without copying them and
`DataPtr` / `DataSize` / `ElemMarker` / `Dim` for addressing a packed array in
place. `ToData` materialises any subtree as a `TBJData` tree when a document
does need to be held, changed or re-encoded.

When it pays off, measured on the same files as above:

| Workload | cursor | tree | |
|---|---|---|---|
| sum 7 M values of packed numeric arrays | 0.016 s | 0.083 s | **5.2x** |
| pull two fields out of every record of a 24 MB table | 0.021 s | 0.070 s | **3.3x** |
| touch every one of 634 K values in a 24 MB document | 0.085 s | 0.082 s | 1.0x |

The pattern is the one lazy parsers always have: a cursor wins by *not* doing
work, so it wins when a document is bigger than the part of it that is needed,
and it draws level when every value is read anyway, because it then decodes
each value instead of reading one that has already been decoded. Reach for the
tree when a document is small, when it is read repeatedly, or when it has to be
modified; reach for the cursor when a large file is scanned once.

### Editing a buffer in place

A view is read-only, but the bytes behind it are yours, and BJData is friendly
to patching:

* **Same size always works.** Every fixed-width value (`i U I u l m L M h d D
  C B`) can be overwritten with another of the same marker, and every element
  of a packed array can be overwritten through `DataPtr`, without touching a
  single byte around it. This is what makes it practical to correct a field in
  a memory-mapped file that is larger than memory.
* **Smaller works if the slack is filled with no-ops.** A shorter string can be
  written over a longer one and the freed bytes set to `N` (0x4E), which a
  decoder has to skip. This library skips them wherever a value or a pair can
  begin, including inside counted and typed containers, and the padding does
  not count towards a container's promised child count. It cannot be used
  inside a packed `[$type#...]` payload, which has no markers to hide in.
* **Larger does not work in place.** The value would overrun its neighbour, so
  everything after it has to move. Rebuild that part of the document instead:
  `ToData` the subtree, change it, and write it back out.

Two limits worth knowing: a structure-of-arrays record cannot be browsed field
by field (the cursor reports `IsSoA` and `ToData` materialises it), and
`DataPtr` hands back the little-endian bytes of the file, so on a big-endian
host use `ElemAsInt64` / `ElemAsDouble` instead.

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

Performance
-----------

Measured with `test/bench.lpr` (FPC 3.2.2, `-O2`, x86-64 Linux), best of seven
runs with the file already in memory. The reference is the C extension of
[pybj](https://github.com/NeuroJSON/pybj) 0.6.0 on the same files and machine.

| Document | | bjdata.pas | pybj 0.6.0 (C) |
|---|---|---|---|
| 24 MB of GitHub events (`largebj`), strings and small objects | decode | **556 MB/s** | 295 MB/s |
| | encode | **509 MB/s** | 459 MB/s |
| | to JSON | 208 MB/s | - |
| 0.4 MB catalogue (`citm`), deeply nested objects | decode | **188 MB/s** | 110 MB/s |
| | encode | **376 MB/s** | 107 MB/s |
| 19 MB of packed numeric arrays | decode | 6.4 GB/s | 28 GB/s |
| | encode | 3.2 GB/s | 4.8 GB/s |

Two notes on the numbers:

* On packed arrays pybj is faster because it hands the payload to NumPy as a
  view of the input buffer, while `TBJData` copies it into a node that owns its
  memory and outlives the buffer. Both are then bound by memory bandwidth.
* Decoding builds a full document tree, so releasing it costs real time as
  well: `doc.Free` on the 24 MB document takes about 26 ms, and the benchmark
  reports it separately rather than hiding it.

### Where the time goes

`bench -s` also walks a document without building anything, which is the byte
processing floor of the format:

| | tree | structural scan only |
|---|---|---|
| 24 MB of GitHub events | 552 MB/s | 2788 MB/s |
| 0.4 MB catalogue | 207 MB/s | 1093 MB/s |

So roughly a fifth of decoding is reading bytes and four fifths is allocating
nodes, copying strings and linking the tree. That is worth knowing before
reaching for wider loads or SIMD: the markers of a BJData stream are already
self-describing, there is nothing to search for and nothing to un-escape, so
vectorising the scan can only touch that fifth.

### N-dimensional arrays

An N-d array is an optimized container whose count marker is followed by a
dimension vector rather than a single number, so the shape travels with the
data and the payload stays one contiguous block:

```
[ $ D # [ $ i # i 3  2 3 4 ]   <24 doubles>        row-major
[ $ D # [ [ $ i # i 3  2 3 4 ] ] <24 doubles>      column-major
```

```pascal
vol := TBJData.NewTypedArray('D', [2, 3, 4]);      // or 'l', 'U', 'h', ...
vol.SetElem(vol.Offset([1, 2, 3]), 42.0);          // subscripts to offset
vol.ColumnMajor := True;                           // the other layout
WriteLn(vol.DimCount, 'd ', vol.Dim[0], 'x', vol.Dim[1], 'x', vol.Dim[2]);
```

`Offset` maps a subscript list to a position in the payload and follows the
layout flag, so the same indexing code works for either order. Element
accessors, `ToJSON` and `ExpandTypedArray` all present the array in row-major
order whichever way it is stored. Through a view the payload can be used where
it lies:

```pascal
v := TBJData.View(buf).Find('volume');
p := PDouble(v.DataPtr);                           // no copy
WriteLn(p[v.Offset([1, 2, 3])]);
```

`examples/ndarray.lpr` (`make example`) walks through all of this and prints
the bytes it produces. A reader here also accepts the dimension vector on a
plain counted array (`[#[$i#i2 2 3]` followed by individually tagged values),
which is useful for a mixed-type grid, but the writer never produces it
because the specification defines the shape only for a uniform element type.

### Use packed arrays

The single biggest performance decision is in the *data*, not the parser. The
same two million values, stored as a packed array and as individually tagged
elements:

| | packed `[$type#[...]` | one tag per element | |
|---|---|---|---|
| 2 M float64, decode | 0.003 s | 0.060 s | **20x** |
| 2 M uint16, decode | 0.001 s | 0.062 s | **62x** |
| 2 M float64, encode | 0.003 s | 0.047 s | **15x** |
| 2 M uint16, encode | 0.001 s | 0.053 s | **55x** |

A packed array is a length and a memcpy; a tagged sequence is a node per
element. This is the same effect other binary formats report when they compare
a typed-array format against one without typed arrays, and it is the reason to
write numeric data through `NewTypedArray` rather than as a generic array.

What the decoder does to get there, in rough order of what it was worth:

* no `try..except` around each container - a container being filled is pushed
  on a small stack instead, and one frame in `Parse` releases the stack if the
  document turns out to be broken (a `setjmp` per container was 21% of decoding)
* no implicit finalization frames in the hot routines: error messages are
  formatted in separate routines, and strings are read straight into the field
  that will hold them instead of through a local variable
* nodes are allocated with `NewInstance` rather than a constructor, because a
  constructor of a class with managed fields carries its own exception frame
* a direct-mapped cache of recently seen object keys: documents repeat the same
  field names over and over, and sharing those strings removes an allocation, a
  copy and a release per key
* `FreeInstance` finalizes the five managed fields directly instead of walking
  the field RTTI table, which halves the cost of releasing a document
* one-byte lengths and counts are decoded inline, and output goes through a
  64 KB buffer instead of one stream call per marker byte

The result is 2.5x the decoding speed of the first working version, from the
same source, with the same output: `test/bench.lpr` and the regression suite
were run against both.

Building and testing
--------------------

```
make test        # build and run the regression suite
make tools       # build bjd2json
make bench BENCHFILES=big.bjd    # time the decoder, the encoder and ToJSON
build/bench -s -n 9 big.bjd      # add a structural scan with no tree building
build/bench -l -k type actor.id big.bjd   # compare the cursor against the tree
make cross       # additionally cross-check against the python bjdata module
```

`test/bjdtest.lpr` holds 168 checks covering the examples of the specification,
round-trips and error handling, including a sweep that parses every prefix and
every single-byte corruption of a document to confirm that malformed input is
rejected without crashing or leaking (run the suite with `-gh` to verify the
second part). `test/crosscheck.py` encodes a set of documents
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
