function tf = isBlosc(bytes)
%BLOSC.ISBLOSC Return true if BYTES looks like a Blosc v1 container.
%
%   TF = BLOSC.ISBLOSC(BYTES) inspects the first byte of BYTES (the
%   version byte) and returns TRUE when it names a Blosc v1 format
%   the library can decode. Cheap; touches only the first 16 bytes.
%
%   Useful as a guard before calling BLOSC.DECODE on data of unknown
%   provenance -- e.g. a chunk read from a Zarr store that could be
%   raw or Blosc-wrapped depending on the store's compressor
%   configuration.

    tf = false;
    if isempty(bytes), return; end
    if ~isa(bytes, 'uint8')
        try
            bytes = typecast(bytes(:), 'uint8');
        catch
            return;
        end
    end
    if numel(bytes) < 16, return; end
    % Byte 0: Blosc format version. 1 (BLOSC1) is what numcodecs and
    % Zarr write; 2 (BLOSC2) is not this library's job. Anything else
    % is not a Blosc container.
    tf = (bytes(1) == 1) || (bytes(1) == 2);
end
