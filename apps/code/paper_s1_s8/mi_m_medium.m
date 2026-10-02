%% Homogeneous reference simulations
clc

scriptFolder = fileparts(mfilename('fullpath'));
if isempty(scriptFolder), scriptFolder = pwd; end
cd(scriptFolder);
%% Reproducibility
rng(23)
addpath(genpath(scriptFolder))

%% Output setup
for ii = 1:9
    % Values are stored in the local function at the end of this file.
    parameters = getGuiCaseParameters(ii, []);

    nRefs = parameters.nRefs;
    refSeedBase = parameters.refSeedBase;
    saveMediumPreviews = parameters.saveMediumPreviews;
    saveRfPrebeamformed = parameters.saveRfPrebeamformed;

    %% Medium parameters
    c0 = parameters.c0;
    rho0 = parameters.rho0;
    hom_alpha = parameters.hom_alpha;
    density_std = parameters.density_std;
    alpha_power = parameters.alpha_power;
    alpha_mode = parameters.alpha_mode;
    sound_speed_ref = parameters.sound_speed_ref;
    simuName = parameters.simuName;

    outputFolder = fullfile(scriptFolder, 'out', simuName);
    if ~exist(outputFolder, 'dir')
        mkdir(outputFolder);
    end

    %% Source parameters

    source_f0 = parameters.source_f0;
    source_amp = parameters.source_amp;
    source_cycles = parameters.source_cycles;
    source_focus = parameters.source_focus;
    element_pitch = parameters.element_pitch;
    element_width = parameters.element_width;
    focal_number_Tx = parameters.focal_number_Tx;
    focal_number_Rx = parameters.focal_number_Rx;
    nLines = parameters.nLines;
    transmit_mode = parameters.transducerBeamMode;
    steering_angles_deg = parameters.steeringAnglesDeg;
    synthetic_aperture_stride = parameters.syntheticApertureStride;
    element_count = parameters.elementCount;

    %% Grid parameters

    grid_size_x = parameters.grid_size_x;
    grid_size_y = parameters.grid_size_y;

    %% Transducer position

    base_translation = parameters.base_translation;
    rotation = parameters.rotation;

    %% Computational parameters

    DATA_CAST = parameters.DATA_CAST;
    ppw = parameters.ppw;
    depth = parameters.depth;
    cfl = parameters.cfl;
    PMLSize = parameters.PMLSize;
    plotSimFlag = parameters.plotSimFlag;
    solverName = parameters.solverName;
    if strcmpi(DATA_CAST, 'gpuArray-single')
        try
            parallel.gpu.enableCUDAForwardCompatibility(true);
        catch exception
            warning('QUS:GPUCompatibility', ...
                'No se pudo habilitar CUDA forward compatibility: %s', exception.message);
        end
    end
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
    if strcmpi(transmit_mode, 'Focused')
        element_num = floor(aperture_Rx / element_pitch);
    else
        element_num = element_count; % PWC y SA usan el arreglo físico completo.
    end

    focused_amp_vector = source_amp * ones(element_num, 1);

    inactive_Tx_elements = element_num - element_num_Tx;
    left_inactive_Tx = floor(inactive_Tx_elements / 2);
    right_inactive_Tx = ceil(inactive_Tx_elements / 2);
    if left_inactive_Tx > 0
        focused_amp_vector(1:left_inactive_Tx) = 0;
    end
    if right_inactive_Tx > 0
        focused_amp_vector(end-right_inactive_Tx+1:end) = 0;
    end

    % Set indices for each element
    ids = (0:element_num-1) - (element_num-1)/2;

    % Retardos del modo focalizado; PWC y SA se calculan por evento.
    focused_time_delays = -(sqrt((ids .* element_pitch).^2 + source_focus.^2) - source_focus) ./ c0;
    focused_time_delays = focused_time_delays - min(focused_time_delays);

    % Create empty kWaveArray
    karray = kWaveArray('BLITolerance', 0.05, 'UpsamplingRate', 10);

    % Add rectangular elements
    for ind = 1:element_num
        y_pos = 0 - (element_num * element_pitch/2 - element_pitch/2) ...
            + (ind-1) * element_pitch;
        karray.addRectElement([0, y_pos], element_width/4, element_width, rotation);
    end

    %% Acquisition events
    if strcmpi(transmit_mode, 'Focused')
        acquisition_mode = 'focused_scan';
        event_values = ((0:nLines-1) - (nLines-1)/2) * element_pitch; % Posición lateral de cada línea.
        assertLateralScanCoverage(grid_size_y, source_focus, element_pitch, element_width, ...
            focal_number_Rx, nLines, base_translation(2), simuName);
    elseif strcmpi(transmit_mode, 'Plane Wave Compounding')
        acquisition_mode = 'plane_wave_compounding';
        event_values = steering_angles_deg(:).'; % Un evento por ángulo Tx.
        assertArrayCoverage(grid_size_y, element_num, element_pitch, element_width, base_translation(2), simuName);
    elseif strcmpi(transmit_mode, 'Synthetic Aperture')
        acquisition_mode = 'synthetic_aperture';
        event_values = 1:synthetic_aperture_stride:element_num; % Índice del único elemento Tx activo.
        assertArrayCoverage(grid_size_y, element_num, element_pitch, element_width, base_translation(2), simuName);
    else
        error('Modo de emisión no reconocido: %s', transmit_mode);
    end
    event_count = numel(event_values);

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
        fprintf('Running homogeneous reference %d of %d\\n', iRef, nRefs);
        fprintf('Seed: %d\\n', refSeed);
        fprintf('========================================\\n');

        %% Acoustic medium

        if strcmpi(parameters.mediumModel, 'Homogeneo')
            medium = makeHomogeneousDensityOnlyMedium( ...
                Nx, Ny, c0, rho0, density_std, hom_alpha);
        elseif strcmpi(parameters.mediumModel, 'Inclusión circular')
            medium = makeCircularInclusion(Nx, Ny, dx, base_translation(1), ...
                c0, rho0, density_std, hom_alpha, parameters.inclusionCenterMm, ...
                parameters.inclusionGeometryMm, parameters.inclusionAlpha, ...
                parameters.inclusionSoundSpeed, parameters.inclusionDensity, ...
                parameters.inclusionDensityStd);
        elseif any(strcmpi(parameters.mediumModel, {'Inclusión irregular', 'Inclusión elipsoidal'}))
            medium = makeIrregularInclusion(Nx, Ny, dx, base_translation(1), ...
                c0, rho0, density_std, hom_alpha, parameters.inclusionShape{1}, ...
                parameters.inclusionCenterMm(1, :), parameters.inclusionGeometryMm(1, :), ...
                parameters.inclusionAlpha(1), parameters.inclusionSoundSpeed(1), ...
                parameters.inclusionDensity(1), parameters.inclusionDensityStd(1));
        elseif strcmpi(parameters.mediumModel, 'Múltiples inclusiones')
            medium = makeMultipleInclusion(Nx, Ny, dx, base_translation(1), ...
                c0, rho0, density_std, hom_alpha, parameters.inclusionShape, ...
                parameters.inclusionCenterMm, parameters.inclusionGeometryMm, ...
                parameters.inclusionAlpha, parameters.inclusionSoundSpeed, ...
                parameters.inclusionDensity, parameters.inclusionDensityStd);
        elseif any(strcmpi(parameters.mediumModel, {'Medio por capas', 'Capas'}))
            medium = makeMultipleLayers(Nx, Ny, dx, base_translation(1), ...
                c0, rho0, density_std, hom_alpha, parameters.layerThicknessMm, ...
                parameters.layerAlpha, parameters.layerSoundSpeed, ...
                parameters.layerDensity, parameters.layerDensityStd);
        else
            error('Modelo acústico no reconocido: %s', parameters.mediumModel);
        end

        medium.alpha_power = alpha_power;
        medium.alpha_mode = alpha_mode;
        medium.sound_speed_ref = sound_speed_ref;

        %% Medium properties
        % Same sound-speed, density and ACS preview as the baseline.
        if saveMediumPreviews
            saveMediumPreview(kgrid, medium, base_translation, depth, outputFolder, iRef);
        end

        %% Allocate RF data

        rf_prebf = zeros(kgrid.Nt, element_num, event_count);
        tx_delays_s = zeros(event_count, element_num);

        %% Acquisition event loop

        for iEvent = 1:event_count
            translation = base_translation;
            if strcmp(acquisition_mode, 'focused_scan')
                translation(2) = base_translation(2) + event_values(iEvent);
                event_amp = focused_amp_vector;
                event_delays = focused_time_delays;
            elseif strcmp(acquisition_mode, 'plane_wave_compounding')
                event_amp = source_amp * ones(element_num, 1);
                theta = deg2rad(event_values(iEvent));
                event_delays = ids .* element_pitch .* sin(theta) ./ c0;
                event_delays = event_delays - min(event_delays); % Inclina el frente sin retardos negativos.
            else
                event_amp = zeros(element_num, 1);
                event_amp(event_values(iEvent)) = source_amp; % SA: transmite uno y reciben todos.
                event_delays = zeros(size(ids));
            end
            tx_delays_s(iEvent, :) = event_delays;
            source_sig = event_amp .* toneBurst(1/kgrid.dt, source_f0, ...
                source_cycles, 'SignalOffset', round(event_delays / kgrid.dt));
            karray.setArrayPosition(translation, rotation)

            source.p_mask = karray.getArrayBinaryMask(kgrid);
            source.p = karray.getDistributedSourceSignal(kgrid, source_sig);

            fprintf('Reference %d/%d | Event %d/%d (%s)\\n', ...
                iRef, nRefs, iEvent, event_count, acquisition_mode);

            %% Sensor
            directivity_size_factor = parameters.directivity_size_factor;
            directivity_angle = parameters.directivity_angle;
            sensor.mask = karray.getArrayBinaryMask(kgrid);
            sensor.directivity_size = directivity_size_factor * kgrid.dx;
            sensor.directivity_angle = directivity_angle ...
                * ones(size(sensor.mask));

            %% Simulation
            sensor_data = runKWaveSolver(solverName, ...
                kgrid, medium, source, sensor, input_args);

            % Combine sensor data into element RF channels.
            combined_sensor_data = karray.combineSensorData(kgrid, sensor_data);
            % Store as [time, receive element, transmit event].
            rf_prebf(:, :, iEvent) = combined_sensor_data';
        end

        %% Axes and metadata

        fs = 1 / kgrid.dt;
        offset = 1;
        axAxis = (0:kgrid.Nt-1) * kgrid.dt * c0 / 2;
        z = axAxis(offset:end);
        if strcmp(acquisition_mode, 'focused_scan')
            x = base_translation(2) + event_values;
        elseif strcmp(acquisition_mode, 'synthetic_aperture')
            x = base_translation(2) + ids(event_values) * element_pitch;
        else
            x = []; % En PWC los eventos son ángulos, no líneas laterales.
        end
        tx_event_values = event_values;

        if strcmp(acquisition_mode, 'focused_scan')
            active_tx_elements = element_num_Tx;
        elseif strcmp(acquisition_mode, 'plane_wave_compounding')
            active_tx_elements = element_num;
        else
            active_tx_elements = 1;
        end
        nEvents = event_count;
        activeTx = focused_amp_vector ~= 0;
        txPositions = ids(activeTx) * element_pitch;
        txDelays = round(focused_time_delays(activeTx) / kgrid.dt) * kgrid.dt;
        pulseDuration = floor(source_cycles / source_f0 * fs) / fs;
        if strcmp(acquisition_mode, 'focused_scan')
            time_zero_s = median(txDelays + (sqrt(source_focus^2 + txPositions.^2) - source_focus) / c0) ...
                + pulseDuration / 2; % Referencia temporal del foco fijo Tx.
            time_delays = focused_time_delays; % Compatibilidad con el beamformer focalizado.
        else
            time_zero_s = median(tx_delays_s, 2).' + pulseDuration / 2;
            time_delays = tx_delays_s;
        end
        density_map = medium.density;
        alpha_coeff = medium.alpha_coeff;
        sound_speed = medium.sound_speed;

        outFile = fullfile(outputFolder, sprintf('rf_prebf_homRef_%03d.mat', iRef));
        if saveRfPrebeamformed
            save(outFile, ...
                'rf_prebf', 'x', 'z', 'fs', 'time_delays', ...
                'density_map', 'alpha_coeff', 'sound_speed', ...
                'density_std', 'hom_alpha', 'c0', 'rho0', ...
                'source_f0', 'source_amp', 'source_cycles', 'source_focus', ...
                'element_pitch', 'element_width', ...
                'focal_number_Tx', 'focal_number_Rx', 'active_tx_elements', 'time_zero_s', 'nLines', 'depth', ...
                'acquisition_mode', 'transmit_mode', 'tx_event_values', 'tx_delays_s', 'nEvents', 'element_count', ...
                'grid_size_x', 'grid_size_y', 'dx', 'ppw', 'cfl', 'PMLSize', ...
                'base_translation', 'rotation', ...
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

%% Funciones

% getGuiCaseParameters devuelve el snapshot serializado de cada caso de la GUI.
function parameters = getGuiCaseParameters(ii, ~)
    % Snapshot autónomo de los valores seleccionados en la GUI.
    % No carga MAT: este M se puede enviar solo al cluster.
    switch ii
        case 1
            parameters = struct;
            parameters.isReference = true;
            parameters.nRefs = 1;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.7;
            parameters.density_std = 0.04;
            parameters.simuName = 'paper_s1_s8';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.02;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 2;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 91;
            parameters.grid_size_x = 0.0405;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.02023273273273274 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.04;
            parameters.cfl = 0.3;
            parameters.PMLSize = [41 41];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = true;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 128;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Homogeneo';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Focused';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 20];
            parameters.inclusionGeometryMm = [7 0];
            parameters.inclusionAlpha = 1;
            parameters.inclusionSoundSpeed = 1540;
            parameters.inclusionDensity = 1060;
            parameters.inclusionDensityStd = 0.04;
            parameters.layerThicknessMm = [27.5 27.5];
            parameters.layerAlpha = [0.5 1];
            parameters.layerSoundSpeed = [1540 1540];
            parameters.layerDensity = [1060 1060];
            parameters.layerDensityStd = [0.04 0.04];
        case 2
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 2;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.04;
            parameters.simuName = 'paper_S1_layers_equal_bs';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.02;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 2;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 91;
            parameters.grid_size_x = 0.0405;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.02023273273273274 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.04;
            parameters.cfl = 0.3;
            parameters.PMLSize = [41 41];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = true;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 128;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Medio por capas';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Focused';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 20];
            parameters.inclusionGeometryMm = [7 0];
            parameters.inclusionAlpha = 1;
            parameters.inclusionSoundSpeed = 1540;
            parameters.inclusionDensity = 1060;
            parameters.inclusionDensityStd = 0.04;
            parameters.layerThicknessMm = [20 20];
            parameters.layerAlpha = [0.5 1];
            parameters.layerSoundSpeed = [1540 1540];
            parameters.layerDensity = [1060 1060];
            parameters.layerDensityStd = [0.04 0.04];
        case 3
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 2;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.04;
            parameters.simuName = 'paper_S2_layers_plus12dB_bs';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.02;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 2;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 91;
            parameters.grid_size_x = 0.0405;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.02023273273273274 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.04;
            parameters.cfl = 0.3;
            parameters.PMLSize = [41 41];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = true;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 128;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Medio por capas';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Focused';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 20];
            parameters.inclusionGeometryMm = [7 0];
            parameters.inclusionAlpha = 1;
            parameters.inclusionSoundSpeed = 1540;
            parameters.inclusionDensity = 1060;
            parameters.inclusionDensityStd = 0.04;
            parameters.layerThicknessMm = [20 20];
            parameters.layerAlpha = [0.5 1];
            parameters.layerSoundSpeed = [1540 1540];
            parameters.layerDensity = [1060 1060];
            parameters.layerDensityStd = [0.04 0.1592428682213989];
        case 4
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 2;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.04;
            parameters.simuName = 'paper_S3_layers_minus12dB_bs';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.02;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 2;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 91;
            parameters.grid_size_x = 0.0405;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.02023273273273274 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.04;
            parameters.cfl = 0.3;
            parameters.PMLSize = [41 41];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = true;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 128;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Medio por capas';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Focused';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 20];
            parameters.inclusionGeometryMm = [7 0];
            parameters.inclusionAlpha = 1;
            parameters.inclusionSoundSpeed = 1540;
            parameters.inclusionDensity = 1060;
            parameters.inclusionDensityStd = 0.04;
            parameters.layerThicknessMm = [20 20];
            parameters.layerAlpha = [0.5 1];
            parameters.layerSoundSpeed = [1540 1540];
            parameters.layerDensity = [1060 1060];
            parameters.layerDensityStd = [0.04 0.01004754572603832];
        case 5
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 2;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.75;
            parameters.density_std = 0.04;
            parameters.simuName = 'paper_S4_homogeneous_acs_plus12dB_bs';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.02;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 2;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 91;
            parameters.grid_size_x = 0.0405;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.02023273273273274 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.04;
            parameters.cfl = 0.3;
            parameters.PMLSize = [41 41];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = true;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 128;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Medio por capas';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Focused';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 20];
            parameters.inclusionGeometryMm = [7 0];
            parameters.inclusionAlpha = 1;
            parameters.inclusionSoundSpeed = 1540;
            parameters.inclusionDensity = 1060;
            parameters.inclusionDensityStd = 0.04;
            parameters.layerThicknessMm = [20 20];
            parameters.layerAlpha = [0.75 0.75];
            parameters.layerSoundSpeed = [1540 1540];
            parameters.layerDensity = [1060 1060];
            parameters.layerDensityStd = [0.04 0.1592428682213989];
        case 6
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 2;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.04;
            parameters.simuName = 'paper_S5_inclusion_equal_bs';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.02;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 2;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 91;
            parameters.grid_size_x = 0.0405;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.02023273273273274 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.04;
            parameters.cfl = 0.3;
            parameters.PMLSize = [41 41];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = true;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 128;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Inclusión circular';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Focused';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 20];
            parameters.inclusionGeometryMm = [7 0];
            parameters.inclusionAlpha = 1;
            parameters.inclusionSoundSpeed = 1540;
            parameters.inclusionDensity = 1060;
            parameters.inclusionDensityStd = 0.04;
            parameters.layerThicknessMm = [27.5 27.5];
            parameters.layerAlpha = [0.5 1];
            parameters.layerSoundSpeed = [1540 1540];
            parameters.layerDensity = [1060 1060];
            parameters.layerDensityStd = [0.04 0.04];
        case 7
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 2;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.04;
            parameters.simuName = 'paper_S6_inclusion_plus12dB_bs';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.02;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 2;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 91;
            parameters.grid_size_x = 0.0405;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.02023273273273274 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.04;
            parameters.cfl = 0.3;
            parameters.PMLSize = [41 41];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = true;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 128;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Inclusión circular';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Focused';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 20];
            parameters.inclusionGeometryMm = [7 0];
            parameters.inclusionAlpha = 1;
            parameters.inclusionSoundSpeed = 1540;
            parameters.inclusionDensity = 1060;
            parameters.inclusionDensityStd = 0.1592428682213989;
            parameters.layerThicknessMm = [27.5 27.5];
            parameters.layerAlpha = [0.5 1];
            parameters.layerSoundSpeed = [1540 1540];
            parameters.layerDensity = [1060 1060];
            parameters.layerDensityStd = [0.04 0.04];
        case 8
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 2;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.04;
            parameters.simuName = 'paper_S7_inclusion_minus12dB_bs';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.02;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 2;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 91;
            parameters.grid_size_x = 0.0405;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.02023273273273274 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.04;
            parameters.cfl = 0.3;
            parameters.PMLSize = [41 41];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = true;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 128;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Inclusión circular';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Focused';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 20];
            parameters.inclusionGeometryMm = [7 0];
            parameters.inclusionAlpha = 1;
            parameters.inclusionSoundSpeed = 1540;
            parameters.inclusionDensity = 1060;
            parameters.inclusionDensityStd = 0.01004754572603832;
            parameters.layerThicknessMm = [27.5 27.5];
            parameters.layerAlpha = [0.5 1];
            parameters.layerSoundSpeed = [1540 1540];
            parameters.layerDensity = [1060 1060];
            parameters.layerDensityStd = [0.04 0.04];
        case 9
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 2;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 1;
            parameters.density_std = 0.04;
            parameters.simuName = 'paper_S8_multiple_inclusions';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.02;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 2;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 91;
            parameters.grid_size_x = 0.0405;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.02023273273273274 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.04;
            parameters.cfl = 0.3;
            parameters.PMLSize = [41 41];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = true;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 128;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Múltiples inclusiones';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Focused';
            parameters.inclusionShape = {'circle', 'circle', 'circle'};
            parameters.inclusionCenterMm = [-7 10;7 18;-5 30];
            parameters.inclusionGeometryMm = [4 0;6 0;5 0];
            parameters.inclusionAlpha = [0.5 0.5 1];
            parameters.inclusionSoundSpeed = [1540 1540 1540];
            parameters.inclusionDensity = [1060 1060 1060];
            parameters.inclusionDensityStd = [0.1592428682213989 0.01004754572603832 0.1592428682213989];
            parameters.layerThicknessMm = [27.5 27.5];
            parameters.layerAlpha = [0.5 1];
            parameters.layerSoundSpeed = [1540 1540];
            parameters.layerDensity = [1060 1060];
            parameters.layerDensityStd = [0.04 0.04];
        otherwise
            error('Unknown experiment case: %d', ii);
    end
end

% saveMediumPreview exporta los mapas usando la misma profundidad física que la GUI.
function saveMediumPreview(kgrid, medium, base_translation, depth, outputFolder, iRef)
    rx = kgrid.y;
    rz = kgrid.x - base_translation(1); % Expresa z desde la superficie del transductor.
    figMedium = figure('Units', 'centimeters', 'Position', [5 5 25 10], 'Visible', 'off');
    colormap(figMedium, turbo(256));
    tiledlayout(1, 3)
    nexttile; imagesc(100 * rx(1,:), 100 * rz(:,1), medium.sound_speed);
    xlabel('x [cm]'); ylabel('z [cm]'); title('Sound speed'); c = colorbar; ylabel(c, 'm/s'); axis image; ylim([0, 100 * depth]); set(gca, 'YDir', 'reverse');
    nexttile; imagesc(100 * rx(1,:), 100 * rz(:,1), medium.density);
    xlabel('x [cm]'); ylabel('z [cm]'); title('Density'); c = colorbar; ylabel(c, 'kg/m^3'); axis image; ylim([0, 100 * depth]); set(gca, 'YDir', 'reverse');
    nexttile; imagesc(100 * rx(1,:), 100 * rz(:,1), medium.alpha_coeff, [0.35 1.05]);
    xlabel('x [cm]'); ylabel('z [cm]'); title('ACS'); c = colorbar; c.Ticks = 0.4:0.1:1.0; c.TickLabels = {'0.4','','0.6','','0.8','','1'}; ylabel(c, 'ACS [dB/cm/MHz]'); axis image; ylim([0, 100 * depth]); set(gca, 'YDir', 'reverse');
    sgtitle(sprintf('Homogeneous reference %03d', iRef))
    savefig(figMedium, fullfile(outputFolder, sprintf('medium_homRef_%03d.fig', iRef)));
    saveas(figMedium, fullfile(outputFolder, sprintf('medium_homRef_%03d.png', iRef)));
    close(figMedium)
end

% assertLateralScanCoverage detiene adquisiciones con arreglos fuera de la malla lateral.
function assertLateralScanCoverage(gridSizeY, sourceFocus, pitch, elementWidth, fNumberRx, nLines, lateralTranslation, caseName)
    receiveElements = floor(sourceFocus / fNumberRx / pitch);
    receiveWidth = (receiveElements - 1) * pitch + elementWidth;
    requiredWidth = 2 * (abs(lateralTranslation) + (nLines - 1) * pitch / 2 + receiveWidth / 2);
    if receiveElements < 1 || gridSizeY + eps(max(gridSizeY, requiredWidth)) < requiredWidth
        availableHalfWidth = gridSizeY / 2 - abs(lateralTranslation) - receiveWidth / 2;
        maxLines = max(0, floor(2 * availableHalfWidth / pitch) + 1);
        error(['%s: malla lateral insuficiente. Se requieren %.3f mm para %d líneas; ' ...
            'la malla actual es %.3f mm y admite como máximo %d líneas.'], ...
            caseName, 1e3 * requiredWidth, nLines, 1e3 * gridSizeY, maxLines);
    end
end

% assertArrayCoverage valida el arreglo fijo usado por PWC y apertura sintética.
function assertArrayCoverage(gridSizeY, elementCount, pitch, elementWidth, lateralTranslation, caseName)
    arrayWidth = (elementCount - 1) * pitch + elementWidth;
    requiredWidth = 2 * abs(lateralTranslation) + arrayWidth;
    if elementCount < 1 || gridSizeY + eps(max(gridSizeY, requiredWidth)) < requiredWidth
        error('%s: la malla lateral debe medir al menos %.3f mm para contener el arreglo fijo.', ...
            caseName, 1e3 * requiredWidth);
    end
end

% runKWaveSolver valida y ejecuta el solver 2-D permitido por la GUI.
function sensor_data = runKWaveSolver(solverName, kgrid, medium, source, sensor, input_args)
    if strcmpi(solverName, 'kspaceFirstoOrder2D')
        solverName = 'kspaceFirstOrder2D'; % Corrige la grafía histórica guardada por configuraciones previas.
    end
    if ~strcmpi(solverName, 'kspaceFirstOrder2D')
        error('Solver no permitido por este pipeline 2-D: %s', solverName);
    end
    sensor_data = kspaceFirstOrder2D(kgrid, medium, source, sensor, input_args{:});
end

% makeHomogeneousDensityOnlyMedium crea un medio uniforme con variación aleatoria de densidad.
function [medium, densityNoise] = makeHomogeneousDensityOnlyMedium(Nx, Ny, c0, rho0, densityStd, alpha)
    medium.sound_speed = c0 * ones(Nx, Ny);
    densityNoise = randn(Nx, Ny);
    medium.density = rho0 .* (1 + densityStd * densityNoise);
    medium.alpha_coeff = alpha * ones(Nx, Ny);
end

% makeCircularInclusion aplica propiedades acústicas independientes dentro de una inclusión circular.
function medium = makeCircularInclusion(Nx, Ny, dx, baseAxialTranslation, c0, rho0, densityStd, bgAlpha, centerMm, geometryMm, incAlpha, incSoundSpeed, incDensity, incDensityStd)
    [medium, densityNoise] = makeHomogeneousDensityOnlyMedium(Nx, Ny, c0, rho0, densityStd, bgAlpha);
    [zMm, xMm] = mediumCoordinates(Nx, Ny, dx, baseAxialTranslation);
    if ~isfinite(centerMm(2)), centerMm(2) = mean(zMm(:)); end
    mask = (xMm - centerMm(1)).^2 + (zMm - centerMm(2)).^2 <= geometryMm(1).^2;
    medium = applyRegionProperties(medium, densityNoise, mask, incSoundSpeed(1), incDensity(1), incDensityStd(1), incAlpha(1));
end

% makeIrregularInclusion construye una inclusión elíptica, rectangular o irregular.
function medium = makeIrregularInclusion(Nx, Ny, dx, baseAxialTranslation, c0, rho0, densityStd, bgAlpha, shape, centerMm, geometryMm, incAlpha, incSoundSpeed, incDensity, incDensityStd)
    [medium, densityNoise] = makeHomogeneousDensityOnlyMedium(Nx, Ny, c0, rho0, densityStd, bgAlpha);
    [zMm, xMm] = mediumCoordinates(Nx, Ny, dx, baseAxialTranslation);
    if ~isfinite(centerMm(2)), centerMm(2) = mean(zMm(:)); end
    mask = inclusionMask(xMm, zMm, shape, centerMm, geometryMm);
    medium = applyRegionProperties(medium, densityNoise, mask, incSoundSpeed, incDensity, incDensityStd, incAlpha);
end

% makeMultipleInclusion asigna propiedades independientes sin permitir solapamientos.
function medium = makeMultipleInclusion(Nx, Ny, dx, baseAxialTranslation, c0, rho0, densityStd, bgAlpha, shapes, centersMm, geometriesMm, incAlpha, incSoundSpeed, incDensity, incDensityStd)
    [medium, densityNoise] = makeHomogeneousDensityOnlyMedium(Nx, Ny, c0, rho0, densityStd, bgAlpha);
    [zMm, xMm] = mediumCoordinates(Nx, Ny, dx, baseAxialTranslation);
    occupied = false(Nx, Ny);
    for incIndex = 1:numel(incAlpha)
        centerMm = centersMm(incIndex, :);
        if ~isfinite(centerMm(2)), centerMm(2) = mean(zMm(:)); end
        mask = inclusionMask(xMm, zMm, shapes{incIndex}, centerMm, geometriesMm(incIndex, :));
        if any(mask(:) & occupied(:)), error('Las inclusiones no pueden solaparse.'); end % Evita que el último ACS sobrescriba otro.
        medium = applyRegionProperties(medium, densityNoise, mask, incSoundSpeed(incIndex), incDensity(incIndex), incDensityStd(incIndex), incAlpha(incIndex));
        occupied = occupied | mask;
    end
end

% makeMultipleLayers distribuye propiedades acústicas por estratos axiales desde z = 0.
function medium = makeMultipleLayers(Nx, Ny, dx, baseAxialTranslation, c0, rho0, densityStd, bgAlpha, thicknessMm, layerAlpha, layerSoundSpeed, layerDensity, layerDensityStd)
    [medium, densityNoise] = makeHomogeneousDensityOnlyMedium(Nx, Ny, c0, rho0, densityStd, bgAlpha);
    [zMm, ~] = mediumCoordinates(Nx, Ny, dx, baseAxialTranslation);
    % zMm is referenced to the transducer surface: layer 1 starts at z = 0.
    zFromTransducer = zMm;
    lower = 0;
    for layerIndex = 1:numel(layerAlpha)
        upper = lower + thicknessMm(layerIndex);
        if layerIndex == numel(layerAlpha), mask = zFromTransducer >= lower; else, mask = zFromTransducer >= lower & zFromTransducer < upper; end % La última capa cubre el resto del dominio.
        medium = applyRegionProperties(medium, densityNoise, mask, layerSoundSpeed(layerIndex), layerDensity(layerIndex), layerDensityStd(layerIndex), layerAlpha(layerIndex));
        lower = upper;
    end
end

% applyRegionProperties conserva el patrón aleatorio y cambia su contraste por región.
function medium = applyRegionProperties(medium, densityNoise, mask, soundSpeed, density, densityStd, alpha)
    medium.sound_speed(mask) = soundSpeed;
    regionalDensity = density .* (1 + densityStd .* densityNoise);
    medium.density(mask) = regionalDensity(mask); % sigma_rho controla el backscatter local.
    medium.alpha_coeff(mask) = alpha;
end

% mediumCoordinates devuelve coordenadas en mm con z referido a la superficie emisora.
function [zMm, xMm] = mediumCoordinates(Nx, Ny, dx, baseAxialTranslation)
    axialMm = 1e3 .* (((0:Nx-1) - floor(Nx/2)) .* dx - baseAxialTranslation); % Convierte el eje centrado de k-Wave a profundidad física.
    lateralMm = 1e3 .* ((0:Ny-1) - floor(Ny/2)) .* dx;
    [zMm, xMm] = ndgrid(axialMm, lateralMm);
end

% inclusionMask devuelve la máscara geométrica para la forma solicitada.
function mask = inclusionMask(xMm, zMm, shape, centerMm, geometryMm)
    switch lower(char(shape))
        case 'circle'
            mask = (xMm - centerMm(1)).^2 + (zMm - centerMm(2)).^2 <= geometryMm(1).^2;
        case 'ellipse'
            mask = ((xMm - centerMm(1)) ./ geometryMm(1)).^2 + ((zMm - centerMm(2)) ./ geometryMm(2)).^2 <= 1;
        case 'rectangle'
            mask = abs(xMm - centerMm(1)) <= geometryMm(1) / 2 & abs(zMm - centerMm(2)) <= geometryMm(2) / 2;
        case 'irregular'
            perturbation = min(max(geometryMm(2), 0), 0.30);
            theta = atan2(zMm - centerMm(2), xMm - centerMm(1));
            boundary = geometryMm(1) .* (1 + perturbation .* (0.65 .* cos(3 .* theta) + 0.35 .* sin(5 .* theta))); % Perturbación angular controlada del radio.
            mask = hypot(xMm - centerMm(1), zMm - centerMm(2)) <= boundary;
        otherwise
            error('Forma de inclusión no reconocida: %s', shape);
    end
end

%% GUI case metadata (read by App_v5; ignored by MATLAB execution)
% QUS_GUI_CASE_METADATA_VERSION 2
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":true,"nRefs":1,"refSeedBase":50000,"c0":1540,"rho0":1060,"hom_alpha":0.7,"density_std":0.04,"simuName":"paper_s1_s8","source_f0":6.66E+6,"source_amp":1.0E+6,"source_cycles":3.5,"source_focus":0.02,"element_pitch":0.0003,"element_width":0.00025,"focal_number_Tx":2,"focal_number_Rx":2,"nLines":91,"grid_size_x":0.0405,"grid_size_y":0.04,"base_translation":[-0.020232732732732735,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":6,"depth":0.04,"cfl":0.3,"PMLSize":[41,41],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":true,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":128,"rngSeed":23,"mediumModel":"Homogeneo","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Focused","inclusionShape":["circle"],"inclusionCenterMm":[0,20],"inclusionGeometryMm":[7,0],"inclusionAlpha":1,"inclusionSoundSpeed":1540,"inclusionDensity":1060,"inclusionDensityStd":0.04,"layerThicknessMm":[27.5,27.5],"layerAlpha":[0.5,1],"layerSoundSpeed":[1540,1540],"layerDensity":[1060,1060],"layerDensityStd":[0.04,0.04]}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":2,"refSeedBase":50000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.04,"simuName":"paper_S1_layers_equal_bs","source_f0":6.66E+6,"source_amp":1.0E+6,"source_cycles":3.5,"source_focus":0.02,"element_pitch":0.0003,"element_width":0.00025,"focal_number_Tx":2,"focal_number_Rx":2,"nLines":91,"grid_size_x":0.0405,"grid_size_y":0.04,"base_translation":[-0.020232732732732735,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":6,"depth":0.04,"cfl":0.3,"PMLSize":[41,41],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":true,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":128,"rngSeed":23,"mediumModel":"Medio por capas","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Focused","inclusionShape":["circle"],"inclusionCenterMm":[0,20],"inclusionGeometryMm":[7,0],"inclusionAlpha":1,"inclusionSoundSpeed":1540,"inclusionDensity":1060,"inclusionDensityStd":0.04,"layerThicknessMm":[20,20],"layerAlpha":[0.5,1],"layerSoundSpeed":[1540,1540],"layerDensity":[1060,1060],"layerDensityStd":[0.04,0.04]}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":2,"refSeedBase":50000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.04,"simuName":"paper_S2_layers_plus12dB_bs","source_f0":6.66E+6,"source_amp":1.0E+6,"source_cycles":3.5,"source_focus":0.02,"element_pitch":0.0003,"element_width":0.00025,"focal_number_Tx":2,"focal_number_Rx":2,"nLines":91,"grid_size_x":0.0405,"grid_size_y":0.04,"base_translation":[-0.020232732732732735,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":6,"depth":0.04,"cfl":0.3,"PMLSize":[41,41],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":true,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":128,"rngSeed":23,"mediumModel":"Medio por capas","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Focused","inclusionShape":["circle"],"inclusionCenterMm":[0,20],"inclusionGeometryMm":[7,0],"inclusionAlpha":1,"inclusionSoundSpeed":1540,"inclusionDensity":1060,"inclusionDensityStd":0.04,"layerThicknessMm":[20,20],"layerAlpha":[0.5,1],"layerSoundSpeed":[1540,1540],"layerDensity":[1060,1060],"layerDensityStd":[0.04,0.15924286822139888]}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":2,"refSeedBase":50000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.04,"simuName":"paper_S3_layers_minus12dB_bs","source_f0":6.66E+6,"source_amp":1.0E+6,"source_cycles":3.5,"source_focus":0.02,"element_pitch":0.0003,"element_width":0.00025,"focal_number_Tx":2,"focal_number_Rx":2,"nLines":91,"grid_size_x":0.0405,"grid_size_y":0.04,"base_translation":[-0.020232732732732735,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":6,"depth":0.04,"cfl":0.3,"PMLSize":[41,41],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":true,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":128,"rngSeed":23,"mediumModel":"Medio por capas","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Focused","inclusionShape":["circle"],"inclusionCenterMm":[0,20],"inclusionGeometryMm":[7,0],"inclusionAlpha":1,"inclusionSoundSpeed":1540,"inclusionDensity":1060,"inclusionDensityStd":0.04,"layerThicknessMm":[20,20],"layerAlpha":[0.5,1],"layerSoundSpeed":[1540,1540],"layerDensity":[1060,1060],"layerDensityStd":[0.04,0.010047545726038321]}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":2,"refSeedBase":50000,"c0":1540,"rho0":1060,"hom_alpha":0.75,"density_std":0.04,"simuName":"paper_S4_homogeneous_acs_plus12dB_bs","source_f0":6.66E+6,"source_amp":1.0E+6,"source_cycles":3.5,"source_focus":0.02,"element_pitch":0.0003,"element_width":0.00025,"focal_number_Tx":2,"focal_number_Rx":2,"nLines":91,"grid_size_x":0.0405,"grid_size_y":0.04,"base_translation":[-0.020232732732732735,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":6,"depth":0.04,"cfl":0.3,"PMLSize":[41,41],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":true,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":128,"rngSeed":23,"mediumModel":"Medio por capas","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Focused","inclusionShape":["circle"],"inclusionCenterMm":[0,20],"inclusionGeometryMm":[7,0],"inclusionAlpha":1,"inclusionSoundSpeed":1540,"inclusionDensity":1060,"inclusionDensityStd":0.04,"layerThicknessMm":[20,20],"layerAlpha":[0.75,0.75],"layerSoundSpeed":[1540,1540],"layerDensity":[1060,1060],"layerDensityStd":[0.04,0.15924286822139888]}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":2,"refSeedBase":50000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.04,"simuName":"paper_S5_inclusion_equal_bs","source_f0":6.66E+6,"source_amp":1.0E+6,"source_cycles":3.5,"source_focus":0.02,"element_pitch":0.0003,"element_width":0.00025,"focal_number_Tx":2,"focal_number_Rx":2,"nLines":91,"grid_size_x":0.0405,"grid_size_y":0.04,"base_translation":[-0.020232732732732735,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":6,"depth":0.04,"cfl":0.3,"PMLSize":[41,41],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":true,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":128,"rngSeed":23,"mediumModel":"Inclusión circular","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Focused","inclusionShape":["circle"],"inclusionCenterMm":[0,20],"inclusionGeometryMm":[7,0],"inclusionAlpha":1,"inclusionSoundSpeed":1540,"inclusionDensity":1060,"inclusionDensityStd":0.04,"layerThicknessMm":[27.5,27.5],"layerAlpha":[0.5,1],"layerSoundSpeed":[1540,1540],"layerDensity":[1060,1060],"layerDensityStd":[0.04,0.04]}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":2,"refSeedBase":50000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.04,"simuName":"paper_S6_inclusion_plus12dB_bs","source_f0":6.66E+6,"source_amp":1.0E+6,"source_cycles":3.5,"source_focus":0.02,"element_pitch":0.0003,"element_width":0.00025,"focal_number_Tx":2,"focal_number_Rx":2,"nLines":91,"grid_size_x":0.0405,"grid_size_y":0.04,"base_translation":[-0.020232732732732735,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":6,"depth":0.04,"cfl":0.3,"PMLSize":[41,41],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":true,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":128,"rngSeed":23,"mediumModel":"Inclusión circular","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Focused","inclusionShape":["circle"],"inclusionCenterMm":[0,20],"inclusionGeometryMm":[7,0],"inclusionAlpha":1,"inclusionSoundSpeed":1540,"inclusionDensity":1060,"inclusionDensityStd":0.15924286822139888,"layerThicknessMm":[27.5,27.5],"layerAlpha":[0.5,1],"layerSoundSpeed":[1540,1540],"layerDensity":[1060,1060],"layerDensityStd":[0.04,0.04]}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":2,"refSeedBase":50000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.04,"simuName":"paper_S7_inclusion_minus12dB_bs","source_f0":6.66E+6,"source_amp":1.0E+6,"source_cycles":3.5,"source_focus":0.02,"element_pitch":0.0003,"element_width":0.00025,"focal_number_Tx":2,"focal_number_Rx":2,"nLines":91,"grid_size_x":0.0405,"grid_size_y":0.04,"base_translation":[-0.020232732732732735,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":6,"depth":0.04,"cfl":0.3,"PMLSize":[41,41],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":true,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":128,"rngSeed":23,"mediumModel":"Inclusión circular","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Focused","inclusionShape":["circle"],"inclusionCenterMm":[0,20],"inclusionGeometryMm":[7,0],"inclusionAlpha":1,"inclusionSoundSpeed":1540,"inclusionDensity":1060,"inclusionDensityStd":0.010047545726038321,"layerThicknessMm":[27.5,27.5],"layerAlpha":[0.5,1],"layerSoundSpeed":[1540,1540],"layerDensity":[1060,1060],"layerDensityStd":[0.04,0.04]}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":2,"refSeedBase":50000,"c0":1540,"rho0":1060,"hom_alpha":1,"density_std":0.04,"simuName":"paper_S8_multiple_inclusions","source_f0":6.66E+6,"source_amp":1.0E+6,"source_cycles":3.5,"source_focus":0.02,"element_pitch":0.0003,"element_width":0.00025,"focal_number_Tx":2,"focal_number_Rx":2,"nLines":91,"grid_size_x":0.0405,"grid_size_y":0.04,"base_translation":[-0.020232732732732735,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":6,"depth":0.04,"cfl":0.3,"PMLSize":[41,41],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":true,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":128,"rngSeed":23,"mediumModel":"Múltiples inclusiones","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Focused","inclusionShape":["circle","circle","circle"],"inclusionCenterMm":[[-7,10],[7,18],[-5,30]],"inclusionGeometryMm":[[4,0],[6,0],[5,0]],"inclusionAlpha":[0.5,0.5,1],"inclusionSoundSpeed":[1540,1540,1540],"inclusionDensity":[1060,1060,1060],"inclusionDensityStd":[0.15924286822139888,0.010047545726038321,0.15924286822139888],"layerThicknessMm":[27.5,27.5],"layerAlpha":[0.5,1],"layerSoundSpeed":[1540,1540],"layerDensity":[1060,1060],"layerDensityStd":[0.04,0.04]}}
