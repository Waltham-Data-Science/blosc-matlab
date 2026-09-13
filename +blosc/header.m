function h = header(container)
%BLOSC.HEADER Return the codec/typesize/size fields from a container.
%
%   H = BLOSC.HEADER(CONTAINER) returns a struct with fields:
%     cname     - char, the codec identity (e.g. 'zstd')
%     clevel    - integer 0..9, compression level
%     shuffle   - 0 (none), 1 (byte), 2 (bit)
%     typesize  - element size in bytes as recorded at encode time
%     nbytes    - uncompressed payload size in bytes
%     cbytes    - total container size in bytes (payload + header)
%     blocksize - internal block size the encoder chose
%
%   Header is read directly from CONTAINER bytes; no decompression
%   is performed. See BLOSC.DECODE to actually get the payload.

    if ~isa(container, 'uint8')
        container = typecast(container(:), 'uint8');
    end
    h = blosc_mex('header', container(:));
end
