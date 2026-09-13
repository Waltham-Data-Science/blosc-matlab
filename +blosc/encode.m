function container = encode(bytesIn, options)
%BLOSC.ENCODE Compress bytes into a Blosc v1 container.
%
%   CONTAINER = BLOSC.ENCODE(BYTESIN) compresses BYTESIN with the
%   library's default codec (Zstd, clevel 5, byte shuffle). BYTESIN is
%   either a uint8 vector or a numeric array; a typed array is
%   converted to its bytes via TYPECAST.
%
%   CONTAINER = BLOSC.ENCODE(BYTESIN, 'Name', Value, ...) sets codec
%   parameters:
%     'cname'     - one of {'blosclz','lz4','lz4hc','zlib','zstd'};
%                   default 'zstd'.
%     'clevel'    - integer in [0..9]; default 5.
%     'shuffle'   - 0 (none), 1 (byte), 2 (bit); default 1.
%     'typesize'  - element size in bytes; default is inferred from
%                   the numeric class of BYTESIN, else 1 for uint8.
%     'blocksize' - internal block size in bytes; default 0 (auto).
%
%   The returned CONTAINER is a uint8 column vector. Its bytes are
%   byte-for-byte identical to what numcodecs.Blosc (Python) writes
%   for the same input and options.
%
%   See also BLOSC.DECODE, BLOSC.HEADER, BLOSC.VERSION.

    arguments
        bytesIn
        options.cname (1,:) char {mustBeMember(options.cname, ...
            {'blosclz','lz4','lz4hc','zlib','zstd'})} = 'zstd'
        options.clevel (1,1) double {mustBeInteger, ...
            mustBeGreaterThanOrEqual(options.clevel, 0), ...
            mustBeLessThanOrEqual(options.clevel, 9)} = 5
        options.shuffle (1,1) double {mustBeMember(options.shuffle, ...
            [0 1 2])} = 1
        options.typesize (1,1) double {mustBeInteger, ...
            mustBeGreaterThanOrEqual(options.typesize, 0)} = 0
        options.blocksize (1,1) double {mustBeInteger, ...
            mustBeGreaterThanOrEqual(options.blocksize, 0)} = 0
    end

    [raw, typesize] = coerceBytes(bytesIn, options.typesize);

    container = blosc_mex('encode', raw, ...
        options.cname, ...
        int32(options.clevel), ...
        int32(options.shuffle), ...
        int32(typesize), ...
        int32(options.blocksize));
end
