%% Homogeneous reference simulations
clearvars
clc

%parallel.gpu.enableCUDAForwardCompatibility(true)

%% Reproducibility
rng(23)
addpath(genpath(pwd))

%% Output setup
for ii = 1:5
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

    outputFolder = fullfile(pwd, simuName);
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
        fprintf('Running homogeneous reference %d of %d\\n', iRef, nRefs);
        fprintf('Seed: %d\\n', refSeed);
        fprintf('========================================\\n');

        %% Homogeneous medium

        medium = makeHomogeneousDensityOnlyMedium( ...
            Nx, Ny, c0, rho0, density_std, hom_alpha);

        medium.alpha_power = alpha_power;
        medium.alpha_mode = alpha_mode;
        medium.sound_speed_ref = sound_speed_ref;

        %% Medium properties
        % Same sound-speed, density and absorption preview as the baseline.
        if saveMediumPreviews
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

            fprintf('Reference %d/%d | Line %d/%d\\n', iRef, nRefs, iLine, nLines);

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
            % Store as [time, element, line].
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
        if saveRfPrebeamformed
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

function parameters = getGuiCaseParameters(ii, refValues)
    % Snapshot autónomo de los valores seleccionados en la GUI.
    % No carga MAT: este M se puede enviar solo al cluster.
    switch ii
        case 1
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 10;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1000;
            parameters.hom_alpha = 0.55;
            parameters.density_std = 0.04;
            parameters.simuName = 'homogeneous_target_medium.hom_alpha_0p55__reproducibility.n_refs_target_10__reproducibility.n_refs_reference_5';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.04;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 4;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 128;
            parameters.grid_size_x = 0.056;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.027 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'single';
            parameters.ppw = 6;
            parameters.depth = 0.055;
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
            parameters.solverName = 'kspaceFirstoOrder2D';
        case 2
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 10;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1000;
            parameters.hom_alpha = 0.65;
            parameters.density_std = 0.04;
            parameters.simuName = 'homogeneous_target_medium.hom_alpha_0p65__reproducibility.n_refs_target_10__reproducibility.n_refs_reference_5';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.04;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 4;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 128;
            parameters.grid_size_x = 0.056;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.027 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.055;
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
            parameters.solverName = 'kspaceFirstoOrder2D';
        case 3
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 10;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1000;
            parameters.hom_alpha = 0.8;
            parameters.density_std = 0.04;
            parameters.simuName = 'homogeneous_target_medium.hom_alpha_0p8__reproducibility.n_refs_target_10__reproducibility.n_refs_reference_5';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.04;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 4;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 128;
            parameters.grid_size_x = 0.056;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.027 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.055;
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
            parameters.solverName = 'kspaceFirstoOrder2D';
        case 4
            parameters = struct;
            parameters.isReference = false;
            parameters.nRefs = 10;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1000;
            parameters.hom_alpha = 0.9;
            parameters.density_std = 0.04;
            parameters.simuName = 'homogeneous_target_medium.hom_alpha_0p9__reproducibility.n_refs_target_10__reproducibility.n_refs_reference_5';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.04;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 4;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 128;
            parameters.grid_size_x = 0.056;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.027 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.055;
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
            parameters.solverName = 'kspaceFirstoOrder2D';
        case 5
            parameters = struct;
            parameters.isReference = true;
            parameters.nRefs = 10;
            parameters.refSeedBase = 50000;
            parameters.c0 = 1540;
            parameters.rho0 = 1000;
            parameters.hom_alpha = 0.524;
            parameters.density_std = 0.04;
            parameters.simuName = 'homogeneous_ref';
            parameters.source_f0 = 6660000;
            parameters.source_amp = 1000000;
            parameters.source_cycles = 3.5;
            parameters.source_focus = 0.04;
            parameters.element_pitch = 0.0003;
            parameters.element_width = 0.00025;
            parameters.focal_number_Tx = 4;
            parameters.focal_number_Rx = 2;
            parameters.nLines = 128;
            parameters.grid_size_x = 0.056;
            parameters.grid_size_y = 0.04;
            parameters.base_translation = [-0.027 0];
            parameters.rotation = 0;
            parameters.DATA_CAST = 'gpuArray-single';
            parameters.ppw = 6;
            parameters.depth = 0.055;
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
            parameters.solverName = 'kspaceFirstoOrder2D';
        otherwise
            error('Unknown experiment case: %d', ii);
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
