function bytesOut = decode(container)
%BLOSC.DECODE Decompress a Blosc v1 container to raw bytes.
%
%   BYTESOUT = BLOSC.DECODE(CONTAINER) decompresses one Blosc v1
%   container CONTAINER into a uint8 column vector.
%
%   CONTAINER can be a uint8 vector or something typecast-able to
%   uint8. The typesize used at encode time is recorded in the
%   container header and is applied automatically; callers do not
%   have to supply it. To interpret the bytes as a typed array,
%   TYPECAST them and RESHAPE to the chunk shape.
%
%   See also BLOSC.ENCODE, BLOSC.HEADER.

    if ~isa(container, 'uint8')
        try
            container = typecast(container(:), 'uint8');
        catch ME
            error('matlab_blosc:decode:BadInput', ...
                'CONTAINER must be a uint8 vector (or typecast-able). typecast said: %s', ...
                ME.message);
        end
    end
    bytesOut = blosc_mex('decode', container(:));
end
