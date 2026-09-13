function encoded = encodeMany(items, options)
%BLOSC.ENCODEMANY Encode a cell array of items with one set of options.
%
%   ENCODED = BLOSC.ENCODEMANY(ITEMS, ...) applies the same codec
%   options to every item in the ITEMS cell array. Returns a cell
%   array of the same size where ENCODED{i} is BLOSC.ENCODE(ITEMS{i}).
%
%   Same Name-Value options as BLOSC.ENCODE. Batching in the MEX
%   world is a MATLAB loop over the MEX call: each call is a direct
%   C function invocation, so the loop is inexpensive compared to
%   spawning or piping to an external process. This function exists
%   for API symmetry with libraries that had to batch, and for the
%   convenience of an obvious idiomatic call.

    arguments
        items (1,:) cell
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

    encoded = cell(size(items));
    for i = 1:numel(items)
        encoded{i} = blosc.encode(items{i}, ...
            'cname', options.cname, 'clevel', options.clevel, ...
            'shuffle', options.shuffle, 'typesize', options.typesize, ...
            'blocksize', options.blocksize);
    end
end
