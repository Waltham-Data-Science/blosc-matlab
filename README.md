# blosc-matlab

MATLAB MEX bindings for [Blosc v1](https://github.com/Blosc/c-blosc). Compresses and decompresses byte arrays with the same container format as Python's [numcodecs.Blosc](https://numcodecs.readthedocs.io/en/stable/blosc.html), so a chunk written by NumPy/Zarr on one side round-trips on the other.

Ships as a small MATLAB package (`+blosc`) plus a MEX file. No Python, no subprocess, no pipe: encode/decode is a direct C call in ~microseconds.

## Why

Blosc is the container format Zarr v2 stores use for compressed chunks. Reading a lightsheet or brainbow OME-Zarr from MATLAB, or writing one, means encoding and decoding thousands of small Blosc containers. Prior tools either shelled out to `python` (subprocess spawn per call — tens to hundreds of milliseconds each) or required MATLAB's `pyenv` (steals the customer's Python configuration). This library is the missing middle: one MEX call, no external process.

## Install

One line in MATLAB. Clone the repo (or just download the top-level MATLAB files), `cd` into it, and run:

```matlab
install
```

`install.m` detects your platform (`mexext` + `computer`), fetches the matching prebuilt from the [latest GitHub release](https://github.com/Waltham-Data-Science/blosc-matlab/releases/latest), drops the MEX file into `+blosc/private/`, and adds the package to your path. Idempotent — running it again is a no-op unless you pass `'Force', true`.

```matlab
>> blosc.version()
ans =
  struct with fields:
     blosc: '1.21.6'
    codecs: {'blosclz', 'lz4', 'lz4hc', 'zlib', 'zstd'}
```

Prebuilt targets: **macOS Apple Silicon**, **Linux x64**, **Windows x64**. Two platforms currently require a source build via `build` (see below):

- **macOS Intel** — GitHub is retiring the `macos-13` runner (their only Intel image), so we no longer attach a `mexmaci64` prebuilt. Intel Mac users compile from source; we may add a Rosetta-based Intel lane on the Apple Silicon runner if demand appears.
- **Linux arm64** — `matlab-actions/setup-matlab` does not yet support Linux arm runners.

**Pin a version** if you want reproducibility:

```matlab
install('Version', 'v0.2.0')
```

**Build from source** (needs a C compiler and CMake) — for platforms without a prebuilt or for local development:

```bash
git clone --recursive https://github.com/Waltham-Data-Science/blosc-matlab
```

then in MATLAB:

```matlab
cd /path/to/blosc-matlab
build   % compiles src/blosc_mex.c against the vendored c-blosc
```

The `--recursive` clone pulls the `c-blosc` submodule.

## Use

```matlab
% Encode one array
data = uint16(randi([0 65535], 1, 4096));
container = blosc.encode(data, 'cname', 'zstd', 'clevel', 5);

% Decode
back = blosc.decode(container);
recovered = typecast(back, 'uint16');
isequal(recovered(:).', data(:).')     % true

% Batch encode / decode (loop over MEX; each call ~µs)
containers = blosc.encodeMany({raw1, raw2, raw3}, 'cname', 'zstd', 'clevel', 5);
decoded    = blosc.decodeMany(containers);

% Peek at a container without decoding
h = blosc.header(container);   % .cname .clevel .typesize .nbytes .cbytes
```

## Codecs

Bundled with C-Blosc 1.21.x: `blosclz`, `lz4`, `lz4hc`, `zlib`, `zstd`. Snappy is not built (avoids its optional GPL considerations and it's rarely used in scientific data).

## Container compatibility

Byte-for-byte identical to what `numcodecs.Blosc` (Python) writes and reads. A Zarr store written by MATLAB is readable by NumPy, and vice versa.

## License

- The MATLAB wrapper and MEX source (this repository, minus `src/c-blosc/`) are MIT licensed — see [LICENSE](LICENSE).
- The vendored C-Blosc library at `src/c-blosc/` is BSD-3-Clause — see [LICENSE-C-BLOSC](LICENSE-C-BLOSC).

## Building the prebuilts

GitHub Actions builds `.mexmaca64`, `.mexmaci64`, `.mexa64` (x64 + arm64), and `.mexw64` on every push and attaches them to tagged releases. See [`.github/workflows/build.yml`](.github/workflows/build.yml).
