function decoded = decodeMany(containers)
%BLOSC.DECODEMANY Decode a cell array of Blosc containers.
%
%   DECODED = BLOSC.DECODEMANY(CONTAINERS) applies BLOSC.DECODE to
%   every element of the CONTAINERS cell array and returns the
%   results in a cell array of the same size.
%
%   In the MEX world each decode is a direct C call, so this is
%   simply a MATLAB loop -- provided as an ergonomic wrapper.

    arguments
        containers (1,:) cell
    end

    decoded = cell(size(containers));
    for i = 1:numel(containers)
        decoded{i} = blosc.decode(containers{i});
    end
end
