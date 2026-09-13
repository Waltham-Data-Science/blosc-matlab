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

/* Class name -> element size in bytes. Only the numeric MATLAB classes
   Blosc-matlab encodes are supported here. Returns 0 for unsupported. */
static size_t mlClassSize(mxClassID cls) {
    switch (cls) {
        case mxLOGICAL_CLASS:
        case mxUINT8_CLASS:
        case mxINT8_CLASS:    return 1;
        case mxUINT16_CLASS:
        case mxINT16_CLASS:   return 2;
        case mxUINT32_CLASS:
        case mxINT32_CLASS:
        case mxSINGLE_CLASS:  return 4;
        case mxUINT64_CLASS:
        case mxINT64_CLASS:
        case mxDOUBLE_CLASS:  return 8;
        default: return 0;
    }
}

/* Read a numeric row vector of shape into targetShape[], returning its
   length. Errors out on shape mismatch. */
static int readShapeArg(const mxArray *a, mwSize *targetShape,
                        int maxNd, const char *argName) {
    if (!mxIsNumeric(a) || mxIsComplex(a)) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArg",
            "%s must be a numeric row vector.", argName);
    }
    size_t n = mxGetNumberOfElements(a);
    if (n < 1 || n > (size_t)maxNd) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArg",
            "%s must have between 1 and %d elements, got %zu.",
            argName, maxNd, n);
    }
    double *p = mxGetPr(a);
    for (size_t i = 0; i < n; ++i) {
        if (p[i] < 1 || p[i] != (mwSize)p[i]) {
            mexErrMsgIdAndTxt("blosc_matlab:mex:BadArg",
                "%s must be a vector of positive integers.", argName);
        }
        targetShape[i] = (mwSize)p[i];
    }
    return (int)n;
}

/* Iterate every element position in a C-order-flattened target buffer of
   shape targetShape[] with typesize bytes per element. For each position
   whose Fortran-indexed counterpart lies inside srcShape[], memcpy the
   src element there; otherwise write padByte (typesize copies of it).

   axisOrder == 'C' means the OUTPUT buffer is C-order (last axis is
   fastest, standard Zarr/NumPy convention). MATLAB inputs are always
   Fortran-order.

   Note: axisOrder='F' path is degenerate -- src and dst are both
   Fortran-order, so a pad-only copy suffices. We still support it for
   symmetry with the decoder.
*/
static void padAndReorder(const uint8_t *src, uint8_t *dst,
                          const mwSize *srcShape, const mwSize *targetShape,
                          int nd, size_t typesize, char axisOrder,
                          const uint8_t *padBytes) {
    size_t nTarget = 1;
    for (int i = 0; i < nd; ++i) nTarget *= (size_t)targetShape[i];

    /* Cumulative strides. srcStride[k] = product of srcShape[0..k-1]:
       Fortran-order strides where axis 0 is fastest.
       cStride[k] = product of targetShape[k+1..nd-1]:
       C-order strides where the last axis is fastest.
       fStride[k] = product of targetShape[0..k-1]:
       Fortran-order strides on the target (for axisOrder='F'). */
    size_t srcStride[32], cStride[32], fStride[32];
    if (nd > 32) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:TooManyAxes",
            "chunk has %d axes, this MEX supports at most 32.", nd);
    }
    srcStride[0] = 1;
    for (int k = 1; k < nd; ++k) srcStride[k] = srcStride[k-1] * (size_t)srcShape[k-1];
    cStride[nd-1] = 1;
    for (int k = nd-2; k >= 0; --k) cStride[k] = cStride[k+1] * (size_t)targetShape[k+1];
    fStride[0] = 1;
    for (int k = 1; k < nd; ++k) fStride[k] = fStride[k-1] * (size_t)targetShape[k-1];

    /* Multi-index. */
    mwSize idx[32];
    for (int k = 0; k < nd; ++k) idx[k] = 0;

    size_t written = 0;
    while (written < nTarget) {
        int inside = 1;
        for (int k = 0; k < nd; ++k) {
            if (idx[k] >= srcShape[k]) { inside = 0; break; }
        }
        /* Compute output offset (C-order or F-order on target). */
        size_t oOff = 0;
        if (axisOrder == 'C') {
            for (int k = 0; k < nd; ++k) oOff += idx[k] * cStride[k];
        } else {
            for (int k = 0; k < nd; ++k) oOff += idx[k] * fStride[k];
        }
        oOff *= typesize;
        if (inside) {
            size_t iOff = 0;
            for (int k = 0; k < nd; ++k) iOff += idx[k] * srcStride[k];
            iOff *= typesize;
            memcpy(dst + oOff, src + iOff, typesize);
        } else {
            /* Copy padBytes typesize bytes (already replicated). */
            memcpy(dst + oOff, padBytes, typesize);
        }
        /* Increment multi-index (odometer). */
        for (int k = 0; k < nd; ++k) {
            if (++idx[k] < targetShape[k]) break;
            idx[k] = 0;
        }
        ++written;
    }
}

/* Inverse of padAndReorder: input buffer is a C-order (or F-order)
   flat buffer of shape bufShape[]; write it as Fortran-order elements
   of a MATLAB array of shape outShape[]. bufShape and outShape must
   match here (no cropping on decode). */
static void reorderToFortran(const uint8_t *src, uint8_t *dst,
                             const mwSize *shape, int nd,
                             size_t typesize, char axisOrder) {
    size_t n = 1;
    for (int i = 0; i < nd; ++i) n *= (size_t)shape[i];

    size_t cStride[32], fStride[32];
    if (nd > 32) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:TooManyAxes",
            "chunk has %d axes, this MEX supports at most 32.", nd);
    }
    cStride[nd-1] = 1;
    for (int k = nd-2; k >= 0; --k) cStride[k] = cStride[k+1] * (size_t)shape[k+1];
    fStride[0] = 1;
    for (int k = 1; k < nd; ++k) fStride[k] = fStride[k-1] * (size_t)shape[k-1];

    mwSize idx[32];
    for (int k = 0; k < nd; ++k) idx[k] = 0;
    size_t written = 0;
    while (written < n) {
        size_t iOff = 0;
        if (axisOrder == 'C') {
            for (int k = 0; k < nd; ++k) iOff += idx[k] * cStride[k];
        } else {
            for (int k = 0; k < nd; ++k) iOff += idx[k] * fStride[k];
        }
        iOff *= typesize;
        size_t oOff = 0;
        for (int k = 0; k < nd; ++k) oOff += idx[k] * fStride[k];
        oOff *= typesize;
        memcpy(dst + oOff, src + iOff, typesize);
        for (int k = 0; k < nd; ++k) {
            if (++idx[k] < shape[k]) break;
            idx[k] = 0;
        }
        ++written;
    }
}

static void doEncodeChunk(int nrhs, const mxArray *prhs[],
                          int nlhs, mxArray *plhs[]) {
    /* encode_chunk(tile, targetShape, cname, clevel, shuffle,
                    blocksize, axisOrder, padByte0..padByteN) */
    if (nrhs < 8) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArgs",
            "encode_chunk: expected (tile, targetShape, cname, clevel, "
            "shuffle, blocksize, axisOrder, padBytes).");
    }
    const mxArray *tile = prhs[1];
    if (!mxIsNumeric(tile) && !mxIsLogical(tile)) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArg",
            "tile must be a numeric or logical array.");
    }
    size_t typesize = mlClassSize(mxGetClassID(tile));
    if (typesize == 0) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArg",
            "tile has unsupported class %s.", mxGetClassName(tile));
    }

    mwSize targetShape[32];
    int nd = readShapeArg(prhs[2], targetShape, 32, "targetShape");

    /* Get tile's actual shape, padded with 1s if lower rank. */
    mwSize srcShape[32];
    int srcNd = (int)mxGetNumberOfDimensions(tile);
    const mwSize *srcDims = mxGetDimensions(tile);
    for (int k = 0; k < nd; ++k) {
        srcShape[k] = (k < srcNd) ? srcDims[k] : 1;
        if (srcShape[k] > targetShape[k]) {
            mexErrMsgIdAndTxt("blosc_matlab:mex:LengthMismatch",
                "tile axis %d has %llu elements, exceeds target %llu.",
                k+1, (unsigned long long)srcShape[k],
                (unsigned long long)targetShape[k]);
        }
    }
    const char *cname = readCharArg(prhs[3], "cname");
    int clevel    = readInt32Arg(prhs[4], "clevel");
    int shuffle   = readInt32Arg(prhs[5], "shuffle");
    int blocksize = readInt32Arg(prhs[6], "blocksize");
    const char *axisStr = readCharArg(prhs[7], "axisOrder");
    char axisOrder = (axisStr && (axisStr[0] == 'C' || axisStr[0] == 'c'))
        ? 'C' : 'F';

    /* padBytes: typesize bytes packed into a uint8 vector. Callers
       fabricate this from a padValue of the tile's own class. */
    size_t padLen = 0;
    const uint8_t *padBytes = readByteArg(prhs[8], &padLen, "padBytes");
    if (padLen != typesize) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArg",
            "padBytes has %zu bytes but tile typesize is %zu.",
            padLen, typesize);
    }

    /* Assemble the padded, reordered byte buffer. */
    size_t nTarget = 1;
    for (int k = 0; k < nd; ++k) nTarget *= (size_t)targetShape[k];
    size_t bufBytes = nTarget * typesize;
    uint8_t *buf = (uint8_t *)mxMalloc(bufBytes > 0 ? bufBytes : 1);
    padAndReorder((const uint8_t *)mxGetData(tile), buf,
                  srcShape, targetShape, nd, typesize, axisOrder, padBytes);

    /* Encode. Same call pattern as doEncode. */
    size_t outCap = bufBytes + BLOSC_MAX_OVERHEAD;
    uint8_t *out = (uint8_t *)mxMalloc(outCap);
    int rc = blosc_compress_ctx(
        clevel, shuffle, typesize,
        bufBytes, buf, out, outCap,
        cname, (size_t)blocksize, 1);
    mxFree(buf);
    if (rc < 0) {
        mxFree(out);
        mexErrMsgIdAndTxt("blosc_matlab:mex:CompressFailed",
            "blosc_compress_ctx returned %d.", rc);
    }
    plhs[0] = bytesToMx(out, (size_t)rc);
    mxFree(out);
}

static void doDecodeChunk(int nrhs, const mxArray *prhs[],
                          int nlhs, mxArray *plhs[]) {
    /* decode_chunk(container, expectedShape, dtypeStr, axisOrder) */
    if (nrhs != 5) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArgs",
            "decode_chunk: expected (container, expectedShape, "
            "dtype, axisOrder).");
    }
    size_t nSrc;
    const uint8_t *src = readByteArg(prhs[1], &nSrc, "container");
    mwSize shape[32];
    int nd = readShapeArg(prhs[2], shape, 32, "expectedShape");
    const char *dtypeStr = readCharArg(prhs[3], "dtype");
    const char *axisStr  = readCharArg(prhs[4], "axisOrder");
    char axisOrder = (axisStr && (axisStr[0] == 'C' || axisStr[0] == 'c'))
        ? 'C' : 'F';

    /* Map dtype name to MATLAB class + typesize. */
    mxClassID mlCls;
    if      (!strcmp(dtypeStr, "uint8"))   mlCls = mxUINT8_CLASS;
    else if (!strcmp(dtypeStr, "int8"))    mlCls = mxINT8_CLASS;
    else if (!strcmp(dtypeStr, "uint16"))  mlCls = mxUINT16_CLASS;
    else if (!strcmp(dtypeStr, "int16"))   mlCls = mxINT16_CLASS;
    else if (!strcmp(dtypeStr, "uint32"))  mlCls = mxUINT32_CLASS;
    else if (!strcmp(dtypeStr, "int32"))   mlCls = mxINT32_CLASS;
    else if (!strcmp(dtypeStr, "single"))  mlCls = mxSINGLE_CLASS;
    else if (!strcmp(dtypeStr, "uint64"))  mlCls = mxUINT64_CLASS;
    else if (!strcmp(dtypeStr, "int64"))   mlCls = mxINT64_CLASS;
    else if (!strcmp(dtypeStr, "double"))  mlCls = mxDOUBLE_CLASS;
    else {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadArg",
            "dtype '%s' not supported.", dtypeStr);
        return;
    }
    size_t typesize = mlClassSize(mlCls);

    /* Consult the container header to verify size. */
    size_t nbytes = 0, cbytes = 0, blocksize = 0;
    blosc_cbuffer_sizes(src, &nbytes, &cbytes, &blocksize);
    if (cbytes == 0 || cbytes > nSrc) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadContainer",
            "Container header says cbytes=%zu, buffer has %zu bytes.",
            cbytes, nSrc);
    }
    size_t nElem = 1;
    for (int k = 0; k < nd; ++k) nElem *= (size_t)shape[k];
    if (nbytes != nElem * typesize) {
        mexErrMsgIdAndTxt("blosc_matlab:mex:BadContainer",
            "Container says nbytes=%zu, expected %zu for shape * typesize.",
            nbytes, nElem * typesize);
    }

    /* Decode into a temp buffer. */
    uint8_t *decoded = (uint8_t *)mxMalloc(nbytes > 0 ? nbytes : 1);
    int rc = blosc_decompress_ctx(src, decoded, nbytes, 1);
    if (rc < 0) {
        mxFree(decoded);
        mexErrMsgIdAndTxt("blosc_matlab:mex:DecompressFailed",
            "blosc_decompress_ctx returned %d.", rc);
    }

    /* Allocate output MATLAB array (Fortran order, given shape). */
    plhs[0] = mxCreateNumericArray(nd, shape, mlCls, mxREAL);
    reorderToFortran(decoded, (uint8_t *)mxGetData(plhs[0]),
                     shape, nd, typesize, axisOrder);
    mxFree(decoded);
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

    const char *cname = NULL;
    if (blosc_compcode_to_compname(complib, &cname) < 0 || cname == NULL) {
        cname = "unknown";
    }

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
    /* blosc_list_compressors returns a comma-separated char*. */
    const char *list = blosc_list_compressors();
    if (list) {
        strncpy(codecs, list, sizeof(codecs) - 1);
        codecs[sizeof(codecs) - 1] = '\0';
    }

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
    } else if (strcmp(verb, "encode_chunk") == 0) {
        doEncodeChunk(nrhs, prhs, nlhs, plhs);
    } else if (strcmp(verb, "decode_chunk") == 0) {
        doDecodeChunk(nrhs, prhs, nlhs, plhs);
    } else if (strcmp(verb, "header") == 0) {
        doHeader(nrhs, prhs, nlhs, plhs);
    } else if (strcmp(verb, "version") == 0) {
        doVersion(nrhs, prhs, nlhs, plhs);
    } else {
        mexErrMsgIdAndTxt("blosc_matlab:mex:UnknownVerb",
            "Unknown verb '%s'.", verb);
    }
}
