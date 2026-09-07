%% Homogeneous reference simulations
clearvars
clc

%% Reproducibility
rng(23)
addpath(genpath(pwd))

%% Configuración de la GUI 
% El .mat se guarda junto a este pipeline cuando se pulsa Save.
configurationFile = fullfile(fileparts(mfilename('fullpath')), 'ejemplo_at_configuration.mat');
if ~isfile(configurationFile)
    error('No se encontró la configuración generada por la GUI: %s', configurationFile);
end
loadedConfiguration = load(configurationFile, 'configuration');
referenceConfiguration = loadedConfiguration.configuration.reference;

%No asi necesito que se mantenga la estructura lo mas que se pueda del
%original, por ejemplo el uso de gpu deberia estar despues de clc, y asi
%con la mayoria no estas revisando que tenga la misma estructura si haces
%configuraciones extra o de la app que sean al final del codigo si en caso
%ocurra al mismo moneto que las variables y asi o al inicio del codigo.


%% Defino estructura
% Cada cambio definido con Set se conserva como una variación.
variationPlan = struct('path', {}, 'values', {}, 'reference', {}, 'label', {});

experimentCases = makeExperimentCases(referenceConfiguration, variationPlan);

for ii = 1:numel(experimentCases)

    caseConfiguration = experimentCases(ii).configuration;
    isReference = experimentCases(ii).is_reference;

    nRefs = caseConfiguration.reproducibility.n_refs_target;
    refSeedBase = caseConfiguration.reproducibility.ref_seed_base;

    %% Medium parameters

    c0 = caseConfiguration.medium.sound_speed;                 % sound speed [m/s]
    rho0 = caseConfiguration.medium.density;                    % density [kg/m^3]

    hom_alpha = caseConfiguration.medium.hom_alpha;             % [dB/(MHz^y cm)]
    density_std = caseConfiguration.medium.density_std;

    % Important: hom_alpha changes here for every value in the queue.
    if isReference
        nRefs = caseConfiguration.reproducibility.n_refs_reference;
    end

    simuName = makeSimulationName(experimentCases(ii), hom_alpha, density_std);
    outputFolder = fullfile(pwd, simuName);

    if ~exist(outputFolder, 'dir')
        mkdir(outputFolder);
    end

    %% Source parameters

    source_f0 = caseConfiguration.transducer.frequency;          % source frequency [Hz]
    source_amp = caseConfiguration.transducer.amplitude;         % source pressure [Pa]
    source_cycles = caseConfiguration.transducer.cycles;         % number of toneburst cycles
    source_focus = caseConfiguration.transducer.source_focus;    % focal length [m]
    element_pitch = caseConfiguration.transducer.element_pitch;  % pitch [m]
    element_width = caseConfiguration.transducer.element_width;  % width [m]
    focal_number_Tx = caseConfiguration.transducer.focal_number_tx;
    focal_number_Rx = caseConfiguration.transducer.focal_number_rx;
    nLines = caseConfiguration.transducer.n_lines;                % number of beams

    %% Grid parameters

    grid_size_x = caseConfiguration.geometry.grid_size_x;         % [m]
    grid_size_y = caseConfiguration.geometry.grid_size_y;         % [m]

    %% Transducer position

    base_translation = [caseConfiguration.transducer.base_translation_x, ...
        caseConfiguration.transducer.base_translation_y];
    rotation = caseConfiguration.transducer.rotation;

    %% Computational parameters

    DATA_CAST = caseConfiguration.computation.data_cast;          % 'single' or 'gpuArray-single'
    if startsWith(DATA_CAST, 'gpuArray')
        parallel.gpu.enableCUDAForwardCompatibility(true)
    end
    ppw = caseConfiguration.geometry.ppw;                         % points per wavelength
    depth = caseConfiguration.geometry.depth;                     % imaging depth [m]
    cfl = caseConfiguration.geometry.cfl;                         % CFL number
    PMLSize = [caseConfiguration.geometry.pml_size_x, ...
        caseConfiguration.geometry.pml_size_y];

    plotSimFlag = caseConfiguration.computation.plot_sim_flag;

    %% Grid

    % Calculate the grid spacing based on the PPW and F0
    dx = c0 / (ppw * source_f0);                                  % [m]

    % Compute the size of the grid
    Nx = roundEven(grid_size_x / dx);
    Ny = roundEven(grid_size_y / dx);

    % Create the computational grid
    kgrid = kWaveGrid(Nx, dx, Ny, dx);

    % Create the time array
    t_end = depth * 2 / c0;                                        % [s]
    kgrid.makeTime(c0, cfl, t_end);

    %% Source / array setup

    aperture_Rx = source_focus / focal_number_Rx;
    aperture_Tx = source_focus / focal_number_Tx;

    element_num_Tx = floor(aperture_Tx / element_pitch);
    element_num = floor(aperture_Rx / element_pitch);

    amp_vector = source_amp * ones(element_num, 1);

    no_Tx_elements = floor((element_num - element_num_Tx) / 2);
    amp_vector(1:no_Tx_elements) = 0;
    amp_vector(end-no_Tx_elements+1:end) = 0;

    % Set indices for each element
    ids = (0:element_num-1) - (element_num-1)/2;

    % Set time delays for each element to focus at source_focus
    time_delays = -(sqrt((ids .* element_pitch).^2 + source_focus.^2) - source_focus) ./ c0;
    time_delays = time_delays - min(time_delays);

    % Create time-varying source signals
    source_sig = amp_vector .* toneBurst(1/kgrid.dt, source_f0, ...
        source_cycles, 'SignalOffset', round(time_delays / kgrid.dt));

    % Create empty kWaveArray
    karray = kWaveArray('BLITolerance', 0.05, 'UpsamplingRate', 10);

    % Add rectangular elements
    for ind = 1:element_num
        y_pos = 0 - (element_num * element_pitch/2 - element_pitch/2) ...
            + (ind-1) * element_pitch;
        karray.addRectElement([0, y_pos], element_width/4, element_width, rotation);
    end

    %% Scanline coordinates
    yCords = ((0:nLines-1) - (nLines-1)/2) * element_pitch;

    %% Input options for k-Wave
    input_args = {...
        'PMLInside', false, ...
        'PMLSize', PMLSize, ...
        'DataCast', DATA_CAST, ...
        'DataRecast', true, ...
        'PlotSim', plotSimFlag};

    %% Reference simulation loop

    manifest = struct([]);

    for iRef = 1:nRefs

        refSeed = refSeedBase + iRef;
        rng(refSeed);

        fprintf('\\n========================================\\n');
        fprintf('Running homogeneous case %d of %d\\n', iRef, nRefs);
        fprintf('Seed: %d\\n', refSeed);
        fprintf('========================================\\n');

        %% Homogeneous medium

        medium = makeHomogeneousDensityOnlyMedium( ...
            Nx, Ny, c0, rho0, density_std, hom_alpha);

        medium.alpha_power = caseConfiguration.medium.alpha_power;
        medium.alpha_mode = caseConfiguration.medium.alpha_mode;
        medium.sound_speed_ref = caseConfiguration.medium.sound_speed_ref;

        % Optional: save a medium preview for each reference
        if caseConfiguration.output.save_medium_previews
            saveMediumPreview(kgrid, medium, base_translation, outputFolder, iRef);
        end

        %% Allocate RF data

        rf_prebf = zeros(kgrid.Nt, element_num, nLines);

        %% Beam loop

        for iLine = 1:nLines
            translation = base_translation;
            translation(2) = yCords(iLine);
            karray.setArrayPosition(translation, rotation)

            source.p_mask = karray.getArrayBinaryMask(kgrid);
            source.p = karray.getDistributedSourceSignal(kgrid, source_sig);

            fprintf('Case %d/%d | Line %d/%d\\n', iRef, nRefs, iLine, nLines);

            %% Sensor
            sensor.mask = karray.getArrayBinaryMask(kgrid);
            sensor.directivity_size = caseConfiguration.sensor.directivity_size_factor * kgrid.dx;
            sensor.directivity_angle = caseConfiguration.sensor.directivity_angle ...
                * ones(size(sensor.mask));

            %% Simulation
            sensor_data = runKWaveSolver(caseConfiguration.computation.solver, ...
                kgrid, medium, source, sensor, input_args);

            combined_sensor_data = karray.combineSensorData(kgrid, sensor_data);
            rf_prebf(:, :, iLine) = combined_sensor_data';
        end

        %% Axes and metadata

        fs = 1 / kgrid.dt;
        offset = 1;
        axAxis = (0:kgrid.Nt-1) * kgrid.dt * c0 / 2;
        z = axAxis(offset:end);
        x = yCords;

        density_map = medium.density;
        alpha_coeff = medium.alpha_coeff;
        sound_speed = medium.sound_speed;

        outFile = fullfile(outputFolder, sprintf('rf_prebf_homRef_%03d.mat', iRef));
        if caseConfiguration.output.save_rf_prebeamformed
            save(outFile, ...
                'rf_prebf', 'x', 'z', 'fs', 'time_delays', ...
                'density_map', 'alpha_coeff', 'sound_speed', ...
                'density_std', 'hom_alpha', 'c0', 'rho0', ...
                'source_f0', 'source_amp', 'source_cycles', 'source_focus', ...
                'element_pitch', 'element_width', ...
                'focal_number_Tx', 'focal_number_Rx', 'nLines', 'depth', ...
                'grid_size_x', 'grid_size_y', 'dx', 'ppw', 'cfl', 'PMLSize', ...
                'refSeed', 'iRef', 'simuName', '-v7.3');
        else
            outFile = '';
        end

        manifest(iRef).file = outFile;
        manifest(iRef).seed = refSeed;
        manifest(iRef).density_std = density_std;
        manifest(iRef).alpha_coeff = hom_alpha;
    end

    save(fullfile(outputFolder, 'reference_manifest.mat'), ...
        'manifest', 'nRefs', 'refSeedBase', 'density_std', 'hom_alpha');

    fprintf('\\nDone. Saved %d homogeneous reference files in:\\n%s\\n', ...
        nRefs, outputFolder);
end

%% Local helper functions

function cases = makeExperimentCases(referenceConfiguration, variationPlan)
    if isempty(variationPlan)
        cases = struct('configuration', referenceConfiguration, 'is_reference', true, ...
            'is_alpha_sweep', false, 'tag', 'reference');
        return
    end

    indexVectors = cell(1, numel(variationPlan));
    for parameterIndex = 1:numel(variationPlan)
        indexVectors{parameterIndex} = 1:numel(variationPlan(parameterIndex).values);
    end
    grids = cell(1, numel(variationPlan));
    [grids{:}] = ndgrid(indexVectors{:});
    targetCount = numel(grids{1});
    isAlphaSweep = numel(variationPlan) == 1 && ...
        strcmp(variationPlan.path, 'medium.hom_alpha');
    cases = repmat(struct('configuration', struct(), 'is_reference', false, ...
        'is_alpha_sweep', isAlphaSweep, 'tag', ''), 1, targetCount + 1);

    for caseIndex = 1:targetCount
        configuration = referenceConfiguration;
        tokens = strings(1, numel(variationPlan));
        for parameterIndex = 1:numel(variationPlan)
            valueIndex = grids{parameterIndex}(caseIndex);
            value = variationPlan(parameterIndex).values{valueIndex};
            configuration = setConfigurationValue(configuration, variationPlan(parameterIndex).path, value);
            tokens(parameterIndex) = variationPlan(parameterIndex).path + '_' + valueToken(value);
        end
        cases(caseIndex).configuration = configuration;
        cases(caseIndex).is_reference = false;
        cases(caseIndex).tag = char(strjoin(tokens, '__'));
    end

    cases(end).configuration = referenceConfiguration;
    cases(end).is_reference = true;
    cases(end).tag = 'reference';
end

function configuration = setConfigurationValue(configuration, path, value)
    parts = strsplit(path, '.');
    configuration.(parts{1}).(parts{2}) = value;
end

function simuName = makeSimulationName(experimentCase, hom_alpha, density_std)
    isAlphaSweep = experimentCase.is_alpha_sweep;
    if isAlphaSweep
        if experimentCase.is_reference
            simuName = ['homogeneus_ref_alpha', valueToken(hom_alpha), ...
                '_std', valueToken(density_std)];
        else
            simuName = ['homogeneus_target_alpha', valueToken(hom_alpha), ...
                '_std', valueToken(density_std)];
        end
        return
    end

    if experimentCase.is_reference
        simuName = 'homogeneous_ref';
    else
        simuName = ['homogeneous_target_', experimentCase.tag];
    end
end

function token = valueToken(value)
    if isnumeric(value)
        token = strrep(num2str(value, '%.8g'), '.', 'p');
        token = strrep(token, '-', 'm');
    elseif islogical(value)
        token = char(string(value));
    else
        token = regexprep(char(string(value)), '[^A-Za-z0-9_-]', '_');
    end
end

function saveMediumPreview(kgrid, medium, base_translation, outputFolder, iRef)
    rx = kgrid.y;
    rz = kgrid.x - base_translation(1);
    figMedium = figure('Units', 'centimeters', 'Position', [5 5 25 10], 'Visible', 'off');
    tiledlayout(1, 3)
    nexttile; imagesc(100 * rx(1,:), 100 * rz(:,1), medium.sound_speed);
    xlabel('x [cm]'); ylabel('z [cm]'); title('Sound speed'); c = colorbar; ylabel(c, 'm/s'); axis image
    nexttile; imagesc(100 * rx(1,:), 100 * rz(:,1), medium.density);
    xlabel('x [cm]'); ylabel('z [cm]'); title('Density'); c = colorbar; ylabel(c, 'kg/m^3'); axis image
    nexttile; imagesc(100 * rx(1,:), 100 * rz(:,1), medium.alpha_coeff, [0.4 1.0]);
    xlabel('x [cm]'); ylabel('z [cm]'); title('Absorption'); c = colorbar; ylabel(c, 'dB/cm/MHz'); axis image
    sgtitle(sprintf('Homogeneous reference %03d', iRef))
    savefig(figMedium, fullfile(outputFolder, sprintf('medium_homRef_%03d.fig', iRef)));
    saveas(figMedium, fullfile(outputFolder, sprintf('medium_homRef_%03d.png', iRef)));
    close(figMedium)
end

function sensor_data = runKWaveSolver(solverName, kgrid, medium, source, sensor, input_args)
    if strcmpi(solverName, 'kspaceFirstoOrder2D')
        solverName = 'kspaceFirstOrder2D';
    end
    sensor_data = feval(solverName, kgrid, medium, source, sensor, input_args{:});
end

function medium = makeHomogeneousDensityOnlyMedium(Nx, Ny, c0, rho0, densityStd, alpha)
    medium.sound_speed = c0 * ones(Nx, Ny);
    medium.density = rho0 .* (1 + densityStd * randn(Nx, Ny));
    medium.alpha_coeff = alpha * ones(Nx, Ny);
end
