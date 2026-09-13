function install(options)
%INSTALL Download the platform-appropriate MEX from GitHub Releases.
%
%   INSTALL() figures out which platform MATLAB is running on, picks
%   the matching prebuilt asset from the latest matlab-blosc release,
%   downloads it, and drops the MEX file into +blosc/private/.
%
%   Options:
%     'Version' - char, the release tag to install (e.g. 'v0.2.0');
%                 default 'latest'.
%     'Force'   - logical, if true reinstall even when a MEX file is
%                 already present; default false.
%     'Repo'    - char, override the source repo. Default
%                 'Waltham-Data-Science/matlab-blosc'.
%
%   Examples:
%       install                           % latest, skip if present
%       install('Version', 'v0.3.0')      % pin a version
%       install('Force', true)            % reinstall
%
%   On success prints where the MEX landed and adds it to the path.
%   Only the MATLAB code + one MEX file is touched -- no compilers,
%   no system state.
%
%   If your platform is missing from the release assets, either run
%   BUILD locally (needs a C compiler and CMake) or open an issue at
%   https://github.com/Waltham-Data-Science/matlab-blosc/issues .

    arguments
        options.Version (1,:) char = 'latest'
        options.Force (1,1) logical = false
        options.Repo (1,:) char = 'Waltham-Data-Science/matlab-blosc'
    end

    here = fileparts(mfilename('fullpath'));
    outDir = fullfile(here, '+blosc', 'private');
    if ~isfolder(outDir), mkdir(outDir); end
    mexPath = fullfile(outDir, ['blosc_mex.' mexext]);

    if ~options.Force && isfile(mexPath)
        fprintf('MEX already installed at %s\n', mexPath);
        addpath(here);
        return;
    end

    assetName = pickAssetName();

    if strcmpi(options.Version, 'latest')
        url = sprintf('https://github.com/%s/releases/latest/download/%s', ...
            options.Repo, assetName);
    else
        url = sprintf('https://github.com/%s/releases/download/%s/%s', ...
            options.Repo, options.Version, assetName);
    end

    tmpDir = fullfile(tempdir, ['matlab-blosc-install-' char(matlab.lang.internal.uuid())]);
    mkdir(tmpDir);
    cleaner = onCleanup(@() safeRmdir(tmpDir));

    localTar = fullfile(tmpDir, assetName);
    fprintf('Downloading %s\n  -> %s\n', url, localTar);
    try
        websave(localTar, url);
    catch ME
        error('matlab_blosc:install:DownloadFailed', ...
            ['Could not fetch %s\n  %s\n\nThe most common cause is ' ...
             'that no release with that tag/asset exists yet. See ' ...
             'https://github.com/%s/releases .'], ...
            url, ME.message, options.Repo);
    end

    fprintf('Extracting...\n');
    extractDir = fullfile(tmpDir, 'x');
    mkdir(extractDir);
    untar(localTar, extractDir);

    % The tarball layout is release/matlab-blosc/+blosc/private/blosc_mex.<ext>
    hits = dir(fullfile(extractDir, '**', ['blosc_mex.' mexext]));
    if isempty(hits)
        error('matlab_blosc:install:AssetMissing', ...
            'Downloaded %s but it does not contain blosc_mex.%s .', ...
            assetName, mexext);
    end
    copyfile(fullfile(hits(1).folder, hits(1).name), mexPath);

    fprintf('Installed %s\n', mexPath);
    addpath(here);
    fprintf('\nQuick smoke test:\n');
    try
        info = blosc.version();
        fprintf('  blosc %s, codecs: %s\n', info.blosc, ...
            strjoin(info.codecs, ', '));
    catch ME
        warning('matlab_blosc:install:SmokeFailed', ...
            'MEX installed but blosc.version() failed: %s', ME.message);
    end
end

function name = pickAssetName()
%PICKASSETNAME - match this MATLAB's platform to a release asset
    mex = mexext;
    switch mex
        case 'mexmaca64'
            name = 'matlab-blosc-macos-arm64.tar.gz';
        case 'mexmaci64'
            name = 'matlab-blosc-macos-x64.tar.gz';
        case 'mexa64'
            % Linux; distinguish x64 vs arm64 by MATLAB's own probe.
            arch = computer('arch');
            if contains(lower(arch), 'aarch64') || ...
               contains(lower(arch), 'arm')
                name = 'matlab-blosc-linux-arm64.tar.gz';
            else
                name = 'matlab-blosc-linux-x64.tar.gz';
            end
        case 'mexw64'
            name = 'matlab-blosc-windows-x64.tar.gz';
        otherwise
            error('matlab_blosc:install:UnknownPlatform', ...
                ['This MATLAB reports mexext=%s, which matlab-blosc ' ...
                 'does not ship a prebuilt for. Options: run BUILD ' ...
                 'from source, or open an issue.'], mex);
    end
end

function safeRmdir(d)
    try %#ok<TRYNC>
        rmdir(d, 's');
    end
end
