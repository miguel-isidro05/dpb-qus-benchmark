%% Comparación de modos de transmisión con 64 elementos
clc

scriptFolder = fileparts(mfilename('fullpath'));
if isempty(scriptFolder), scriptFolder = pwd; end
cd(scriptFolder);
%% Reproducibility
rng(23)
addpath(genpath(scriptFolder))

%% Output setup
for ii = 1:8
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

    % Cover the largest electronic-focus delay plus the full imaging depth.
    maximumFocusedDistance = hypot((element_count - 1) * element_pitch, ...
        source_focus);
    maximumFocusedTimeZero = ...
        (maximumFocusedDistance - source_focus) / c0 + ...
        source_cycles / (2 * source_f0);
    t_end = maximumFocusedTimeZero + depth * 2 / c0 + 1 / source_f0;
    kgrid.makeTime(c0, cfl, t_end);

    %% Source / array setup

    if strcmpi(transmit_mode, 'Focused')
        acquisition = makeFocusedAcquisition(source_amp, source_focus, ...
            element_count, element_pitch, element_width, nLines, ...
            base_translation, c0, grid_size_y, simuName);
    elseif strcmpi(transmit_mode, 'Plane Wave')
        acquisition = makePlaneWaveAcquisition(source_amp, steering_angles_deg, ...
            element_count, element_pitch, element_width, base_translation, ...
            c0, grid_size_y, simuName);
    elseif strcmpi(transmit_mode, 'Plane Wave Compounding')
        acquisition = makePlaneWaveCompoundingAcquisition(source_amp, ...
            steering_angles_deg, element_count, element_pitch, element_width, ...
            base_translation, c0, grid_size_y, simuName);
    elseif strcmpi(transmit_mode, 'Synthetic Aperture')
        acquisition = makeSyntheticApertureAcquisition(source_amp, ...
            synthetic_aperture_stride, element_count, element_pitch, ...
            element_width, base_translation, grid_size_y, simuName);
    else
        error('Modo de emisión no reconocido: %s', transmit_mode);
    end
    acquisition_mode = acquisition.mode;
    event_values = acquisition.event_values;
    event_count = numel(event_values);
    element_num = acquisition.element_count;
    ids = acquisition.element_ids;

    % Create empty kWaveArray
    karray = kWaveArray('BLITolerance', 0.05, 'UpsamplingRate', 10);

    % Add rectangular elements
    for ind = 1:element_num
        y_pos = acquisition.element_positions_m(ind);
        karray.addRectElement([0, y_pos], element_width/4, element_width, rotation);
    end

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

        rf_prebf = zeros(kgrid.Nt, acquisition.element_count, event_count);
        tx_delays_s = acquisition.delays_s;

        %% Acquisition event loop

        for iEvent = 1:event_count
            [event_amp, event_delays, translation] = ...
                getAcquisitionEvent(acquisition, iEvent);
            source_sig = event_amp .* toneBurst(1/kgrid.dt, source_f0, ...
                source_cycles, 'SignalOffset', round(event_delays / kgrid.dt));
            karray.setArrayPosition(translation, rotation)

            source.p_mask = karray.getArrayBinaryMask(kgrid);
            source.p = karray.getDistributedSourceSignal(kgrid, source_sig);

            fprintf('Reference %d/%d | Event %d/%d (%s)\n', ...
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
        x = acquisition.x_m;
        tx_event_values = acquisition.event_values;
        tx_event_units = acquisition.event_units;
        active_tx_elements = acquisition.active_tx_elements;
        nEvents = event_count;
        element_count = acquisition.element_count;
        rx_element_count = acquisition.element_count;
        tx_element_positions_m = base_translation(2) + acquisition.element_positions_m;
        rx_element_positions_m = tx_element_positions_m;
        tx_active_mask = acquisition.amplitudes ~= 0;
        tx_apodization = acquisition.amplitudes ./ source_amp;
        scan_line_positions_m = acquisition.x_m;
        pulseDuration = floor(source_cycles / source_f0 * fs) / fs;
        focused_tx_strategy = '';
        if strcmp(acquisition_mode, 'focused_scan')
            focusDistances = hypot( ...
                tx_element_positions_m - scan_line_positions_m(:), ...
                source_focus);
            quantizedTxDelays = round(tx_delays_s / kgrid.dt) * kgrid.dt;
            time_zero_s = median(quantizedTxDelays + ...
                (focusDistances - source_focus) / c0, 'all') ...
                + pulseDuration / 2; % Referencia temporal del foco fijo Tx.
            time_delays = tx_delays_s(1, :); % Compatibilidad con el beamformer focalizado.
            focused_tx_strategy = 'fixed_array_electronic_focus';
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
                'acquisition_mode', 'transmit_mode', 'focused_tx_strategy', ...
                'tx_event_values', 'tx_event_units', ...
                'tx_delays_s', 'tx_active_mask', 'tx_apodization', ...
                'tx_element_positions_m', 'rx_element_positions_m', ...
                'scan_line_positions_m', 'nEvents', 'element_count', 'rx_element_count', ...
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
            parameters.refSeedBase = 41000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.025;
            parameters.simuName = 'transmission_comparison_64el';
            parameters.source_f0 = 2000000;
            parameters.source_amp = 100000;
            parameters.source_cycles = 2;
            parameters.source_focus = 0.006;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00027;
            parameters.focal_number_Tx = 1.5;
            parameters.focal_number_Rx = 1.5;
            parameters.nLines = 64;
            parameters.grid_size_x = 0.014;
            parameters.grid_size_y = 0.024;
            parameters.base_translation = [-0.0068075 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 4;
            parameters.depth = 0.012;
            parameters.cfl = 0.3;
            parameters.PMLSize = [10 10];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = false;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 64;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Homogeneo';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Focused';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 6];
            parameters.inclusionGeometryMm = [2 0];
            parameters.inclusionAlpha = 0.8;
            parameters.inclusionSoundSpeed = 1500;
            parameters.inclusionDensity = 1120;
            parameters.inclusionDensityStd = 0.025;
            parameters.layerThicknessMm = 12;
            parameters.layerAlpha = 0.5;
            parameters.layerSoundSpeed = 1540;
            parameters.layerDensity = 1060;
            parameters.layerDensityStd = 0.025;
        case 2
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 1;
            parameters.refSeedBase = 41000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.025;
            parameters.simuName = 'homogeneous_plane_wave';
            parameters.source_f0 = 2000000;
            parameters.source_amp = 100000;
            parameters.source_cycles = 2;
            parameters.source_focus = 0.006;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00027;
            parameters.focal_number_Tx = 1.5;
            parameters.focal_number_Rx = 1.5;
            parameters.nLines = 64;
            parameters.grid_size_x = 0.014;
            parameters.grid_size_y = 0.024;
            parameters.base_translation = [-0.0068075 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 4;
            parameters.depth = 0.012;
            parameters.cfl = 0.3;
            parameters.PMLSize = [10 10];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = false;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = 0;
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 64;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Homogeneo';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Plane Wave';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 6];
            parameters.inclusionGeometryMm = [2 0];
            parameters.inclusionAlpha = 0.8;
            parameters.inclusionSoundSpeed = 1500;
            parameters.inclusionDensity = 1120;
            parameters.inclusionDensityStd = 0.025;
            parameters.layerThicknessMm = 12;
            parameters.layerAlpha = 0.5;
            parameters.layerSoundSpeed = 1540;
            parameters.layerDensity = 1060;
            parameters.layerDensityStd = 0.025;
        case 3
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 1;
            parameters.refSeedBase = 41000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.025;
            parameters.simuName = 'homogeneous_pwc';
            parameters.source_f0 = 2000000;
            parameters.source_amp = 100000;
            parameters.source_cycles = 2;
            parameters.source_focus = 0.006;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00027;
            parameters.focal_number_Tx = 1.5;
            parameters.focal_number_Rx = 1.5;
            parameters.nLines = 64;
            parameters.grid_size_x = 0.014;
            parameters.grid_size_y = 0.024;
            parameters.base_translation = [-0.0068075 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 4;
            parameters.depth = 0.012;
            parameters.cfl = 0.3;
            parameters.PMLSize = [10 10];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = false;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 64;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Homogeneo';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Plane Wave Compounding';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 6];
            parameters.inclusionGeometryMm = [2 0];
            parameters.inclusionAlpha = 0.8;
            parameters.inclusionSoundSpeed = 1500;
            parameters.inclusionDensity = 1120;
            parameters.inclusionDensityStd = 0.025;
            parameters.layerThicknessMm = 12;
            parameters.layerAlpha = 0.5;
            parameters.layerSoundSpeed = 1540;
            parameters.layerDensity = 1060;
            parameters.layerDensityStd = 0.025;
        case 4
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 1;
            parameters.refSeedBase = 41000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.025;
            parameters.simuName = 'homogeneous_sta';
            parameters.source_f0 = 2000000;
            parameters.source_amp = 100000;
            parameters.source_cycles = 2;
            parameters.source_focus = 0.006;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00027;
            parameters.focal_number_Tx = 1.5;
            parameters.focal_number_Rx = 1.5;
            parameters.nLines = 64;
            parameters.grid_size_x = 0.014;
            parameters.grid_size_y = 0.024;
            parameters.base_translation = [-0.0068075 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 4;
            parameters.depth = 0.012;
            parameters.cfl = 0.3;
            parameters.PMLSize = [10 10];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = false;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 64;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Homogeneo';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Synthetic Aperture';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 6];
            parameters.inclusionGeometryMm = [2 0];
            parameters.inclusionAlpha = 0.8;
            parameters.inclusionSoundSpeed = 1500;
            parameters.inclusionDensity = 1120;
            parameters.inclusionDensityStd = 0.025;
            parameters.layerThicknessMm = 12;
            parameters.layerAlpha = 0.5;
            parameters.layerSoundSpeed = 1540;
            parameters.layerDensity = 1060;
            parameters.layerDensityStd = 0.025;
        case 5
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 1;
            parameters.refSeedBase = 41000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.025;
            parameters.simuName = 'central_inclusion_focused';
            parameters.source_f0 = 2000000;
            parameters.source_amp = 100000;
            parameters.source_cycles = 2;
            parameters.source_focus = 0.006;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00027;
            parameters.focal_number_Tx = 1.5;
            parameters.focal_number_Rx = 1.5;
            parameters.nLines = 64;
            parameters.grid_size_x = 0.014;
            parameters.grid_size_y = 0.024;
            parameters.base_translation = [-0.0068075 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 4;
            parameters.depth = 0.012;
            parameters.cfl = 0.3;
            parameters.PMLSize = [10 10];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = false;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 64;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Inclusión circular';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Focused';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 6];
            parameters.inclusionGeometryMm = [2 0];
            parameters.inclusionAlpha = 0.8;
            parameters.inclusionSoundSpeed = 1500;
            parameters.inclusionDensity = 1120;
            parameters.inclusionDensityStd = 0.025;
            parameters.layerThicknessMm = 12;
            parameters.layerAlpha = 0.5;
            parameters.layerSoundSpeed = 1540;
            parameters.layerDensity = 1060;
            parameters.layerDensityStd = 0.025;
        case 6
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 1;
            parameters.refSeedBase = 41000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.025;
            parameters.simuName = 'central_inclusion_plane_wave';
            parameters.source_f0 = 2000000;
            parameters.source_amp = 100000;
            parameters.source_cycles = 2;
            parameters.source_focus = 0.006;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00027;
            parameters.focal_number_Tx = 1.5;
            parameters.focal_number_Rx = 1.5;
            parameters.nLines = 64;
            parameters.grid_size_x = 0.014;
            parameters.grid_size_y = 0.024;
            parameters.base_translation = [-0.0068075 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 4;
            parameters.depth = 0.012;
            parameters.cfl = 0.3;
            parameters.PMLSize = [10 10];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = false;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = 0;
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 64;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Inclusión circular';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Plane Wave';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 6];
            parameters.inclusionGeometryMm = [2 0];
            parameters.inclusionAlpha = 0.8;
            parameters.inclusionSoundSpeed = 1500;
            parameters.inclusionDensity = 1120;
            parameters.inclusionDensityStd = 0.025;
            parameters.layerThicknessMm = 12;
            parameters.layerAlpha = 0.5;
            parameters.layerSoundSpeed = 1540;
            parameters.layerDensity = 1060;
            parameters.layerDensityStd = 0.025;
        case 7
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 1;
            parameters.refSeedBase = 41000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.025;
            parameters.simuName = 'central_inclusion_pwc';
            parameters.source_f0 = 2000000;
            parameters.source_amp = 100000;
            parameters.source_cycles = 2;
            parameters.source_focus = 0.006;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00027;
            parameters.focal_number_Tx = 1.5;
            parameters.focal_number_Rx = 1.5;
            parameters.nLines = 64;
            parameters.grid_size_x = 0.014;
            parameters.grid_size_y = 0.024;
            parameters.base_translation = [-0.0068075 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 4;
            parameters.depth = 0.012;
            parameters.cfl = 0.3;
            parameters.PMLSize = [10 10];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = false;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 64;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Inclusión circular';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Plane Wave Compounding';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 6];
            parameters.inclusionGeometryMm = [2 0];
            parameters.inclusionAlpha = 0.8;
            parameters.inclusionSoundSpeed = 1500;
            parameters.inclusionDensity = 1120;
            parameters.inclusionDensityStd = 0.025;
            parameters.layerThicknessMm = 12;
            parameters.layerAlpha = 0.5;
            parameters.layerSoundSpeed = 1540;
            parameters.layerDensity = 1060;
            parameters.layerDensityStd = 0.025;
        case 8
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 1;
            parameters.refSeedBase = 41000;
            parameters.c0 = 1540;
            parameters.rho0 = 1060;
            parameters.hom_alpha = 0.5;
            parameters.density_std = 0.025;
            parameters.simuName = 'central_inclusion_sta';
            parameters.source_f0 = 2000000;
            parameters.source_amp = 100000;
            parameters.source_cycles = 2;
            parameters.source_focus = 0.006;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00027;
            parameters.focal_number_Tx = 1.5;
            parameters.focal_number_Rx = 1.5;
            parameters.nLines = 64;
            parameters.grid_size_x = 0.014;
            parameters.grid_size_y = 0.024;
            parameters.base_translation = [-0.0068075 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 4;
            parameters.depth = 0.012;
            parameters.cfl = 0.3;
            parameters.PMLSize = [10 10];
            parameters.plotSimFlag = false;
            parameters.alpha_power = 1;
            parameters.alpha_mode = 'no_dispersion';
            parameters.sound_speed_ref = 1540;
            parameters.saveMediumPreviews = false;
            parameters.saveRfPrebeamformed = true;
            parameters.directivity_size_factor = 10;
            parameters.directivity_angle = 0;
            parameters.solverName = 'kspaceFirstOrder2D';
            parameters.steeringAnglesDeg = [-10 0 10];
            parameters.syntheticApertureStride = 1;
            parameters.elementCount = 64;
            parameters.rngSeed = 23;
            parameters.mediumModel = 'Inclusión circular';
            parameters.transducerType = 'Lineal Plano';
            parameters.transducerSignal = 'Tone Burst';
            parameters.transducerBeamMode = 'Synthetic Aperture';
            parameters.inclusionShape = {'circle'};
            parameters.inclusionCenterMm = [0 6];
            parameters.inclusionGeometryMm = [2 0];
            parameters.inclusionAlpha = 0.8;
            parameters.inclusionSoundSpeed = 1500;
            parameters.inclusionDensity = 1120;
            parameters.inclusionDensityStd = 0.025;
            parameters.layerThicknessMm = 12;
            parameters.layerAlpha = 0.5;
            parameters.layerSoundSpeed = 1540;
            parameters.layerDensity = 1060;
            parameters.layerDensityStd = 0.025;
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

% assertArrayCoverage valida el arreglo fijo usado por PWC y apertura sintética.
function assertArrayCoverage(gridSizeY, elementCount, pitch, elementWidth, lateralTranslation, caseName)
    arrayWidth = (elementCount - 1) * pitch + elementWidth;
    requiredWidth = 2 * abs(lateralTranslation) + arrayWidth;
    if elementCount < 1 || gridSizeY + eps(max(gridSizeY, requiredWidth)) < requiredWidth
        error('%s: la malla lateral debe medir al menos %.3f mm para contener el arreglo fijo.', ...
            caseName, 1e3 * requiredWidth);
    end
end

% makeFocusedAcquisition usa los 64 elementos fijos y enfoca cada línea con retardos.
function acquisition = makeFocusedAcquisition(sourceAmp, sourceFocus, elementCount, pitch, elementWidth, nLines, baseTranslation, c0, gridSizeY, caseName)
    if elementCount < 1 || elementCount ~= round(elementCount) || ...
            nLines < 1 || nLines ~= round(nLines)
        error('%s: el número de elementos y de líneas debe ser entero positivo.', caseName);
    end
    assertArrayCoverage(gridSizeY, elementCount, pitch, elementWidth, ...
        baseTranslation(2), caseName);
    ids = (0:elementCount-1) - (elementCount-1)/2;
    offsets = ((0:nLines-1) - (nLines-1)/2) * pitch;
    linePositions = baseTranslation(2) + offsets;
    elementPositions = baseTranslation(2) + ids .* pitch;
    focusDistances = hypot(elementPositions - linePositions(:), sourceFocus);
    delays = (max(focusDistances, [], 'all') - focusDistances) ./ c0;
    amplitudes = sourceAmp * ones(nLines, elementCount);
    translations = repmat(baseTranslation, nLines, 1);
    acquisition = acquisitionStruct('focused_scan', linePositions, 'm', ids, pitch, ...
        amplitudes, delays, translations, linePositions, elementCount);
end

% makePlaneWaveAcquisition define una sola emisión de onda plana.
function acquisition = makePlaneWaveAcquisition(sourceAmp, angleDeg, elementCount, pitch, elementWidth, baseTranslation, c0, gridSizeY, caseName)
    if numel(angleDeg) ~= 1 || ~isfinite(angleDeg) || abs(angleDeg) >= 90
        error('%s: Plane Wave requiere un ángulo finito entre -90 y 90 grados.', caseName);
    end
    acquisition = makePlaneWaveEvents(sourceAmp, angleDeg, elementCount, pitch, ...
        elementWidth, baseTranslation, c0, gridSizeY, caseName, 'plane_wave');
end

% makePlaneWaveCompoundingAcquisition define un evento por ángulo de compounding.
function acquisition = makePlaneWaveCompoundingAcquisition(sourceAmp, anglesDeg, elementCount, pitch, elementWidth, baseTranslation, c0, gridSizeY, caseName)
    if numel(anglesDeg) < 2 || any(~isfinite(anglesDeg)) || any(abs(anglesDeg) >= 90)
        error('%s: PWC requiere al menos dos ángulos finitos entre -90 y 90 grados.', caseName);
    end
    acquisition = makePlaneWaveEvents(sourceAmp, anglesDeg, elementCount, pitch, ...
        elementWidth, baseTranslation, c0, gridSizeY, caseName, ...
        'plane_wave_compounding');
end

% makePlaneWaveEvents calcula retardos angulares para PW y PWC.
function acquisition = makePlaneWaveEvents(sourceAmp, anglesDeg, elementCount, pitch, elementWidth, baseTranslation, c0, gridSizeY, caseName, mode)
    if elementCount < 1 || elementCount ~= round(elementCount)
        error('%s: el número de elementos debe ser un entero positivo.', caseName);
    end
    assertArrayCoverage(gridSizeY, elementCount, pitch, elementWidth, ...
        baseTranslation(2), caseName);
    ids = (0:elementCount-1) - (elementCount-1)/2;
    anglesDeg = anglesDeg(:).';
    eventCount = numel(anglesDeg);
    delays = zeros(eventCount, elementCount);
    for eventIndex = 1:eventCount
        delays(eventIndex, :) = ids .* pitch .* sind(anglesDeg(eventIndex)) ./ c0;
        delays(eventIndex, :) = delays(eventIndex, :) - min(delays(eventIndex, :));
    end
    amplitudes = sourceAmp * ones(eventCount, elementCount);
    translations = repmat(baseTranslation, eventCount, 1);
    acquisition = acquisitionStruct(mode, anglesDeg, 'deg', ids, pitch, ...
        amplitudes, delays, translations, [], elementCount);
end

% makeSyntheticApertureAcquisition define un emisor Tx por evento y recepción completa.
function acquisition = makeSyntheticApertureAcquisition(sourceAmp, stride, elementCount, pitch, elementWidth, baseTranslation, gridSizeY, caseName)
    if stride < 1 || stride ~= round(stride) || elementCount < 1 || elementCount ~= round(elementCount)
        error('%s: STA requiere un paso y un número de elementos enteros positivos.', caseName);
    end
    assertArrayCoverage(gridSizeY, elementCount, pitch, elementWidth, ...
        baseTranslation(2), caseName);
    ids = (0:elementCount-1) - (elementCount-1)/2;
    eventValues = 1:stride:elementCount;
    eventCount = numel(eventValues);
    amplitudes = zeros(eventCount, elementCount);
    for eventIndex = 1:eventCount
        amplitudes(eventIndex, eventValues(eventIndex)) = sourceAmp;
    end
    delays = zeros(eventCount, elementCount);
    translations = repmat(baseTranslation, eventCount, 1);
    xPositions = baseTranslation(2) + ids(eventValues) * pitch;
    acquisition = acquisitionStruct('synthetic_aperture', eventValues, ...
        'element_index', ids, pitch, amplitudes, delays, translations, ...
        xPositions, 1);
end

% acquisitionStruct normaliza el contrato compartido por todos los modos.
function acquisition = acquisitionStruct(mode, eventValues, eventUnits, ids, pitch, amplitudes, delays, translations, xPositions, activeTxElements)
    expectedSize = [numel(eventValues), numel(ids)];
    if ~isequal(size(amplitudes), expectedSize) || ~isequal(size(delays), expectedSize) || ...
            ~isequal(size(translations), [numel(eventValues), 2])
        error('Las matrices de adquisición no coinciden con eventos y elementos.');
    end
    acquisition = struct('mode', mode, 'event_values', eventValues, ...
        'event_units', eventUnits, 'element_count', numel(ids), ...
        'element_ids', ids, 'element_positions_m', ids .* pitch, ...
        'amplitudes', amplitudes, 'delays_s', delays, ...
        'translations_m', translations, 'x_m', xPositions, ...
        'active_tx_elements', activeTxElements);
end

% getAcquisitionEvent entrega al solver un evento ya calculado y verificable.
function [amplitude, delays, translation] = getAcquisitionEvent(acquisition, eventIndex)
    amplitude = acquisition.amplitudes(eventIndex, :).';
    delays = acquisition.delays_s(eventIndex, :);
    translation = acquisition.translations_m(eventIndex, :);
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
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":true,"nRefs":1,"refSeedBase":41000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.025,"simuName":"transmission_comparison_64el","source_f0":2.0E+6,"source_amp":100000,"source_cycles":2,"source_focus":0.006,"element_pitch":0.0003,"element_width":0.00027,"focal_number_Tx":1.5,"focal_number_Rx":1.5,"nLines":64,"grid_size_x":0.014,"grid_size_y":0.024,"base_translation":[-0.0068075,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":4,"depth":0.012,"cfl":0.3,"PMLSize":[10,10],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":false,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":64,"rngSeed":23,"mediumModel":"Homogeneo","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Focused","inclusionShape":["circle"],"inclusionCenterMm":[0,6],"inclusionGeometryMm":[2,0],"inclusionAlpha":0.8,"inclusionSoundSpeed":1500,"inclusionDensity":1120,"inclusionDensityStd":0.025,"layerThicknessMm":12,"layerAlpha":0.5,"layerSoundSpeed":1540,"layerDensity":1060,"layerDensityStd":0.025}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":1,"refSeedBase":41000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.025,"simuName":"homogeneous_plane_wave","source_f0":2.0E+6,"source_amp":100000,"source_cycles":2,"source_focus":0.006,"element_pitch":0.0003,"element_width":0.00027,"focal_number_Tx":1.5,"focal_number_Rx":1.5,"nLines":64,"grid_size_x":0.014,"grid_size_y":0.024,"base_translation":[-0.0068075,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":4,"depth":0.012,"cfl":0.3,"PMLSize":[10,10],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":false,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":0,"syntheticApertureStride":1,"elementCount":64,"rngSeed":23,"mediumModel":"Homogeneo","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Plane Wave","inclusionShape":["circle"],"inclusionCenterMm":[0,6],"inclusionGeometryMm":[2,0],"inclusionAlpha":0.8,"inclusionSoundSpeed":1500,"inclusionDensity":1120,"inclusionDensityStd":0.025,"layerThicknessMm":12,"layerAlpha":0.5,"layerSoundSpeed":1540,"layerDensity":1060,"layerDensityStd":0.025}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":1,"refSeedBase":41000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.025,"simuName":"homogeneous_pwc","source_f0":2.0E+6,"source_amp":100000,"source_cycles":2,"source_focus":0.006,"element_pitch":0.0003,"element_width":0.00027,"focal_number_Tx":1.5,"focal_number_Rx":1.5,"nLines":64,"grid_size_x":0.014,"grid_size_y":0.024,"base_translation":[-0.0068075,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":4,"depth":0.012,"cfl":0.3,"PMLSize":[10,10],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":false,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":64,"rngSeed":23,"mediumModel":"Homogeneo","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Plane Wave Compounding","inclusionShape":["circle"],"inclusionCenterMm":[0,6],"inclusionGeometryMm":[2,0],"inclusionAlpha":0.8,"inclusionSoundSpeed":1500,"inclusionDensity":1120,"inclusionDensityStd":0.025,"layerThicknessMm":12,"layerAlpha":0.5,"layerSoundSpeed":1540,"layerDensity":1060,"layerDensityStd":0.025}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":1,"refSeedBase":41000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.025,"simuName":"homogeneous_sta","source_f0":2.0E+6,"source_amp":100000,"source_cycles":2,"source_focus":0.006,"element_pitch":0.0003,"element_width":0.00027,"focal_number_Tx":1.5,"focal_number_Rx":1.5,"nLines":64,"grid_size_x":0.014,"grid_size_y":0.024,"base_translation":[-0.0068075,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":4,"depth":0.012,"cfl":0.3,"PMLSize":[10,10],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":false,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":64,"rngSeed":23,"mediumModel":"Homogeneo","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Synthetic Aperture","inclusionShape":["circle"],"inclusionCenterMm":[0,6],"inclusionGeometryMm":[2,0],"inclusionAlpha":0.8,"inclusionSoundSpeed":1500,"inclusionDensity":1120,"inclusionDensityStd":0.025,"layerThicknessMm":12,"layerAlpha":0.5,"layerSoundSpeed":1540,"layerDensity":1060,"layerDensityStd":0.025}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":1,"refSeedBase":41000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.025,"simuName":"central_inclusion_focused","source_f0":2.0E+6,"source_amp":100000,"source_cycles":2,"source_focus":0.006,"element_pitch":0.0003,"element_width":0.00027,"focal_number_Tx":1.5,"focal_number_Rx":1.5,"nLines":64,"grid_size_x":0.014,"grid_size_y":0.024,"base_translation":[-0.0068075,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":4,"depth":0.012,"cfl":0.3,"PMLSize":[10,10],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":false,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":64,"rngSeed":23,"mediumModel":"Inclusión circular","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Focused","inclusionShape":["circle"],"inclusionCenterMm":[0,6],"inclusionGeometryMm":[2,0],"inclusionAlpha":0.8,"inclusionSoundSpeed":1500,"inclusionDensity":1120,"inclusionDensityStd":0.025,"layerThicknessMm":12,"layerAlpha":0.5,"layerSoundSpeed":1540,"layerDensity":1060,"layerDensityStd":0.025}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":1,"refSeedBase":41000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.025,"simuName":"central_inclusion_plane_wave","source_f0":2.0E+6,"source_amp":100000,"source_cycles":2,"source_focus":0.006,"element_pitch":0.0003,"element_width":0.00027,"focal_number_Tx":1.5,"focal_number_Rx":1.5,"nLines":64,"grid_size_x":0.014,"grid_size_y":0.024,"base_translation":[-0.0068075,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":4,"depth":0.012,"cfl":0.3,"PMLSize":[10,10],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":false,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":0,"syntheticApertureStride":1,"elementCount":64,"rngSeed":23,"mediumModel":"Inclusión circular","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Plane Wave","inclusionShape":["circle"],"inclusionCenterMm":[0,6],"inclusionGeometryMm":[2,0],"inclusionAlpha":0.8,"inclusionSoundSpeed":1500,"inclusionDensity":1120,"inclusionDensityStd":0.025,"layerThicknessMm":12,"layerAlpha":0.5,"layerSoundSpeed":1540,"layerDensity":1060,"layerDensityStd":0.025}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":1,"refSeedBase":41000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.025,"simuName":"central_inclusion_pwc","source_f0":2.0E+6,"source_amp":100000,"source_cycles":2,"source_focus":0.006,"element_pitch":0.0003,"element_width":0.00027,"focal_number_Tx":1.5,"focal_number_Rx":1.5,"nLines":64,"grid_size_x":0.014,"grid_size_y":0.024,"base_translation":[-0.0068075,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":4,"depth":0.012,"cfl":0.3,"PMLSize":[10,10],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":false,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":64,"rngSeed":23,"mediumModel":"Inclusión circular","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Plane Wave Compounding","inclusionShape":["circle"],"inclusionCenterMm":[0,6],"inclusionGeometryMm":[2,0],"inclusionAlpha":0.8,"inclusionSoundSpeed":1500,"inclusionDensity":1120,"inclusionDensityStd":0.025,"layerThicknessMm":12,"layerAlpha":0.5,"layerSoundSpeed":1540,"layerDensity":1060,"layerDensityStd":0.025}}
% QUS_GUI_CASE_JSON {"schema_version":2,"case":{"isReference":false,"nRefs":1,"refSeedBase":41000,"c0":1540,"rho0":1060,"hom_alpha":0.5,"density_std":0.025,"simuName":"central_inclusion_sta","source_f0":2.0E+6,"source_amp":100000,"source_cycles":2,"source_focus":0.006,"element_pitch":0.0003,"element_width":0.00027,"focal_number_Tx":1.5,"focal_number_Rx":1.5,"nLines":64,"grid_size_x":0.014,"grid_size_y":0.024,"base_translation":[-0.0068075,0],"rotation":0,"DATA_CAST":"gpuArray-single","ppw":4,"depth":0.012,"cfl":0.3,"PMLSize":[10,10],"plotSimFlag":false,"alpha_power":1,"alpha_mode":"no_dispersion","sound_speed_ref":1540,"saveMediumPreviews":false,"saveRfPrebeamformed":true,"directivity_size_factor":10,"directivity_angle":0,"solverName":"kspaceFirstOrder2D","steeringAnglesDeg":[-10,0,10],"syntheticApertureStride":1,"elementCount":64,"rngSeed":23,"mediumModel":"Inclusión circular","transducerType":"Lineal Plano","transducerSignal":"Tone Burst","transducerBeamMode":"Synthetic Aperture","inclusionShape":["circle"],"inclusionCenterMm":[0,6],"inclusionGeometryMm":[2,0],"inclusionAlpha":0.8,"inclusionSoundSpeed":1500,"inclusionDensity":1120,"inclusionDensityStd":0.025,"layerThicknessMm":12,"layerAlpha":0.5,"layerSoundSpeed":1540,"layerDensity":1060,"layerDensityStd":0.025}}
