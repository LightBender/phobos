# std.utf string-overload collapse: before / after metrics

Primary goal: fewer template instantiations for string overloads of
`stride`, `strideBack`, `codeLength`, `isValidUTF`, and `validate`.
Secondary goal: smaller generated object size.

Public APIs stay S-templated. Decode / `decodeImpl` / `byUTF` / `byCodeUnit`
were not modified.

## Method

Compared `master` to this branch by compiling
[tools/measure_utf_driver.d](measure_utf_driver.d) against each tree:

```text
dmd -c -vtemplates=list-instances -I<worktree> -of<out>.obj tools/measure_utf_driver.d
```

The driver instantiates the public string APIs across `char` / `wchar` /
`dchar` and mutable / `const` / `immutable` arrays, plus small
`FrontPop` / `BidirCU` ranges so trampolines are not the only bodies in
the object file. `validate` is referenced behind `if (false)` so it is
instantiated without throwing at runtime.

Automation: [tools/measure_templates.d](measure_templates.d) checks out
each ref in a git worktree, compiles the driver, parses DMD
`-vtemplates=list-instances` summaries, and records object size.

```text
dmd -run tools/measure_templates.d --old=master --new=HEAD --driver=tools/measure_utf_driver.d --report=tools/utf_string_overload_metrics.md
```

- Compiler: DMD 2.113.0
- Host: Windows
- Baseline: `master`
- Candidate: `HEAD` (`utf-collapse-string-overloads`)
- `dumpbin` / `nm` were not on `PATH`; symbol tables are omitted.

DMD summary lines look like
`N (M distinct) instantiation(s) of template \`name\``. Totals below
are those `N` / `M` values. Distinct is summed across overloads, so it
is an upper bound on unique bodies.

## Object size

| | bytes |
|---|---:|
| old | 627766 |
| new | 600890 |
| delta | **-26876** (−4.3%) |

Object size is the better bloat signal. The trampolines remain
templates (one instantiation per string type), but the large UTF-8 /
UTF-16 bodies are now shared non-template `const(C)[]` implementations.

## `-vtemplates=list-instances`

| | old | new | delta |
|---|---:|---:|---:|
| log lines | 3600 | 3499 | −101 |
| summary records | 115 | 121 | +6 |
| total instantiations | 3485 | 3378 | **−107** |
| distinct instantiations (sum) | 809 | 767 | **−42** |
| instance lines | 3485 | 3378 | −107 |

### Focused APIs (DMD summary totals / distinct)

| name | old total | new total | Δ total | old distinct | new distinct | Δ distinct |
|---|---:|---:|---:|---:|---:|---:|
| `stride` | 24 | 21 | −3 | 18 | 18 | 0 |
| `strideBack` | 37 | 34 | −3 | 32 | 32 | 0 |
| `codeLength` | 60 | 60 | 0 | 33 | 27 | **−6** |
| `isValidUTF` | 9 | 9 | 0 | 9 | 9 | 0 |
| `isValidUTFImpl` | 0 | 9 | +9 | 0 | 3 | +3 |
| `validate` | 9 | 9 | 0 | 9 | 9 | 0 |
| `validateImpl` | 0 | 9 | +9 | 0 | 3 | +3 |
| `decode` | 19 | 9 | **−10** | 14 | 5 | **−9** |
| `decodeImpl` | 28 | 19 | **−9** | 18 | 13 | **−5** |
| `decodeFront` | 22 | 22 | 0 | 16 | 16 | 0 |
| `decodeBack` | 18 | 18 | 0 | 12 | 12 | 0 |
| `byUTF` | 94 | 94 | 0 | 51 | 51 | 0 |

## Interpretation

- **Trampolines vs shared bodies.** `stride` / `strideBack` still
  instantiate once per string type (the public trampoline). Distinct
  counts therefore barely move. The win is that `string`, `char[]`, and
  `const(char)[]` (and the wchar analogs, including static arrays via
  `cast(const(C)[])`) share one `strideUTF8` / `strideUTF16` /
  `strideBackUTF8` / `strideBackUTF16` body. That shows up in object
  size, not in trampoline instantiation counts.
- **`codeLength`.** Matching strings now hit the identity
  `codeLength(C)(const(C)[] input)` (3 encodings) instead of the
  transcoding range overload. Distinct `codeLength` instantiations drop
  by 6; total call sites stay 60 because the driver still asks for every
  encoding combination.
- **`isValidUTF` / `validate`.** Public S-templates remain (9 string
  types). The heavy work moves to `isValidUTFImpl` / `validateImpl` with
  3 encodings. Extra summary records (+6 overall) are these new impl
  templates; they replace duplicated string-typed bodies.
- **`decode` / `decodeImpl` source is unchanged.** Instantiations still
  drop because `validateImpl` / `isValidUTFImpl` now pass `const(C)[]`,
  so decode is instantiated for three encodings rather than each string
  qualifier. `byUTF` is unchanged, as intended.
- **Do not fold the trampoline into the large body.** A previous
  `byUTF` experiment that merged two entry points into one function
  with a `static if` at the front *increased* object size. Tiny
  trampolines around a shared implementation is the pattern that
  actually shrinks generated code.

## Tests

`std/utf.d` unittests pass in both modes:

```text
dmd -main -unittest -version=StdUnittest -I. -oftestutf.exe std/utf.d && testutf.exe
dmd -main -unittest -version=StdUnittest -version=NoAutodecodeStrings -I. -oftestutf_na.exe std/utf.d && testutf_na.exe
```

Both printed `1 modules passed unittests`.

## Implementation notes (for reviewers)

- Public overloads stay S-templated. A public non-template
  `const(dchar)[]` next to `const(char)[]` clashes with autodecode
  (`is(S : const dchar[])`).
- Trampolines use `cast(const(char)[])` / wchar / dchar, not
  `is(immutable S == immutable C[], C)`, so static arrays such as
  `char[4]` still compile (`buf.stride` in encode unittests).
- Range overloads exclude strings (`!is(S : const char[])` and
  analogs) so they do not duplicate the string body.
- UTF-16 private impls are `@safe pure nothrow @nogc`. Non-template
  helpers do not infer `nothrow`; without it, `byUTF` `Result.back`
  failed under `-version=NoAutodecodeStrings`.
- UTF-8 private impls stay `@safe pure` (they can throw `UTFException`).
- dchar `stride` / `strideBack` remain the original S-templates.
- Decode pointer arithmetic (`str.ptr + index`, `decodeImpl!(true, ...)`)
  was not touched.
