function B = loadBModeExperiment(prebfFile, configFile)
% loadBModeExperiment
% Carga un experimento B-mode desde uno o dos archivos:
%   1) prebfFile  -> .mat con rf_prebf [Nt x nElements x nLines]
%   2) configFile -> opcional .mat con configuration y/o pipelineParameters
%
% La RF se mantiene como matfile para no cargar todo el cubo en RAM.
%
% USO:
%   B = loadBModeExperiment(prebfFile);
%   B = loadBModeExperiment(prebfFile, configFile);
%   rfRaw = B.rfMat.rf_prebf(:,:,1);
%
% CAMPOS PRINCIPALES:
%   B.rfMat, B.Nt, B.nElements, B.nLines
%   B.fs, B.c0, B.rho0
%   B.element_pitch, B.element_width
%   B.source_focus, B.source_f0, B.source_cycles
%   B.source_amp, B.source_t0, B.time_delays
%   B.yCords
%   B.configuration, B.pipelineParameters

    prebfFile = char(string(prebfFile));
    if nargin < 2 || isempty(configFile)
        configFile = prebfFile;
    else
        configFile = char(string(configFile));
    end

    if ~isfile(prebfFile)
        error('No existe el archivo PRE-BF: %s', prebfFile);
    end
    if ~isfile(configFile)
        error('No existe el archivo de configuración: %s', configFile);
    end

    %% 1) RF: verificar y mantener como matfile
    rfInfo = whos('-file', prebfFile);
    rfNames = {rfInfo.name};

    if ~ismember('rf_prebf', rfNames)
        error('El archivo PRE-BF no contiene una variable top-level llamada "rf_prebf".');
    end

    B.rfMat = matfile(prebfFile);
    B.prebfFile = prebfFile;
    B.configFile = configFile;

    rfSize = size(B.rfMat, 'rf_prebf');
    if numel(rfSize) < 3
        rfSize(3) = 1;
    end

    B.Nt        = rfSize(1);
    B.nElements = rfSize(2);
    B.nLines    = rfSize(3);

    %% 2) Cargar SOLO metadata del archivo RF (no rf_prebf)
    allowedMetadata = {'x','z','fs','c0','rho0','source_f0','source_amp', ...
        'source_cycles','source_focus','element_pitch','element_width', ...
        'time_delays','nLines','depth','grid_size_x','grid_size_y', ...
        'hom_alpha','focal_number_Tx','focal_number_Rx','active_tx_elements','simuName', ...
        'refSeed','iRef'};
    metadataNames = intersect(rfNames, allowedMetadata, 'stable');

    if isempty(metadataNames)
        R = struct();
    else
        R = load(prebfFile, metadataNames{:});
    end

    %% 3) Cargar configuración/pipeline sin recargar rf_prebf
    if strcmp(prebfFile, configFile)
        C = R;
    else
        C = load(configFile);
    end

    if isfield(C, 'configuration')
        B.configuration = C.configuration;
    else
        B.configuration = struct();
    end

    if isfield(C, 'pipelineParameters')
        B.pipelineParameters = C.pipelineParameters;
    else
        B.pipelineParameters = struct();
    end

    %% 4) Parámetros: primero metadata RF, luego pipelineParameters,
    %     luego configuration y finalmente todo configFile
    sources = {R, B.pipelineParameters, B.configuration, C};

    B.fs = pick(sources, ...
        {'fs','sampling_frequency','samplingFrequency','sample_rate','sampleRate'}, false);

    B.dt = pick(sources, ...
        {'dt','time_step','timeStep'}, false);

    if isempty(B.fs)
        if ~isempty(B.dt) && isnumeric(B.dt) && isscalar(B.dt) && B.dt > 0
            B.fs = 1/B.dt;
        else
            error('No se encontró fs ni dt. Se necesita la frecuencia de muestreo.');
        end
    end

    B.c0 = pick(sources, ...
        {'c0','sound_speed_ref','soundSpeedRef','sound_speed','soundSpeed'}, true);

    B.rho0 = pick(sources, ...
        {'rho0','density_ref','densityRef','density','rho'}, false);

    B.element_pitch = pick(sources, ...
        {'element_pitch','elementPitch','pitch'}, true);

    B.element_width = pick(sources, ...
        {'element_width','elementWidth'}, false);

    B.source_focus = pick(sources, ...
        {'source_focus','sourceFocus','focus_depth','focusDepth'}, true);

    B.source_f0 = pick(sources, ...
        {'source_f0','sourceF0','f0','center_frequency','centerFrequency'}, true);

    B.source_cycles = pick(sources, ...
        {'source_cycles','sourceCycles','cycles','nCycles'}, true);

    B.source_amp = pick(sources, ...
        {'source_amp','sourceAmp','source_amplitude','sourceAmplitude'}, false);

    B.source_t0 = pick(sources, ...
        {'source_t0','sourceT0','t0'}, false);

    B.time_delays = pick(sources, ...
        {'time_delays','timeDelays','tx_delays','txDelays'}, false);

    B.focal_number_Tx = pick(sources, ...
        {'focal_number_Tx','focalNumberTx','f_number_tx'}, false);

    B.active_tx_elements = pick(sources, ...
        {'active_tx_elements','activeTxElements'}, false);

    B.yCords = pick(sources, ...
        {'yCords','yCoords','y_coords','scan_positions','scanPositions', ...
         'line_positions','linePositions','x'}, false);

    B.z = pick(sources, ...
        {'z','axial_positions','axialPositions','depth_axis','depthAxis'}, false);

    B.grid_size_x = pick(sources, ...
        {'grid_size_x','gridSizeX'}, false);

    B.grid_size_y = pick(sources, ...
        {'grid_size_y','gridSizeY'}, false);

    B.depth = pick(sources, ...
        {'depth','imaging_depth','imagingDepth'}, false);

    B.hom_alpha = pick(sources, ...
        {'hom_alpha','homAlpha'}, false);

    %% 5) Comprobaciones
    nLinesCfg = pick(sources, ...
        {'nLines','n_lines','num_lines','numLines'}, false);

    if ~isempty(nLinesCfg) && double(nLinesCfg) ~= B.nLines
        warning(['nLines de configuración (%g) no coincide con size(rf_prebf,3) (%d). ' ...
                 'Se usará la dimensión real de rf_prebf.'], ...
                 double(nLinesCfg), B.nLines);
    end

    %% 6) Resumen
    fprintf('\n================ EXPERIMENTO CARGADO ================\n');
    fprintf('PRE-BF       : %s\n', prebfFile);
    fprintf('Configuración: %s\n', configFile);
    fprintf('rf_prebf     : %d x %d x %d\n', B.Nt, B.nElements, B.nLines);
    fprintf('fs           : %.3f MHz\n', B.fs/1e6);
    fprintf('c0           : %.2f m/s\n', B.c0);
    fprintf('f0           : %.3f MHz\n', B.source_f0/1e6);
    fprintf('pitch        : %.3f mm\n', B.element_pitch*1e3);
    fprintf('focus TX     : %.2f mm\n', B.source_focus*1e3);
    fprintf('======================================================\n\n');

    if isempty(B.yCords)
        fprintf(['Nota: no se encontró yCords. El B-mode puede generarse, ' ...
                 'pero el eje lateral se mostrará como número de línea.\n\n']);
    end
end


function value = pick(sources, aliases, required)
    value = [];

    for s = 1:numel(sources)
        [value, found] = findRecursive(sources{s}, aliases);
        if found
            return;
        end
    end

    if required
        error('No se encontró el parámetro requerido: %s', strjoin(aliases, ' / '));
    end
end


function [value, found] = findRecursive(S, aliases)
    value = [];
    found = false;

    if ~isstruct(S) || isempty(S)
        return;
    end

    names = fieldnames(S);

    % Buscar primero en el nivel actual
    for i = 1:numel(aliases)
        idx = find(strcmpi(names, aliases{i}), 1);
        if ~isempty(idx)
            value = S.(names{idx});
            found = true;
            return;
        end
    end

    % Después buscar en subestructuras
    for i = 1:numel(names)
        child = S.(names{i});
        if isstruct(child) && isscalar(child)
            [value, found] = findRecursive(child, aliases);
            if found
                return;
            end
        end
    end
end
