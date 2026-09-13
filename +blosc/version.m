function v = version()
%BLOSC.VERSION Return the C-Blosc version and the codecs it was built with.
%
%   V = BLOSC.VERSION() returns a struct:
%     blosc  - char, the C-Blosc version string (e.g. '1.21.6')
%     codecs - cellstr of codec names the build supports (e.g.
%              {'blosclz','lz4','lz4hc','zlib','zstd'}).

    v = blosc_mex('version');
end
