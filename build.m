function build(options)
%BUILD Compile the Blosc MEX from source.
%
%   BUILD() compiles src/blosc_mex.c against the vendored C-Blosc at
%   src/c-blosc and installs the resulting MEX file into
%   +blosc/private/. Requires a C compiler MATLAB is configured to
%   use (mex -setup c).
%
%   BUILD('Verbose', true) forwards -v to mex for full compiler
%   output when diagnosing a build.

    arguments
        options.Verbose (1,1) logical = false
    end

    here = fileparts(mfilename('fullpath'));
    cbloscRoot = fullfile(here, 'src', 'c-blosc');
    if ~isfile(fullfile(cbloscRoot, 'blosc', 'blosc.h'))
        error('blosc_matlab:build:MissingSubmodule', ...
            ['The c-blosc submodule at %s is empty. Run\n' ...
             '  git submodule update --init --recursive\n' ...
             'in the repo root and try again.'], cbloscRoot);
    end

    buildDir = fullfile(here, 'build_c_blosc');
    if ~isfolder(buildDir), mkdir(buildDir); end

    % Configure and build c-blosc as a static library. Snappy is
    % deliberately disabled -- see README ("Codecs").
    %
    % CMAKE_POLICY_VERSION_MINIMUM=3.5 is set because c-blosc's own
    % top-level cmake_minimum_required() is below CMake 4.0's floor
    % (< 3.5). CMake 4+ removed that compatibility path outright, so
    % without the override the very first `cmake -S` errors out with
    % "Compatibility with CMake < 3.5 has been removed". Setting the
    % override tells CMake to behave as if the caller had asked for
    % policy defaults from 3.5, which is what c-blosc's build
    % actually needs.
    cmakeCmd = sprintf(['cmake -S %s -B %s ' ...
        '-DBUILD_STATIC=ON -DBUILD_SHARED=OFF -DBUILD_TESTS=OFF ' ...
        '-DBUILD_BENCHMARKS=OFF -DBUILD_FUZZERS=OFF ' ...
        '-DDEACTIVATE_SNAPPY=ON ' ...
        '-DCMAKE_POSITION_INDEPENDENT_CODE=ON ' ...
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5 ' ...
        '-DCMAKE_BUILD_TYPE=Release'], ...
        shellQuote(cbloscRoot), shellQuote(buildDir));
    runShell(cmakeCmd);

    buildCmd = sprintf('cmake --build %s --config Release --parallel', ...
        shellQuote(buildDir));
    runShell(buildCmd);

    % Find the static library. Location and file name vary by
    % generator: unix drops libblosc.a next to the source, MSVC's
    % multi-config generator drops libblosc.lib into a Release/ or
    % Debug/ subdir, and older single-config Windows generators drop
    % blosc.lib (no lib prefix) directly. Cover all of them.
    libSearchDirs = { ...
        fullfile(buildDir, 'blosc'), ...
        fullfile(buildDir, 'blosc', 'Release'), ...
        fullfile(buildDir, 'blosc', 'Debug') ...
    };
    libSearchNames = {'libblosc.a', 'libblosc.lib', 'blosc.lib'};
    libPath = '';
    tried = {};
    for i = 1:numel(libSearchDirs)
        for j = 1:numel(libSearchNames)
            candidate = fullfile(libSearchDirs{i}, libSearchNames{j});
            tried{end+1} = candidate; %#ok<AGROW>
            if isfile(candidate)
                libPath = candidate;
                break;
            end
        end
        if ~isempty(libPath), break; end
    end
    if isempty(libPath)
        error('blosc_matlab:build:LibMissing', ...
            'Could not find libblosc after building. Looked in:\n%s', ...
            strjoin(tried, '\n'));
    end

    % Include dirs: the public blosc/ header plus the sub-headers c-blosc
    % pulls at build time (lz4, zstd, ...) live under c-blosc/internal-
    % complibs, but the MEX only needs blosc/blosc.h.
    outDir = fullfile(here, '+blosc', 'private');
    if ~isfolder(outDir), mkdir(outDir); end

    mexArgs = { ...
        '-outdir', outDir, ...
        ['-I' fullfile(cbloscRoot, 'blosc')], ...
        fullfile(here, 'src', 'blosc_mex.c'), ...
        libPath};
    if options.Verbose
        mexArgs = ['-v', mexArgs];
    end
    % Windows needs pthread and MSVC's zdll linkage bundled by
    % c-blosc's own build; the static lib carries them, so nothing
    % extra to pass here. Linux gets away without -lpthread since
    % blosc_compress_ctx uses only nthreads=1.
    mex(mexArgs{:});
    fprintf('Built %s/blosc_mex.%s\n', outDir, mexext);
end

function runShell(cmd)
    fprintf('%s\n', cmd);
    [rc, out] = system(cmd);
    if rc ~= 0
        error('blosc_matlab:build:ShellFailed', ...
            'Command failed (exit %d):\n%s\n\n%s', rc, cmd, out);
    end
    disp(out);
end

function s = shellQuote(p)
    if ispc
        s = ['"' p '"'];
    else
        s = ['''' strrep(p, '''', '''\''''') ''''];
    end
end
