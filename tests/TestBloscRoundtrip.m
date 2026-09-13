classdef TestBloscRoundtrip < matlab.unittest.TestCase
    % Round-trip tests for the MEX Blosc bindings.
    %
    % Relies on the build having produced a MEX file at
    % +blosc/private/blosc_mex.<mexext>. The build.m script does that;
    % the CI matrix invokes it before this test runs.

    methods (Test)

        function testRoundtripUint16(testCase)
            rng(1);
            data = uint16(randi([0 65535], 1, 4096));
            container = blosc.encode(data);
            testCase.verifyTrue(blosc.isBlosc(container));
            back = blosc.decode(container);
            recovered = typecast(back, 'uint16');
            testCase.verifyEqual(numel(recovered), numel(data));
            testCase.verifyEqual(recovered(:).', data(:).');
        end

        function testRoundtripSingle(testCase)
            data = single(reshape(1:1000, [10 10 10])) / 3.14;
            container = blosc.encode(data);
            back = blosc.decode(container);
            recovered = reshape(typecast(back, 'single'), size(data));
            testCase.verifyEqual(recovered, data);
        end

        function testHeaderReadsBack(testCase)
            data = uint16(zeros(1, 512));
            container = blosc.encode(data);
            h = blosc.header(container);
            testCase.verifyEqual(h.typesize, 2);
            testCase.verifyEqual(h.nbytes, 2 * 512);
            testCase.verifyEqual(h.cbytes, numel(container));
            testCase.verifyEqual(h.shuffle, 1);
        end

        function testEveryCodec(testCase)
            % Every codec the build reports must be usable.
            info = blosc.version();
            data = uint16(1:4096);
            for i = 1:numel(info.codecs)
                cname = info.codecs{i};
                container = blosc.encode(data, 'cname', cname);
                back = blosc.decode(container);
                recovered = typecast(back, 'uint16');
                testCase.verifyEqual(recovered(:).', data(:).', ...
                    sprintf('Round-trip failed for codec %s', cname));
            end
        end

        function testShuffleModes(testCase)
            data = uint16(1:2048);
            for shuf = [0 1 2]
                container = blosc.encode(data, 'shuffle', shuf);
                back = blosc.decode(container);
                recovered = typecast(back, 'uint16');
                testCase.verifyEqual(recovered(:).', data(:).', ...
                    sprintf('Round-trip failed for shuffle=%d', shuf));
            end
        end

        function testEncodeManyRoundtrips(testCase)
            rng(2);
            items = { ...
                uint16(randi([0 65535], 1, 512)), ...
                uint16(randi([0 65535], 1, 1024)), ...
                uint16(randi([0 65535], 1, 256))};
            containers = blosc.encodeMany(items);
            decoded = blosc.decodeMany(containers);
            for i = 1:numel(items)
                recovered = typecast(decoded{i}, 'uint16');
                testCase.verifyEqual(recovered(:).', items{i}(:).');
            end
        end

        function testIsBloscRejectsRandom(testCase)
            testCase.verifyFalse(blosc.isBlosc(uint8(zeros(1, 4))));
            testCase.verifyFalse(blosc.isBlosc(uint8(255 * ones(1, 32))));
        end

        function testLengthMismatchErrors(testCase)
            bytes = uint8(1:11);
            testCase.verifyError( ...
                @() blosc.encode(bytes, 'typesize', 2), ...
                'matlab_blosc:encode:LengthMismatch');
        end

        function testVersionReports(testCase)
            info = blosc.version();
            testCase.verifyClass(info, 'struct');
            testCase.verifyNotEmpty(info.blosc);
            testCase.verifyClass(info.codecs, 'cell');
            testCase.verifyGreaterThan(numel(info.codecs), 0);
        end

    end
end
