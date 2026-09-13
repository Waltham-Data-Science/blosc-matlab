classdef TestBloscMemStable < matlab.unittest.TestCase
    % Steady-state memory stability tests for the MEX bindings.
    %
    % Hammers each MEX verb in a tight loop and checks that MATLAB's
    % process RSS does not grow beyond a fixed threshold across the run.
    % A real leak (say 1 KB per call) would blow past the threshold long
    % before the loop finishes; MATLAB's own memory manager can
    % legitimately grow RSS a bit during warmup as caches populate, so
    % the threshold is generous (100 MB steady-state growth over ~100k
    % iterations = about 1 KB per iteration).
    %
    % Linux and macOS only: the RSS sampler shells out to
    % `ps -o rss= -p <pid>`. On Windows the tests skip cleanly.

    properties (Constant)
        WARMUP_ITERS   = 5000    % populate JIT + memory manager caches
        MEASURED_ITERS = 100000  % steady-state region
        MAX_GROWTH_MB  = 100     % post-warmup ceiling; > this = a leak
    end

    methods (Test)

        function testEncodeSteadyState(testCase)
            testCase.assumeTrue(isunix(), ...
                'RSS sampler is Linux/macOS only.');
            data = uint16(1:4096).';

            % Warmup.
            for i = 1:testCase.WARMUP_ITERS
                blosc.encode(data);
            end
            baseline = matlabRSSMB();

            % Steady state.
            for i = 1:testCase.MEASURED_ITERS
                blosc.encode(data); %#ok<*NASGU>
            end
            final = matlabRSSMB();

            growth = final - baseline;
            testCase.verifyLessThan(growth, testCase.MAX_GROWTH_MB, ...
                sprintf(['blosc.encode leaked ~%.0f MB over %d ' ...
                    'iterations (baseline %.0f -> final %.0f MB, ' ...
                    'threshold %d MB).'], growth, ...
                    testCase.MEASURED_ITERS, baseline, final, ...
                    testCase.MAX_GROWTH_MB));
        end

        function testDecodeSteadyState(testCase)
            testCase.assumeTrue(isunix(), ...
                'RSS sampler is Linux/macOS only.');
            container = blosc.encode(uint16(1:4096).');

            for i = 1:testCase.WARMUP_ITERS
                blosc.decode(container);
            end
            baseline = matlabRSSMB();

            for i = 1:testCase.MEASURED_ITERS
                blosc.decode(container); %#ok<*NASGU>
            end
            final = matlabRSSMB();

            growth = final - baseline;
            testCase.verifyLessThan(growth, testCase.MAX_GROWTH_MB, ...
                sprintf(['blosc.decode leaked ~%.0f MB over %d ' ...
                    'iterations (baseline %.0f -> final %.0f MB, ' ...
                    'threshold %d MB).'], growth, ...
                    testCase.MEASURED_ITERS, baseline, final, ...
                    testCase.MAX_GROWTH_MB));
        end

        function testEncodeChunkSteadyState(testCase)
            testCase.assumeTrue(isunix(), ...
                'RSS sampler is Linux/macOS only.');
            % 32^3 uint16 = 64 KB per chunk. Small enough that
            % 100k iters run in reasonable CI time; large enough that a
            % byte-per-iteration leak accumulates measurably.
            tile = uint16(reshape(1:(32^3), [32 32 32]));

            for i = 1:testCase.WARMUP_ITERS
                blosc.encodeChunk(tile, size(tile));
            end
            baseline = matlabRSSMB();

            for i = 1:testCase.MEASURED_ITERS
                blosc.encodeChunk(tile, size(tile)); %#ok<*NASGU>
            end
            final = matlabRSSMB();

            growth = final - baseline;
            testCase.verifyLessThan(growth, testCase.MAX_GROWTH_MB, ...
                sprintf(['blosc.encodeChunk leaked ~%.0f MB over %d ' ...
                    'iterations (baseline %.0f -> final %.0f MB, ' ...
                    'threshold %d MB).'], growth, ...
                    testCase.MEASURED_ITERS, baseline, final, ...
                    testCase.MAX_GROWTH_MB));
        end

        function testDecodeChunkSteadyState(testCase)
            testCase.assumeTrue(isunix(), ...
                'RSS sampler is Linux/macOS only.');
            tile = uint16(reshape(1:(32^3), [32 32 32]));
            container = blosc.encodeChunk(tile, size(tile));

            for i = 1:testCase.WARMUP_ITERS
                blosc.decodeChunk(container, size(tile), 'uint16');
            end
            baseline = matlabRSSMB();

            for i = 1:testCase.MEASURED_ITERS
                blosc.decodeChunk(container, size(tile), 'uint16'); %#ok<*NASGU>
            end
            final = matlabRSSMB();

            growth = final - baseline;
            testCase.verifyLessThan(growth, testCase.MAX_GROWTH_MB, ...
                sprintf(['blosc.decodeChunk leaked ~%.0f MB over %d ' ...
                    'iterations (baseline %.0f -> final %.0f MB, ' ...
                    'threshold %d MB).'], growth, ...
                    testCase.MEASURED_ITERS, baseline, final, ...
                    testCase.MAX_GROWTH_MB));
        end
    end
end

function mb = matlabRSSMB()
% Resident set size of the current MATLAB process, in MB.
%
%   Uses `ps -o rss= -p <pid>` which prints kilobytes on both Linux
%   and macOS. Callers must skip the test on Windows (see the
%   assumeTrue guards); the function itself returns NaN there.
    mb = NaN;
    if ~isunix()
        return;
    end
    pid = feature('getpid');
    [rc, out] = system(sprintf('ps -o rss= -p %d', pid));
    if rc == 0
        v = sscanf(strtrim(out), '%f');
        if ~isempty(v)
            mb = v / 1024;
        end
    end
end
