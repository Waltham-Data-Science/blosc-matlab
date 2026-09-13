classdef TestBloscChunk < matlab.unittest.TestCase
    % Round-trip tests for the fat encodeChunk / decodeChunk MEX API.
    %
    % These do the pad + axis-order transpose + typecast + Blosc encode
    % in a single MEX call, so the assertions here cover geometry
    % (matches numpy.transpose+tobytes semantics) as well as the codec.

    methods (Test)

        function testRoundtripNoPad3DUint16(testCase)
            rng(3);
            tile = uint16(randi([0 65535], [16 24 8]));
            container = blosc.encodeChunk(tile, size(tile));
            back = blosc.decodeChunk(container, size(tile), 'uint16');
            testCase.verifyEqual(back, tile);
        end

        function testRoundtripWithPadUint16(testCase)
            % Edge chunk: tile smaller than target on every axis.
            tile = uint16(reshape(1:120, [4 5 6]));
            targetShape = [8 8 8];
            container = blosc.encodeChunk(tile, targetShape, ...
                'padValue', uint16(9999));
            back = blosc.decodeChunk(container, targetShape, 'uint16');
            % Inside the tile extent, values match tile.
            testCase.verifyEqual(back(1:4, 1:5, 1:6), tile);
            % Outside, everything is the pad value.
            padded = back;
            padded(1:4, 1:5, 1:6) = 9999;
            testCase.verifyTrue(all(padded(:) == 9999));
        end

        function testRoundtripSingle4D(testCase)
            data = single(rand([3 4 5 2]));
            container = blosc.encodeChunk(data, size(data));
            back = blosc.decodeChunk(container, size(data), 'single');
            testCase.verifyEqual(back, data);
        end

        function testAxisOrderFRoundtrip(testCase)
            % axisOrder = 'F' skips the C<->Fortran transpose, so encode
            % + decode with axisOrder='F' is a pure Blosc round-trip on
            % the raw byte layout.
            tile = uint32(reshape(1:1000, [10 10 10]));
            container = blosc.encodeChunk(tile, size(tile), 'axisOrder', 'F');
            back = blosc.decodeChunk(container, size(tile), 'uint32', ...
                'axisOrder', 'F');
            testCase.verifyEqual(back, tile);
        end

        function testCOrderMatchesTransposePlusEncode(testCase)
            % blosc.encodeChunk('axisOrder', 'C') must produce byte-for-
            % byte the same container as manually permute'ing the tile
            % into C-order-friendly axes, typecast'ing to bytes, and
            % calling blosc.encode with the same options.
            rng(7);
            tile = uint16(randi([0 65535], [16 8 4]));
            nd = ndims(tile);
            permuted = permute(tile, nd:-1:1);
            rawBytes = typecast(permuted(:), 'uint8');
            slow = blosc.encode(rawBytes, ...
                'cname', 'zstd', 'clevel', 5, 'shuffle', 1, ...
                'typesize', 2);
            fast = blosc.encodeChunk(tile, size(tile), ...
                'cname', 'zstd', 'clevel', 5, 'shuffle', 1);
            testCase.verifyEqual(fast, slow);
        end

        function testEncodeChunkClevel9(testCase)
            tile = uint16(zeros([32 32 32]));
            tile(:) = uint16(mod(0:numel(tile)-1, 65536));
            container = blosc.encodeChunk(tile, size(tile), ...
                'clevel', 9, 'cname', 'zstd');
            testCase.verifyTrue(blosc.isBlosc(container));
            back = blosc.decodeChunk(container, size(tile), 'uint16');
            testCase.verifyEqual(back, tile);
        end

        function testHeaderReflectsChunkTypesize(testCase)
            tile = uint16(zeros([8 8 8]));
            container = blosc.encodeChunk(tile, size(tile));
            h = blosc.header(container);
            testCase.verifyEqual(h.typesize, 2);
            testCase.verifyEqual(h.nbytes, numel(tile) * 2);
        end

        function testRejectsOversizedTile(testCase)
            tile = uint16(zeros([9 4]));
            targetShape = [8 8];
            testCase.verifyError( ...
                @() blosc.encodeChunk(tile, targetShape), ...
                'blosc_matlab:mex:LengthMismatch');
        end
    end
end
