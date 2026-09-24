classdef MediumConfigurationLogic
    % Configuración única de medios acústicos para la GUI y su preview.
    methods (Static)
        function config = defaultConfig()
            background = MediumConfigurationLogic.region(1595, 1060, 0.50, 0.04);
            inclusion = MediumConfigurationLogic.region(1595, 1060, 1.00, 0.04);
            config = struct( ...
                'kind', 'homogeneous', ...
                'background', background, ...
                'inclusions', MediumConfigurationLogic.defaultInclusion(inclusion), ...
                'layers', MediumConfigurationLogic.defaultLayers(background), ...
                'alpha_power', 1, ...
                'alpha_mode', 'no_dispersion', ...
                'sound_speed_ref', 1540);
        end

        function config = forModel(config, model)
            config.kind = MediumConfigurationLogic.kindFromModel(model);
            if isempty(config.inclusions)
                config.inclusions = MediumConfigurationLogic.defaultInclusion(config.background);
            end
            if isempty(config.layers)
                config.layers = MediumConfigurationLogic.defaultLayers(config.background);
            end
            if strcmp(config.kind, 'single_circle')
                config.inclusions(1).shape = 'circle';
                config.inclusions(1).geometry_mm = [7, 0];
                config.inclusions(1).center_mm = [0, NaN];
            elseif strcmp(config.kind, 'single_shape')
                config.inclusions(1).shape = 'ellipse';
                config.inclusions(1).geometry_mm = [7, 4];
                config.inclusions(1).center_mm = [0, NaN];
            end
        end

        function config = setLayerCount(config, count, axialSizeMm)
            % En la primera etapa de capas no se edita z manualmente: las
            % capas dividen el campo axial en fracciones iguales 1/N.
            count = round(count);
            if ~isscalar(count) || ~isfinite(count) || count < 1 || count > 4
                error('El número de capas debe estar entre 1 y 4.');
            end
            if ~isscalar(axialSizeMm) || ~isfinite(axialSizeMm) || axialSizeMm <= 0
                error('La profundidad debe ser positiva para dividir las capas.');
            end

            previousLayers = config.layers;
            layers = repmat(struct('thickness_mm', axialSizeMm / count, ...
                'acoustic', config.background), 1, count);
            for index = 1:count
                if index <= numel(previousLayers)
                    layers(index).acoustic = previousLayers(index).acoustic;
                end
            end
            config.layers = layers;
        end

        function kind = kindFromModel(model)
            switch char(string(model))
                case 'Homogeneo'
                    kind = 'homogeneous';
                case 'Inclusión circular'
                    kind = 'single_circle';
                case {'Inclusión elipsoidal', 'Inclusión de contorno irregular', 'Inclusión irregular'}
                    kind = 'single_shape';
                case 'Múltiples inclusiones'
                    kind = 'multiple';
                case {'Medio por capas', 'Capas'}
                    kind = 'layers';
                otherwise
                    error('Modelo acústico no reconocido: %s.', char(string(model)));
            end
        end

        function model = modelFromKind(kind)
            switch kind
                case 'homogeneous', model = 'Homogeneo';
                case 'single_circle', model = 'Inclusión circular';
                case 'single_shape', model = 'Inclusión irregular';
                case 'multiple', model = 'Múltiples inclusiones';
                case 'layers', model = 'Medio por capas';
                otherwise, error('Tipo de medio no reconocido.');
            end
        end

        function [soundSpeed, density, acs] = maps(config, axialMm, lateralMm, seed)
            [z, x] = ndgrid(axialMm, lateralMm);
            soundSpeed = config.background.sound_speed * ones(size(z));
            acs = config.background.acs * ones(size(z));
            density = MediumConfigurationLogic.densityMap(config.background, size(z), seed);
            switch config.kind
                case {'single_circle', 'single_shape', 'multiple'}
                    count = 1;
                    if strcmp(config.kind, 'multiple'), count = numel(config.inclusions); end
                    for index = 1:count
                        item = config.inclusions(index);
                        center = item.center_mm;
                        if isnan(center(2)), center(2) = mean(axialMm); end
                        mask = MediumConfigurationLogic.shapeMask(x, z, item, center);
                        acs(mask) = item.acoustic.acs;
                    end
                case 'layers'
                    % Las capas se definen desde la cara del transductor
                    % (z = 0), igual que el pipeline generado. No se
                    % desplazan al borde del grid cuando éste incluye margen.
                    lower = 0;
                    for index = 1:numel(config.layers)
                        layer = config.layers(index);
                        upper = lower + layer.thickness_mm;
                        if index == numel(config.layers), mask = z >= lower; else, mask = z >= lower & z < upper; end
                        acs(mask) = layer.acoustic.acs;
                        lower = upper;
                    end
            end
        end

        function validate(config, axialSizeMm, lateralSizeMm)
            MediumConfigurationLogic.validateRegion(config.background, 'Background');
            if config.alpha_power <= 0 || config.sound_speed_ref <= 0
                error('Alpha power y velocidad de referencia deben ser positivos.');
            end
            switch config.kind
                case {'single_circle', 'single_shape', 'multiple'}
                    items = config.inclusions;
                    if isempty(items), error('Configura al menos una inclusión.'); end
                    masks = cell(1, numel(items));
                    [z, x] = ndgrid(linspace(0, axialSizeMm, 300), ...
                        linspace(-lateralSizeMm / 2, lateralSizeMm / 2, 300));
                    for index = 1:numel(items)
                        MediumConfigurationLogic.validateRegion(items(index).acoustic, ...
                            sprintf('Inclusión %d', index));
                        center = items(index).center_mm;
                        if isnan(center(2)), center(2) = axialSizeMm / 2; end
                        masks{index} = MediumConfigurationLogic.shapeMask(x, z, items(index), center);
                        if ~any(masks{index}(:)) || any(masks{index}([1 end], :), 'all') || ...
                                any(masks{index}(:, [1 end]), 'all')
                            error('La inclusión %d queda parcial o totalmente fuera del grid.', index);
                        end
                        for previous = 1:index - 1
                            if any(masks{index} & masks{previous}, 'all')
                                error('Las inclusiones %d y %d se solapan.', previous, index);
                            end
                        end
                    end
                case 'layers'
                    if isempty(config.layers), error('Configura al menos una capa.'); end
                    total = 0;
                    for index = 1:numel(config.layers)
                        MediumConfigurationLogic.validateRegion(config.layers(index).acoustic, ...
                            sprintf('Capa %d', index));
                        if config.layers(index).thickness_mm <= 0
                            error('Cada capa debe tener espesor positivo.');
                        end
                        total = total + config.layers(index).thickness_mm;
                    end
                    if abs(total - axialSizeMm) > 1e-6
                        error('Los espesores de las capas deben sumar la profundidad (%g mm).', axialSizeMm);
                    end
            end
        end
    end

    methods (Static, Access = private)
        function region = region(soundSpeed, density, acs, densityStd)
            region = struct('sound_speed', soundSpeed, 'density', density, ...
                'acs', acs, 'density_std', densityStd);
        end

        function item = defaultInclusion(background)
            acoustic = background;
            acoustic.acs = 1.00;
            item = struct('shape', 'circle', 'geometry_mm', [7, 0], ...
                'center_mm', [0, NaN], 'acoustic', acoustic);
        end

        function layers = defaultLayers(background)
            top = struct('thickness_mm', 27.5, 'acoustic', background);
            bottomAcoustic = background;
            bottomAcoustic.acs = 1.00;
            bottom = struct('thickness_mm', 27.5, 'acoustic', bottomAcoustic);
            layers = [top, bottom];
        end

        function map = densityMap(region, sizeValue, seed)
            stream = RandStream('mt19937ar', 'Seed', max(0, round(seed)));
            map = region.density * (1 + region.density_std * randn(stream, sizeValue));
        end

        function mask = shapeMask(x, z, item, center)
            x0 = center(1); z0 = center(2); geometry = item.geometry_mm;
            switch item.shape
                case 'circle'
                    mask = (x - x0).^2 + (z - z0).^2 <= geometry(1)^2;
                case 'ellipse'
                    mask = ((x - x0) / geometry(1)).^2 + ((z - z0) / geometry(2)).^2 <= 1;
                case 'rectangle'
                    mask = abs(x - x0) <= geometry(1) / 2 & abs(z - z0) <= geometry(2) / 2;
                case 'square'
                    mask = abs(x - x0) <= geometry(1) / 2 & abs(z - z0) <= geometry(1) / 2;
                case 'irregular'
                    % Contorno suave perturbado: radio medio y fracción de
                    % perturbación. No introduce vértices artificiales.
                    radius = geometry(1);
                    perturbation = geometry(2);
                    if ~isfinite(perturbation), perturbation = 0.15; end
                    perturbation = min(max(perturbation, 0), 0.30);
                    theta = atan2(z - z0, x - x0);
                    boundary = radius .* (1 + perturbation .* ...
                        (0.65 * cos(3 * theta) + 0.35 * sin(5 * theta)));
                    mask = hypot(x - x0, z - z0) <= boundary;
                otherwise
                    error('Forma de inclusión no reconocida.');
            end
        end

        function validateRegion(region, label)
            values = [region.sound_speed, region.density, region.acs, region.density_std];
            if any(~isfinite(values)) || region.sound_speed <= 0 || region.density <= 0 || ...
                    region.acs < 0 || region.density_std < 0
                error('%s contiene propiedades acústicas inválidas.', label);
            end
        end
    end
end
