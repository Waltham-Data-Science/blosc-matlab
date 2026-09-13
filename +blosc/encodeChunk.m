function container = encodeChunk(tile, targetShape, options)
%BLOSC.ENCODECHUNK Pad, reorder, and encode a MATLAB array into a Blosc container.
%
%   CONTAINER = BLOSC.ENCODECHUNK(TILE, TARGETSHAPE) returns a Blosc v1
%   container whose bytes match what Zarr / numcodecs would produce for
%   an array of shape TARGETSHAPE containing TILE at its origin. TILE
%   may be smaller than TARGETSHAPE along any axis; missing positions
%   are padded with zeros (see 'padValue' below).
%
%   CONTAINER = BLOSC.ENCODECHUNK(TILE, TARGETSHAPE, 'Name', Value, ...)
%   sets:
%     'cname'      char, one of {'blosclz','lz4','lz4hc','zlib','zstd'};
%                  default 'zstd'.
%     'clevel'     integer in [0..9]; default 5.
%     'shuffle'    0 (none), 1 (byte), 2 (bit); default 1.
%     'blocksize'  integer >= 0; default 0 (auto).
%     'padValue'   scalar of the same class as TILE used to fill padded
%                  positions; default 0 cast to that class.
%     'axisOrder'  'C' (default; matches Zarr / NumPy on-disk byte order)
%                  or 'F' (MATLAB-native, mostly useful for round-trip
%                  tests).
%
%   Why this exists: naive MATLAB code writing a Zarr chunk from a
%   TILE goes tile -> padarray -> permute -> typecast -> blosc.encode,
%   with a full memcpy at each step. On a lightsheet ingest that adds
%   up to hundreds of gigabytes of gratuitous MATLAB memory traffic.
%   BLOSC.ENCODECHUNK does the pad, the axis-order transpose, the
%   typecast and the Blosc compress in one MEX call with no
%   intermediate MATLAB allocations.
%
%   The returned CONTAINER is byte-for-byte identical to what a
%   numpy.transpose(tile).tobytes() + numcodecs.Blosc.encode chain
%   writes with the same options.
%
%   See also BLOSC.DECODECHUNK, BLOSC.ENCODE, BLOSC.DECODE.

    arguments
        tile
        targetShape (1,:) double {mustBeInteger, mustBePositive}
        options.cname (1,:) char {mustBeMember(options.cname, ...
            {'blosclz','lz4','lz4hc','zlib','zstd'})} = 'zstd'
        options.clevel (1,1) double {mustBeInteger, ...
            mustBeGreaterThanOrEqual(options.clevel, 0), ...
            mustBeLessThanOrEqual(options.clevel, 9)} = 5
        options.shuffle (1,1) double {mustBeMember(options.shuffle, ...
            [0 1 2])} = 1
        options.blocksize (1,1) double {mustBeInteger, ...
            mustBeGreaterThanOrEqual(options.blocksize, 0)} = 0
        options.padValue = []
        options.axisOrder (1,:) char {mustBeMember(options.axisOrder, ...
            {'C', 'F'})} = 'C'
    end

    if ~(isnumeric(tile) || islogical(tile))
        error('blosc_matlab:encodeChunk:BadInput', ...
            'TILE must be a numeric or logical array.');
    end

    if isempty(options.padValue)
        options.padValue = cast(0, class(tile));
    else
        options.padValue = cast(options.padValue, class(tile));
    end
    padBytes = typecast(options.padValue, 'uint8');
    padBytes = padBytes(:);

    container = blosc_mex('encode_chunk', tile, double(targetShape), ...
        options.cname, ...
        int32(options.clevel), int32(options.shuffle), ...
        int32(options.blocksize), ...
        options.axisOrder, ...
        padBytes);
end
