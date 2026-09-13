/*
 * blosc_mex.c - MATLAB MEX bindings for Blosc v1
 *
 * Calling convention (dispatched by the first argument, a string):
 *
 *   out = blosc_mex('encode', rawBytes, cname, clevel, shuffle, typesize, blocksize)
 *     rawBytes : uint8 column vector
 *     cname    : char row: 'blosclz','lz4','lz4hc','zlib','zstd'
 *     clevel   : int32 in [0..9]
 *     shuffle  : int32 in {0,1,2}
 *     typesize : int32 >= 1
 *     blocksize: int32 >= 0 (0 = auto)
 *     returns  : uint8 column vector, one Blosc-1 container
 *
 *   out = blosc_mex('decode', container)
 *     container: uint8 column vector, one Blosc-1 container
 *     returns  : uint8 column vector, raw decompressed bytes
 *
 *   h = blosc_mex('header', container)
 *     container: uint8 column vector
 *     returns  : struct with numeric fields
 *                cname (char), clevel, shuffle, typesize, nbytes, cbytes
 *
 *   v = blosc_mex('version')
 *     returns  : struct with fields
 *                blosc  (char, e.g. '1.21.6')
 *                codecs (cellstr of built-in codecs)
 *
 * Container format is Blosc v1; byte-for-byte compatible with
 * numcodecs.Blosc. See src/c-blosc/README.md for details.
 *
 * All bookkeeping stays inside the MEX call. No global state, no
 * threads (blosc_compress_ctx / blosc_decompress_ctx are the
 * thread-safe context APIs).
 */

#include "mex.h"
#include "blosc.h"

#include <string.h>
#include <stdint.h>

/* ---- Small helpers -------------------------------------------------- */

static const char *readCharArg(const mxArray *a, const char *argName) {
    if (!mxIsChar(a) || mxGetM(a) != 1) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArg",
            "%s must be a char row.", argName);
    }
    /* mxArrayToString allocs; we release with mxFree via caller pattern
       -- but the small size and single-shot per call makes leak
       management trivial: MATLAB's per-mex-call arena reclaims. */
    return mxArrayToString(a);
}

static int readInt32Arg(const mxArray *a, const char *argName) {
    if (!mxIsNumeric(a) || mxGetNumberOfElements(a) != 1) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArg",
            "%s must be a scalar integer.", argName);
    }
    return (int)mxGetScalar(a);
}

static const uint8_t *readByteArg(const mxArray *a, size_t *nOut,
                                  const char *argName) {
    if (!mxIsUint8(a)) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArg",
            "%s must be uint8.", argName);
    }
    *nOut = mxGetNumberOfElements(a);
    return (const uint8_t *)mxGetData(a);
}

static mxArray *bytesToMx(const uint8_t *bytes, size_t n) {
    mxArray *out = mxCreateNumericMatrix((mwSize)n, 1, mxUINT8_CLASS, mxREAL);
    if (n > 0) {
        memcpy(mxGetData(out), bytes, n);
    }
    return out;
}

/* ---- Sub-command implementations ------------------------------------ */

static void doEncode(int nrhs, const mxArray *prhs[],
                     int nlhs, mxArray *plhs[]) {
    if (nrhs != 7) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArgs",
            "encode: expected 6 arguments after the verb "
            "(rawBytes, cname, clevel, shuffle, typesize, blocksize).");
    }
    size_t nSrc;
    const uint8_t *src = readByteArg(prhs[1], &nSrc, "rawBytes");
    const char *cname = readCharArg(prhs[2], "cname");
    int clevel   = readInt32Arg(prhs[3], "clevel");
    int shuffle  = readInt32Arg(prhs[4], "shuffle");
    int typesize = readInt32Arg(prhs[5], "typesize");
    int blocksize = readInt32Arg(prhs[6], "blocksize");

    if (typesize < 1) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadTypesize",
            "typesize must be >= 1, got %d.", typesize);
    }
    if (nSrc % (size_t)typesize != 0) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:LengthMismatch",
            "Input length %zu is not a multiple of typesize %d.",
            nSrc, typesize);
    }

    /* Worst-case output size per Blosc's contract. */
    size_t bufSize = nSrc + BLOSC_MAX_OVERHEAD;
    uint8_t *dst = (uint8_t *)mxMalloc(bufSize);

    int rc = blosc_compress_ctx(
        clevel, shuffle, (size_t)typesize,
        nSrc, src, dst, bufSize,
        cname, (size_t)blocksize, 1 /* nthreads */);

    if (rc < 0) {
        mxFree(dst);
        mexErrMsgIdAndTxt("blosc_matlab:mex:CompressFailed",
            "blosc_compress_ctx returned %d.", rc);
    }

    plhs[0] = bytesToMx(dst, (size_t)rc);
    mxFree(dst);
}

static void doDecode(int nrhs, const mxArray *prhs[],
                     int nlhs, mxArray *plhs[]) {
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArgs",
            "decode: expected 1 argument after the verb (container).");
    }
    size_t nSrc;
    const uint8_t *src = readByteArg(prhs[1], &nSrc, "container");

    /* The uncompressed size is recorded in the container header, so
       we can allocate exactly. */
    size_t nbytes = 0, cbytes = 0, blocksize = 0;
    blosc_cbuffer_sizes(src, &nbytes, &cbytes, &blocksize);
    if (cbytes == 0 || cbytes > nSrc) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadContainer",
            "Container header says cbytes=%zu, buffer has %zu bytes.",
            cbytes, nSrc);
    }

    uint8_t *dst = (uint8_t *)mxMalloc(nbytes > 0 ? nbytes : 1);
    int rc = blosc_decompress_ctx(src, dst, nbytes, 1 /* nthreads */);
    if (rc < 0) {
        mxFree(dst);
        mexErrMsgIdAndTxt("blosc_matlab:mex:DecompressFailed",
            "blosc_decompress_ctx returned %d.", rc);
    }

    plhs[0] = bytesToMx(dst, nbytes);
    mxFree(dst);
}

static void doHeader(int nrhs, const mxArray *prhs[],
                     int nlhs, mxArray *plhs[]) {
    if (nrhs != 2) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArgs",
            "header: expected 1 argument after the verb (container).");
    }
    size_t nSrc;
    const uint8_t *src = readByteArg(prhs[1], &nSrc, "container");
    if (nSrc < 16) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadContainer",
            "Container must be at least 16 bytes (header).");
    }

    size_t nbytes = 0, cbytes = 0, blocksize = 0;
    blosc_cbuffer_sizes(src, &nbytes, &cbytes, &blocksize);

    /* We do the byte peek for cname/clevel/shuffle/typesize the same
       way numcodecs does -- from the raw header bytes. That avoids a
       dependence on any private symbol. Fields:
         byte 2  flags (bit 0: byte shuffle, bit 1: no shuffle, bit 2: bit shuffle)
         byte 3  typesize
         byte 15 clevel (per numcodecs)
         cname  looked up via blosc_get_compressor_from_id(complib)
       See c-blosc's blosc/blosc.h for header layout.
    */
    uint8_t flags    = src[2];
    int     typesize = (int)src[3];
    int     complib  = (src[2] & 0xE0) >> 5;

    int shuffleVal = 0;
    if (flags & 0x01) shuffleVal = 1;      /* byte shuffle */
    else if (flags & 0x02) shuffleVal = 0; /* no shuffle */
    if (flags & 0x04) shuffleVal = 2;      /* bit shuffle */

    int clevel = 0;
    if (nSrc > 15) {
        clevel = (int)src[15];
    }

    const char *cname = blosc_get_compressor_from_id(complib);
    if (cname == NULL) cname = "unknown";

    const char *fields[] = {"cname", "clevel", "shuffle", "typesize",
                            "nbytes", "cbytes", "blocksize"};
    mxArray *s = mxCreateStructMatrix(1, 1, 7, fields);
    mxSetField(s, 0, "cname",     mxCreateString(cname));
    mxSetField(s, 0, "clevel",    mxCreateDoubleScalar((double)clevel));
    mxSetField(s, 0, "shuffle",   mxCreateDoubleScalar((double)shuffleVal));
    mxSetField(s, 0, "typesize",  mxCreateDoubleScalar((double)typesize));
    mxSetField(s, 0, "nbytes",    mxCreateDoubleScalar((double)nbytes));
    mxSetField(s, 0, "cbytes",    mxCreateDoubleScalar((double)cbytes));
    mxSetField(s, 0, "blocksize", mxCreateDoubleScalar((double)blocksize));
    plhs[0] = s;
}

static void doVersion(int nrhs, const mxArray *prhs[],
                      int nlhs, mxArray *plhs[]) {
    (void)nrhs; (void)prhs;

    /* Blosc string: e.g. "1.21.6 ($Date:: 2024-..-..#$)" */
    const char *bloscStr = BLOSC_VERSION_STRING;

    char codecs[512];
    codecs[0] = '\0';
    int n = blosc_list_compressors_len();
    /* blosc_list_compressors returns a comma-separated char*. */
    const char *list = blosc_list_compressors();
    if (list) {
        strncpy(codecs, list, sizeof(codecs) - 1);
        codecs[sizeof(codecs) - 1] = '\0';
    }
    (void)n;

    /* Split codecs on comma into a MATLAB cellstr. */
    int nCodecs = 0;
    for (const char *p = codecs; *p; ++p) if (*p == ',') ++nCodecs;
    if (codecs[0] != '\0') ++nCodecs;
    mxArray *cell = mxCreateCellMatrix(1, nCodecs);
    int i = 0;
    char *save = NULL;
    char *tok = codecs;
    char *comma;
    while (tok && *tok) {
        comma = strchr(tok, ',');
        if (comma) *comma = '\0';
        mxSetCell(cell, i++, mxCreateString(tok));
        if (comma) tok = comma + 1;
        else break;
    }
    (void)save;

    const char *fields[] = {"blosc", "codecs"};
    mxArray *s = mxCreateStructMatrix(1, 1, 2, fields);
    mxSetField(s, 0, "blosc",  mxCreateString(bloscStr));
    mxSetField(s, 0, "codecs", cell);
    plhs[0] = s;
}

/* ---- Entry point ---------------------------------------------------- */

void mexFunction(int nlhs, mxArray *plhs[],
                 int nrhs, const mxArray *prhs[]) {
    if (nrhs < 1) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArgs",
            "Usage: blosc_mex(verb, ...). Verbs: encode, decode, "
            "header, version.");
    }
    const char *verb = readCharArg(prhs[0], "verb");

    if (strcmp(verb, "encode") == 0) {
        doEncode(nrhs, prhs, nlhs, plhs);
    } else if (strcmp(verb, "decode") == 0) {
        doDecode(nrhs, prhs, nlhs, plhs);
    } else if (strcmp(verb, "header") == 0) {
        doHeader(nrhs, prhs, nlhs, plhs);
    } else if (strcmp(verb, "version") == 0) {
        doVersion(nrhs, prhs, nlhs, plhs);
    } else {
        mexErrMsgIdAndTxt("blosc_matlab:mex:UnknownVerb",
            "Unknown verb '%s'.", verb);
    }
}
