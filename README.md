# haxe-conformance

Conformance tests for Haxe compilers, measured against Haxe 4.3.7.

| Path | Contents |
| --- | --- |
| `tests/` | The test suites of Haxe 4.3.7 ([HaxeFoundation/haxe](https://github.com/HaxeFoundation/haxe), tag `4.3.7`, commit `e0b355c`), unchanged |
| `cases/` | Case families: small programs and command lines whose results are compared with Haxe 4.3.7's |
| `expected/` | Haxe 4.3.7's recorded result for every case whose oracle is `haxe` |
| `harness/` | The runner |

## Install

```bash
haxelib git haxe-conformance https://github.com/dimensionscape/haxe-conformance
```

The runner runs under the installed Haxe, never under the compiler being tested.

## Run

```bash
haxelib run haxe-conformance run --compiler <compiler>
haxelib run haxe-conformance corpus unit,misc --compiler <compiler>
haxelib run haxe-conformance list
```

`run` compares the compiler's result for each case with the recording in `expected/`, or with a
live Haxe given with `--haxe`. `corpus` runs the suites under `tests/` with the compiler
installed as `haxe`, the way Haxe's own CI runs them. With `--haxe`, a suite that fails is run
with that Haxe too and fails only where the compiler fails alone, per project for misc; its
`--divergences` entries are keyed `suite/project`.

`corpus unit-hl` is not in the default set. It builds `tests/unit/compile-hl.hxml` (without `hl-check`)
with the compiler and with `--haxe` (required), requires the two `unit.hl` files to be byte-identical
except for the compile date, and requires both to run alike on `hl.exe` (`--hl-exe`), exit code and
output without the `Generated at:` and `execution time:` lines. The suite expects utest a94f881, the pin in Haxe 4.3.7's CI (`tests/RunCi.hx`); UTest 2, which `haxelib` usually has, changed the `type` of `Assert.raises` to `Any`, so the suite's `exc` helper breaks and `haxe.Log.trace` is left null. The harness therefore exports that commit from the installed utest's git checkout into a cache under the temp root and points `HAXELIB_PATH` at it for both compilers (nothing installed or global changes). Each run's error and failure counts are printed.

| Option | Meaning |
| --- | --- |
| `--compiler <path>` | The compiler under test |
| `--haxe <path>` | Compare with this Haxe instead of the recordings |
| `--std <path>` | `HAXE_STD_PATH` for every compile |
| `--hl-exe <path>` | The `hl` that runs `unit-hl` (default: `hl` on `PATH`) |
| `--cases <dir>`, `--expected <dir>` | Another family root and its recordings |
| `--divergences <file>` | JSON object mapping `family/case` to a reason; listed cases may differ. Repeat it to merge several files |
| `--family a,b`, `--exclude a,b` | Select families by name |
| `--cost`, `--kind`, `--oracle` | Select families by those fields |
| `--shard k/n` | Run the k-th of n slices of the selected cases |
| `-j <n>` | Cases in parallel (default 4) |
| `--timeout <seconds>` | Limit per compile (default 120) |
| `--junit <file>` | Write a JUnit report |

The exit code is 0 when every case passes, 1 when a case fails, a listed divergence matches, or no
case is selected, and 2 for a usage error.

## Cases

A family is a directory under `cases/` holding `family.json`, `cases.hx.txt` and optionally
`fixture/`, which is copied next to every case.

`family.json`:

| Field | Values |
| --- | --- |
| `name` | The family name |
| `oracle` | `haxe` (Haxe 4.3.7's result), `expected` (the case's own `===` block), `self` (two compiles of the same case) |
| `kind` | `compile-diff` (compiler output), `run` (program output), `emit-diff` (generated file), `compile-twice` |
| `cost` | `quick`, `medium`, `slow` |
| `module` | The module a case is written as, default `P` |
| `args` | Compiler arguments; `$module`, `$out`, `$FILE` and `$FILEJSON` are substituted |
| `chdir` | Run the compiler in the case directory instead of passing `--cwd` |
| `live` | Cases whose result depends on the machine; they are compared with the `haxe` on `PATH` |

`cases.hx.txt`:

```
--- case-name [@ pack.Module] [+ extra arguments]
class P { static function main() {} }
===
expected output, for oracle "expected"
```

## Recording

```bash
haxelib run haxe-conformance record --compiler <haxe-4.3.7>
```

Results are compared after normalizing line endings, display timestamps, the case directory
(`$CASE`) and the standard library path (`$STD`).

The recordings were made with hxjava 4.2.0 installed, which the cases that select the JVM target
need.

To move to a newer Haxe, replace `tests/` with the `tests/` directory of that release and record
again.

## License

GPL-2.0-or-later; see [LICENSE](LICENSE). `tests/` is part of Haxe, Copyright (C) 2005-2025 Haxe
Foundation. Everything else is Copyright (C) 2026 Dimensionscape.
