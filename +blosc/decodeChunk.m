function tile = decodeChunk(container, expectedShape, dtype, options)
%BLOSC.DECODECHUNK Decode a Blosc container directly into a MATLAB array.
%
%   TILE = BLOSC.DECODECHUNK(CONTAINER, EXPECTEDSHAPE, DTYPE)
%
%   Decodes a Blosc v1 CONTAINER (uint8 vector) into a MATLAB ND-array
%   of shape EXPECTEDSHAPE and class DTYPE. The bytes in CONTAINER are
%   assumed to be in C-order (Zarr / NumPy on-disk convention); the
%   returned MATLAB array is Fortran-order so that TILE(i,j,k,...) is
%   accessed in MATLAB's native indexing. The axis-order transpose is
%   done inside the MEX with no intermediate MATLAB allocations, which
%   avoids a full memcpy per chunk on every read.
%
%   TILE = BLOSC.DECODECHUNK(..., 'axisOrder', 'F') skips the transpose,
%   treating the container bytes as Fortran-order (mostly useful for
%   round-trip tests against BLOSC.ENCODECHUNK).
%
%   DTYPE is one of {'uint8','int8','uint16','int16','uint32','int32',
%   'single','uint64','int64','double'}.
%
%   See also BLOSC.ENCODECHUNK, BLOSC.DECODE, BLOSC.HEADER.

    arguments
        container
        expectedShape (1,:) double {mustBeInteger, mustBePositive}
        dtype (1,:) char {mustBeMember(dtype, ...
            {'uint8','int8','uint16','int16','uint32','int32', ...
             'single','uint64','int64','double'})}
        options.axisOrder (1,:) char {mustBeMember(options.axisOrder, ...
            {'C', 'F'})} = 'C'
    end

    if ~isa(container, 'uint8')
        container = typecast(container(:), 'uint8');
    end
    container = container(:);

    tile = blosc_mex('decode_chunk', container, double(expectedShape), ...
        dtype, options.axisOrder);
end
