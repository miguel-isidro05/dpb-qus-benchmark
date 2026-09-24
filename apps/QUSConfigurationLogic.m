classdef QUSConfigurationLogic
    % Gestiona la configuración reproducible compartida por las apps.
    % Prepara y guarda los datos, pero no ejecuta k-Wave.
    
    %Estas son solo llamadas a acciones de botones o menus.
    methods (Static)
        function parametersByCase = readPipelineConfiguration(pipelinePath)
            % Lector público usado por Open Config y por herramientas de
            % inspección. Conserva un único contrato para los metadatos de
            % pipelines generados por la GUI.
            parametersByCase = QUSConfigurationLogic.readPipelineCases(pipelinePath);
            parametersByCase = QUSConfigurationLogic.referenceFirst(parametersByCase);
        end

        function onSet(app)
            state = QUSConfigurationLogic.prepare(app);

            try
                current = QUSConfigurationLogic.readCurrentConfiguration(app, state.advanced);
                QUSConfigurationLogic.validateConfiguration(current);
            catch exception
                QUSConfigurationLogic.showError(app, exception.message);
                return
            end

            if ~state.referenceDefined
                state.reference = current;
                state.referenceDefined = true;
            else
                changes = QUSConfigurationLogic.detectChanges(state.reference, current);
                for index = 1:numel(changes)
                    state.queue = QUSConfigurationLogic.addChange(state.queue, changes(index));
                end
                % El nombre identifica la salida, no una nueva referencia.
                % Reset es la única acción que vacía la cola.
                state.reference.experiment.name = current.experiment.name;
            end

            state.advanced.reproducibility = current.reproducibility;
            state = QUSConfigurationLogic.recordPreviewCase(app, state, current);
            QUSConfigurationLogic.storeState(app, state);
            QUSConfigurationLogic.configureDeleteButton(app, state);
            QUSConfigurationLogic.updateExecution(app, state);
            QUSConfigurationLogic.updateStatusSummary(app, state, '');
            QUSConfigurationLogic.refreshAssociatedViews(app);
        end

        function onTest(app)
            state = QUSConfigurationLogic.prepare(app);
            QUSConfigurationLogic.updateExecution(app, state);
            QUSConfigurationLogic.updateStatusSummary(app, state, '');
        end

        function onDeleteSelectedCase(app)
            state = QUSConfigurationLogic.prepare(app);
            caseIndex = QUSConfigurationLogic.groupIndex(app.DropDown.Value);
            if caseIndex <= 1
                QUSConfigurationLogic.showError(app, ...
                    'Ref define la base de todos los casos. Para eliminarla usa Reset.');
                return
            end
            deletedLabel = QUSConfigurationLogic.caseLabel(caseIndex);
            if ~isempty(state.previewCases)
                if caseIndex > numel(state.previewCases)
                    QUSConfigurationLogic.showError(app, 'El caso seleccionado no existe.');
                    return
                end
                state.previewCases(caseIndex) = [];
                state.queue = QUSConfigurationLogic.rebuildQueueFromPreviewCases(state);
                selectedIndex = min(caseIndex, numel(state.previewCases));
                selectedConfiguration = state.previewCases(selectedIndex).configuration;
                state.advanced = QUSConfigurationLogic.advancedFromReference(selectedConfiguration);
                QUSConfigurationLogic.applyConfiguration(app, selectedConfiguration);
                QUSConfigurationLogic.configureGroupSelector(app, ...
                    numel(state.previewCases), selectedIndex);
            elseif ~isempty(state.pipelineCases)
                if caseIndex > numel(state.pipelineCases)
                    QUSConfigurationLogic.showError(app, 'El caso seleccionado no existe.');
                    return
                end
                state.pipelineCases(caseIndex) = [];
                selectedIndex = min(caseIndex, numel(state.pipelineCases));
                state = QUSConfigurationLogic.applyPipelineCase(app, state, selectedIndex);
                QUSConfigurationLogic.configureGroupSelector(app, ...
                    numel(state.pipelineCases), selectedIndex);
            else
                QUSConfigurationLogic.showError(app, 'No hay un Case que eliminar.');
                return
            end
            QUSConfigurationLogic.storeState(app, state);
            QUSConfigurationLogic.configureDeleteButton(app, state);
            QUSConfigurationLogic.updateExecution(app, state);
            QUSConfigurationLogic.updateStatusSummary(app, state, ...
                sprintf('%s eliminado', deletedLabel));
            QUSConfigurationLogic.refreshAssociatedViews(app);
        end

        function onReset(app)
            state = QUSConfigurationLogic.prepare(app);
            state.referenceDefined = false;
            state.reference = struct();
            state.queue = QUSConfigurationLogic.emptyQueue();
            state.pipelinePath = '';
            state.pipelineCases = struct([]);
            state.previewCases = struct([]);
            state.selectedPipelineCase = [];
            if isprop(app, 'DropDown')
                QUSConfigurationLogic.configureGroupSelector(app, 1, 1);
                app.DropDown.Enable = 'off';
            end
            QUSConfigurationLogic.storeState(app, state);
            QUSConfigurationLogic.configureDeleteButton(app, state);
            QUSConfigurationLogic.updateExecution(app, state);
            QUSConfigurationLogic.updateStatusSummary(app, state, 'Sin configuración');
            QUSConfigurationLogic.refreshAssociatedViews(app);
        end

        function onSave(app)
            state = QUSConfigurationLogic.prepare(app);
            try
                current = QUSConfigurationLogic.readCurrentConfiguration(app, state.advanced);
                QUSConfigurationLogic.validateConfiguration(current);
            catch exception
                QUSConfigurationLogic.showError(app, exception.message);
                return
            end

            if ~state.referenceDefined
                % La primera configuración define la referencia del plan.
                state.reference = current;
                state.referenceDefined = true;
                state.queue = QUSConfigurationLogic.emptyQueue();
            else
                % Save también captura el cambio actual. Así no se pierde una
                % variación si el usuario guarda sin pulsar Set previamente.
                changes = QUSConfigurationLogic.detectChanges(state.reference, current);
                for index = 1:numel(changes)
                    state.queue = QUSConfigurationLogic.addChange(state.queue, changes(index));
                end
                % Renombrar solo cambia el nombre de la carpeta y archivos de
                % salida. No modifica la referencia física ni borra la cola.
                state.reference.experiment.name = current.experiment.name;
            end
            state.advanced.reproducibility = current.reproducibility;
            QUSConfigurationLogic.storeState(app, state);
            QUSConfigurationLogic.configureDeleteButton(app, state);
            QUSConfigurationLogic.updateExecution(app, state);

            fileStem = QUSConfigurationLogic.safeFileName(state.reference.experiment.name);
            outputFolder = QUSConfigurationLogic.codeFolder(app, fileStem);
            if ~exist(outputFolder, 'dir')
                mkdir(outputFolder);
            end
            pipelineFileName = [fileStem, '_pipeline.m'];
            pipelinePath = fullfile(outputFolder, pipelineFileName);
            sbatchFileName = [fileStem, '_pipeline.sh'];
            sbatchPath = fullfile(outputFolder, sbatchFileName);
            metadataFileName = [fileStem, '_pipeline.config.json'];
            metadataPath = fullfile(outputFolder, metadataFileName);

            try
                QUSConfigurationLogic.writePipelineScript(pipelinePath, state);
                QUSConfigurationLogic.writeSbatchScript(sbatchPath, pipelinePath);
                QUSConfigurationLogic.writePipelineCaseJson(metadataPath, state);
            catch exception
                QUSConfigurationLogic.showError(app, exception.message);
                return
            end

            QUSConfigurationLogic.updateStatusSummary(app, state, 'Pipeline guardado');
            QUSConfigurationLogic.refreshAssociatedViews(app);
            if isprop(app, 'Tree') && isprop(app, 'NombreEditField')
                ProjectExplorerLogic.selectExperimentOutputFolder(app);
            end
        end

        function onOpen(app)
            [fileName, folder] = uigetfile({'*.m', 'Pipeline MATLAB (*.m)'}, ...
                'Abrir pipeline reproducible');
            if isequal(fileName, 0)
                return
            end

            QUSConfigurationLogic.openPipelineFile(app, fullfile(folder, fileName));
        end

        function openPipelineFile(app, pipelinePath)
            state = QUSConfigurationLogic.prepare(app);
            try
                parametersByCase = QUSConfigurationLogic.readPipelineCases(pipelinePath);
                parametersByCase = QUSConfigurationLogic.referenceFirst(parametersByCase);
                state.referenceDefined = true;
                state.queue = QUSConfigurationLogic.emptyQueue();
                state.pipelinePath = pipelinePath;
                state.pipelineCases = parametersByCase;
                QUSConfigurationLogic.configureGroupSelector(app, numel(parametersByCase), 1);
                state = QUSConfigurationLogic.applyPipelineCase(app, state, 1);
            catch exception
                QUSConfigurationLogic.showError(app, exception.message);
                return
            end

            QUSConfigurationLogic.storeState(app, state);
            QUSConfigurationLogic.configureDeleteButton(app, state);
            QUSConfigurationLogic.updateExecution(app, state);
            QUSConfigurationLogic.updateStatusSummary(app, state, 'Pipeline cargado: Ref');
            QUSConfigurationLogic.refreshAssociatedViews(app);
        end

        function onGroupSelected(app)
            state = QUSConfigurationLogic.prepare(app);
            caseIndex = QUSConfigurationLogic.groupIndex(app.DropDown.Value);
            try
                if isfield(state, 'previewCases') && ~isempty(state.previewCases)
                    if caseIndex < 1 || caseIndex > numel(state.previewCases)
                        error('El caso seleccionado no existe en la cola actual.');
                    end
                    configuration = state.previewCases(caseIndex).configuration;
                    state.advanced = QUSConfigurationLogic.advancedFromReference(configuration);
                    QUSConfigurationLogic.applyConfiguration(app, configuration);
                    statusText = sprintf('Configuración en cola: %s', ...
                        QUSConfigurationLogic.caseLabel(caseIndex));
                elseif isfield(state, 'pipelineCases') && ~isempty(state.pipelineCases)
                    if caseIndex < 1 || caseIndex > numel(state.pipelineCases)
                        error('El caso seleccionado no existe en el pipeline abierto.');
                    end
                    state = QUSConfigurationLogic.applyPipelineCase(app, state, caseIndex);
                    statusText = sprintf('Pipeline cargado: %s', ...
                        QUSConfigurationLogic.caseLabel(caseIndex));
                else
                    return
                end
            catch exception
                QUSConfigurationLogic.showError(app, exception.message);
                return
            end

            QUSConfigurationLogic.storeState(app, state);
            QUSConfigurationLogic.configureDeleteButton(app, state);
            QUSConfigurationLogic.updateExecution(app, state);
            QUSConfigurationLogic.updateStatusSummary(app, state, statusText);
            QUSConfigurationLogic.refreshAssociatedViews(app);
        end

        function [gridSizeZ, gridSizeX] = currentGridSize(app)
            [gridSizeZ, gridSizeX] = QUSConfigurationLogic.parseGridSize( ...
                app.GridSizeEditField.Value);
        end

        function updateCalculatedTime(app)
            if ~isprop(app, 'TiempoEditField') || ~isvalid(app.TiempoEditField)
                return
            end
            depth = app.DimensionesEditField.Value;
            soundSpeed = app.VelsonidoEditField.Value;
            if isfinite(depth) && depth > 0 && isfinite(soundSpeed) && soundSpeed > 0
                app.TiempoEditField.Value = 1e6 * (2 * depth / soundSpeed);
            else
                app.TiempoEditField.Value = 0;
            end
        end

        function onMediumModelChanged(app)
            state = QUSConfigurationLogic.prepare(app);
            state.advanced.medium.config = MediumConfigurationLogic.forModel( ...
                state.advanced.medium.config, app.ModeloDropDown.Value);
            if strcmp(state.advanced.medium.config.kind, 'layers')
                state.advanced.medium.config = MediumConfigurationLogic.setLayerCount( ...
                    state.advanced.medium.config, ...
                    numel(state.advanced.medium.config.layers), ...
                    1e3 * app.DimensionesEditField.Value);
            end
            app.VelsonidoEditField.Value = state.advanced.medium.config.background.sound_speed;
            app.DensidadEditField.Value = state.advanced.medium.config.background.density;
            densityStdField = QUSConfigurationLogic.densityStdControl(app);
            densityStdField.Value = state.advanced.medium.config.background.density_std;
            QUSConfigurationLogic.storeState(app, state);
        end

        function onGridSizeChanged(app)
            state = QUSConfigurationLogic.prepare(app);
            try
                [gridSizeX, gridSizeY] = QUSConfigurationLogic.parseGridSize( ...
                    app.GridSizeEditField.Value);
            catch exception
                QUSConfigurationLogic.syncGridSizeDisplay(app, state.advanced.computation.grid_size_y);
                QUSConfigurationLogic.showError(app, exception.message);
                return
            end

            state.advanced.computation.grid_size_y = gridSizeY;
            QUSConfigurationLogic.storeState(app, state);
            QUSConfigurationLogic.updateCalculatedTime(app);
        end

        function syncGridSizeDisplay(app, gridSizeY)
            if ~isprop(app, 'GridSizeEditField') || ~isvalid(app.GridSizeEditField)
                return
            end
            if nargin < 2
                state = QUSConfigurationLogic.prepare(app);
                gridSizeY = state.advanced.computation.grid_size_y;
            end
            try
                [gridSizeZ, ~] = QUSConfigurationLogic.currentGridSize(app);
            catch
                gridSizeZ = 5.6e-2;
            end
            app.GridSizeEditField.Value = QUSConfigurationLogic.formatGridSize(gridSizeZ, gridSizeY);
        end

        function openMediumSettings(app)
            state = QUSConfigurationLogic.prepare(app);
            settings = state.advanced.medium;
            if ~isfield(settings, 'config')
                settings.config = MediumConfigurationLogic.defaultConfig();
            end
            settings.config = MediumConfigurationLogic.forModel(settings.config, app.ModeloDropDown.Value);
            settings.config.background.sound_speed = app.VelsonidoEditField.Value;
            settings.config.background.density = app.DensidadEditField.Value;
            settings.config.background.density_std = QUSConfigurationLogic.densityStdControl(app).Value;
            dialog = QUSConfigurationLogic.settingsDialog('Medio acústico: ACS y geometría');
            dialog.Position = [330 80 650 720];
            acsPreview = uiaxes(dialog, 'Position', [205 445 250 225]);
            tabs = uitabgroup(dialog, 'Position', [15 55 620 365]);

            isLayers = strcmp(settings.config.kind, 'layers');
            isSingleInclusion = any(strcmp(settings.config.kind, ...
                {'single_circle', 'single_shape'}));
            alphaPower = []; alphaMode = [];
            inclusionAlphaPower = []; inclusionAlphaMode = [];
            homAlpha = []; cReference = []; inclusionCReference = [];
            if ~isLayers
                absorptionTab = uitab(tabs, 'Title', 'Background ACS');
                absorptionGrid = uigridlayout(absorptionTab, [4 2]);
                absorptionGrid.ColumnWidth = {'1x', '1x'};
                homAlpha = QUSConfigurationLogic.numericField(absorptionGrid, 1, ...
                    'Background ACS [dB/cm/MHz]', settings.hom_alpha);
                alphaPower = QUSConfigurationLogic.numericField(absorptionGrid, 2, ...
                    'Alpha power (global)', settings.alpha_power);
                alphaMode = QUSConfigurationLogic.dropDownField(absorptionGrid, 3, ...
                    'Modo de absorción (global)', {'no_dispersion', 'default'}, settings.alpha_mode);
                cReference = QUSConfigurationLogic.numericField(absorptionGrid, 4, ...
                    'Referencia k-Wave [m/s] (fijada)', settings.sound_speed_ref);
                % This is the reference speed of k-Wave's k-space operator, not
                % an acoustic absorption property.  Keep the baseline value fixed
                % in the GUI so it cannot be confused with the physical c map.
                cReference.Editable = 'off';
                cReference.Tooltip = ['Parámetro numérico del operador k-Wave. ' ...
                    'El baseline usa 1540 m/s; no corresponde a ACS ni a c(x,z).'];
            end

            inclusion = settings.config.inclusions(1);
            inclusionAcs = [];
            shape = []; size1 = []; size2 = []; centerX = []; centerZ = [];
            inclusionTable = []; layersTable = []; layerCount = [];
            selectedInclusionIndex = 1;
            if strcmp(settings.config.kind, 'multiple')
                inclusionTab = uitab(tabs, 'Title', 'Inclusiones');
                data = cell(numel(settings.config.inclusions), 3);
                for index = 1:numel(settings.config.inclusions)
                    item = settings.config.inclusions(index);
                    data(index, :) = {item.shape, item.center_mm(1) / 10, item.center_mm(2) / 10};
                end
                inclusionTable = uitable(inclusionTab, 'Data', data, ...
                    'ColumnName', {'Forma','x cm','z cm'}, ...
                    'ColumnFormat', {{'circle','ellipse','rectangle'}, 'numeric', 'numeric'}, ...
                    'ColumnEditable', true(1, 3), 'Position', [8 42 600 255]);
                addButton = uibutton(inclusionTab, 'Text', '+ Inclusión', 'Position', [8 8 115 26]);
                removeButton = uibutton(inclusionTab, 'Text', '− Última', 'Position', [132 8 105 26]);
                modifyButton = uibutton(inclusionTab, 'Text', 'Modificar propiedades', ...
                    'Position', [247 8 165 26]);
                addButton.ButtonPushedFcn = @(~, ~) addInclusionRow();
                removeButton.ButtonPushedFcn = @(~, ~) removeInclusionRow();
                modifyButton.ButtonPushedFcn = @(~, ~) modifySelectedInclusion();
                inclusionTable.CellSelectionCallback = @(~, event) selectInclusion(event);
            elseif strcmp(settings.config.kind, 'layers')
                layersTab = uitab(tabs, 'Title', 'Capas');
                depthMm = 1e3 * app.DimensionesEditField.Value;
                settings.config = MediumConfigurationLogic.setLayerCount( ...
                    settings.config, numel(settings.config.layers), depthMm);
                uilabel(layersTab, 'Text', 'Número de capas:', ...
                    'Position', [20 318 125 24]);
                layerCount = uidropdown(layersTab, 'Items', {'1','2','3','4'}, ...
                    'Value', num2str(numel(settings.config.layers)), ...
                    'Position', [150 318 70 24]);
                layerInfo = uilabel(layersTab, 'Text', '', ...
                    'Position', [232 318 365 24]);
                layersTable = uitable(layersTab, ...
                    'ColumnName', {'ACS [dB/cm/MHz]'}, ...
                    'ColumnFormat', {'numeric'}, ...
                    'ColumnEditable', true, 'Position', [20 20 580 280]);
                updateLayerTable();
                layerCount.ValueChangedFcn = @(~, ~) updateLayerCount();
                layersTable.CellEditCallback = @(~, ~) refreshAcsPreview();
            elseif ~strcmp(settings.config.kind, 'homogeneous')
                inclusionAcsTab = uitab(tabs, 'Title', 'Inclusión ACS');
                inclusionAcsGrid = uigridlayout(inclusionAcsTab, [4 2]);
                inclusionAcs = QUSConfigurationLogic.numericField(inclusionAcsGrid, 1, ...
                    'Inclusión ACS [dB/cm/MHz]', inclusion.acoustic.acs);
                inclusionAlphaPower = QUSConfigurationLogic.numericField(inclusionAcsGrid, 2, ...
                    'Alpha power (global)', settings.alpha_power);
                inclusionAlphaMode = QUSConfigurationLogic.dropDownField(inclusionAcsGrid, 3, ...
                    'Modo de absorción (global)', {'no_dispersion', 'default'}, settings.alpha_mode);
                inclusionCReference = QUSConfigurationLogic.numericField(inclusionAcsGrid, 4, ...
                    'Referencia k-Wave [m/s] (fijada)', settings.sound_speed_ref);
                inclusionCReference.Editable = 'off';
                inclusionCReference.Tooltip = cReference.Tooltip;
                geometryTab = uitab(tabs, 'Title', 'Geometría');
                geometryRows = 5;
                if strcmp(settings.config.kind, 'single_circle')
                    geometryRows = 3;
                end
                geometryGrid = uigridlayout(geometryTab, [geometryRows 2]);
                if strcmp(settings.config.kind, 'single_circle')
                    size1 = QUSConfigurationLogic.numericField(geometryGrid, 1, ...
                        'Radio [mm]', inclusion.geometry_mm(1));
                    size2 = [];
                    centerX = QUSConfigurationLogic.numericField(geometryGrid, 2, ...
                        'x lateral [mm]', inclusion.center_mm(1));
                else
                    shape = QUSConfigurationLogic.dropDownField(geometryGrid, 1, 'Forma', ...
                        {'ellipse','rectangle'}, inclusion.shape);
                    size1 = QUSConfigurationLogic.numericField(geometryGrid, 2, ...
                        'Dimensión lateral [mm]', inclusion.geometry_mm(1));
                    size2 = QUSConfigurationLogic.numericField(geometryGrid, 3, ...
                        'Dimensión axial [mm]', inclusion.geometry_mm(2));
                    centerX = QUSConfigurationLogic.numericField(geometryGrid, 4, ...
                        'x lateral [mm]', inclusion.center_mm(1));
                end
                centerZValue = inclusion.center_mm(2);
                centerZLabel = 'z axial [mm]';
                centerZIsAutomatic = ~isfinite(centerZValue);
                if centerZIsAutomatic
                    % NaN representa centro axial automático en la
                    % configuración. uieditfield exige un escalar finito,
                    % por eso el diálogo muestra la mitad de profundidad.
                    centerZValue = 5e2 * app.DimensionesEditField.Value;
                    centerZLabel = 'z axial [mm] (automático)';
                end
                centerZRow = geometryRows;
                centerZ = QUSConfigurationLogic.numericField(geometryGrid, centerZRow, ...
                    centerZLabel, centerZValue);
                if centerZIsAutomatic
                    centerZ.Enable = 'off';
                end
            end

            QUSConfigurationLogic.dialogButtons(dialog, @applySettings);
            previewControls = {homAlpha, alphaPower, alphaMode, cReference, inclusionAcs, ...
                inclusionAlphaPower, inclusionAlphaMode, inclusionCReference, size1, size2, centerX, centerZ};
            for controlIndex = 1:numel(previewControls)
                if ~isempty(previewControls{controlIndex})
                    previewControls{controlIndex}.ValueChangedFcn = @(source, ~) ...
                        synchronizeAbsorptionControls(source);
                end
            end
            if ~isempty(shape), shape.ValueChangedFcn = @(~, ~) refreshAcsPreview(); end
            if ~isempty(inclusionTable), inclusionTable.CellEditCallback = @(~, ~) refreshAcsPreview(); end
            refreshAcsPreview();

            function applySettings(~, ~)
                % Esta ventana solo captura la configuración. La validación
                % física se hace de manera centralizada al pulsar Set, junto
                % con geometría, emisor, cálculo y reproducibilidad.
                config = settings.config;
                backgroundAcs = settings.hom_alpha;
                alphaPowerValue = settings.alpha_power;
                alphaModeValue = settings.alpha_mode;
                soundSpeedReference = settings.sound_speed_ref;
                if ~isempty(homAlpha), backgroundAcs = homAlpha.Value; end
                if ~isempty(alphaPower), alphaPowerValue = alphaPower.Value; end
                if ~isempty(alphaMode), alphaModeValue = alphaMode.Value; end
                if ~isempty(cReference), soundSpeedReference = cReference.Value; end
                config.background = struct('sound_speed', app.VelsonidoEditField.Value, ...
                    'density', app.DensidadEditField.Value, 'acs', backgroundAcs, ...
                    'density_std', QUSConfigurationLogic.densityStdControl(app).Value);
                config.alpha_power = alphaPowerValue; config.alpha_mode = alphaModeValue; config.sound_speed_ref = soundSpeedReference;
                if ~isempty(inclusionTable)
                    config.inclusions = readInclusions(inclusionTable.Data);
                elseif ~isempty(layersTable)
                    config.layers = readLayers(layersTable.Data);
                    config = MediumConfigurationLogic.setLayerCount(config, ...
                        str2double(layerCount.Value), 1e3 * app.DimensionesEditField.Value);
                elseif ~isempty(inclusionAcs)
                    if strcmp(settings.config.kind, 'single_circle')
                        config.inclusions(1).shape = 'circle';
                        config.inclusions(1).geometry_mm = [size1.Value, 0];
                    else
                        config.inclusions(1).shape = shape.Value;
                        config.inclusions(1).geometry_mm = [size1.Value, size2.Value];
                    end
                    centerZValue = centerZ.Value;
                    if centerZIsAutomatic
                        centerZValue = NaN;
                    end
                    config.inclusions(1).center_mm = [centerX.Value, centerZValue];
                    config.inclusions(1).acoustic = regionWithGlobalProperties(inclusionAcs.Value);
                end
                state.advanced.medium = struct( ...
                    'hom_alpha', backgroundAcs, ...
                    'density_std', QUSConfigurationLogic.densityStdControl(app).Value, ...
                    'alpha_power', alphaPowerValue, ...
                    'alpha_mode', alphaModeValue, ...
                    'sound_speed_ref', soundSpeedReference, 'config', config);
                QUSConfigurationLogic.storeState(app, state);
                delete(dialog);
            end

            function addInclusionRow()
                data = inclusionTable.Data;
                prototype = data(end, :);
                prototype{2} = prototype{2} + 1;
                inclusionTable.Data(end + 1, :) = prototype;
                refreshAcsPreview();
            end

            function selectInclusion(event)
                if ~isempty(event.Indices)
                    selectedInclusionIndex = event.Indices(1);
                end
            end

            function removeInclusionRow()
                if size(inclusionTable.Data, 1) > 1
                    inclusionTable.Data(end, :) = [];
                    refreshAcsPreview();
                end
            end

            function modifySelectedInclusion()
                items = readInclusions(inclusionTable.Data);
                index = min(max(1, selectedInclusionIndex), numel(items));
                item = items(index);
                propertyDialog = uifigure('Name', sprintf('Inclusión %d: propiedades', index), ...
                    'Position', [470 260 460 390], 'WindowStyle', 'modal', 'Resize', 'off');
                geometryRows = 1;
                if strcmp(item.shape, 'ellipse') || strcmp(item.shape, 'rectangle')
                    geometryRows = 2;
                end
                grid = uigridlayout(propertyDialog, [4 + geometryRows 2]);
                grid.Padding = [15 48 15 15];
                acsField = QUSConfigurationLogic.numericField(grid, 1, 'ACS [dB/cm/MHz]', item.acoustic.acs);
                alphaPowerField = QUSConfigurationLogic.numericField(grid, 2, ...
                    'Alpha power (global)', settings.config.alpha_power);
                alphaModeField = QUSConfigurationLogic.dropDownField(grid, 3, ...
                    'Modo de absorción (global)', {'no_dispersion', 'default'}, settings.config.alpha_mode);
                cReferenceField = QUSConfigurationLogic.numericField(grid, 4, ...
                    'Referencia k-Wave [m/s] (fijada)', settings.config.sound_speed_ref);
                cReferenceField.Editable = 'off';
                if strcmp(item.shape, 'circle')
                    geometryField1 = QUSConfigurationLogic.numericField(grid, 5, ...
                        'Radio [mm]', item.geometry_mm(1));
                    geometryField2 = [];
                elseif strcmp(item.shape, 'ellipse')
                    geometryField1 = QUSConfigurationLogic.numericField(grid, 5, ...
                        'Semieje lateral [mm]', item.geometry_mm(1));
                    geometryField2 = QUSConfigurationLogic.numericField(grid, 6, ...
                        'Semieje axial [mm]', item.geometry_mm(2));
                else
                    geometryField1 = QUSConfigurationLogic.numericField(grid, 5, ...
                        'Ancho lateral [mm]', item.geometry_mm(1));
                    geometryField2 = QUSConfigurationLogic.numericField(grid, 6, ...
                        'Alto axial [mm]', item.geometry_mm(2));
                end
                uibutton(propertyDialog, 'Text', 'Aplicar', 'Position', [250 12 92 26], ...
                    'ButtonPushedFcn', @(~, ~) applyInclusionProperties());
                uibutton(propertyDialog, 'Text', 'Cancelar', 'Position', [350 12 92 26], ...
                    'ButtonPushedFcn', @(~, ~) delete(propertyDialog));
                function applyInclusionProperties()
                    geometryValues = geometryField1.Value;
                    if isempty(geometryField2)
                        geometryValues(2) = 0;
                        positiveDimensions = geometryValues(1);
                    else
                        geometryValues(2) = geometryField2.Value;
                        positiveDimensions = geometryValues;
                    end
                    if any(~isfinite(geometryValues)) || any(positiveDimensions <= 0)
                        uialert(propertyDialog, 'Las dimensiones de la inclusión deben ser positivas.', ...
                            'Geometría inválida');
                        return
                    end
                    items(index).acoustic.acs = acsField.Value;
                    items(index).geometry_mm = geometryValues;
                    settings.config.alpha_power = alphaPowerField.Value;
                    settings.config.alpha_mode = alphaModeField.Value;
                    settings.config.sound_speed_ref = cReferenceField.Value;
                    settings.config.inclusions = items;
                    if ~isempty(alphaPower), alphaPower.Value = alphaPowerField.Value; end
                    if ~isempty(alphaMode), alphaMode.Value = alphaModeField.Value; end
                    if ~isempty(cReference), cReference.Value = cReferenceField.Value; end
                    if ~isempty(inclusionAlphaPower), inclusionAlphaPower.Value = alphaPowerField.Value; end
                    if ~isempty(inclusionAlphaMode), inclusionAlphaMode.Value = alphaModeField.Value; end
                    if ~isempty(inclusionCReference), inclusionCReference.Value = cReferenceField.Value; end
                    delete(propertyDialog);
                    refreshAcsPreview();
                end
            end

            function synchronizeAbsorptionControls(source)
                if isequal(source, alphaPower) && ~isempty(inclusionAlphaPower)
                    inclusionAlphaPower.Value = alphaPower.Value;
                elseif isequal(source, inclusionAlphaPower) && ~isempty(alphaPower)
                    alphaPower.Value = inclusionAlphaPower.Value;
                elseif isequal(source, alphaMode) && ~isempty(inclusionAlphaMode)
                    inclusionAlphaMode.Value = alphaMode.Value;
                elseif isequal(source, inclusionAlphaMode) && ~isempty(alphaMode)
                    alphaMode.Value = inclusionAlphaMode.Value;
                elseif isequal(source, cReference) && ~isempty(inclusionCReference)
                    inclusionCReference.Value = cReference.Value;
                elseif isequal(source, inclusionCReference) && ~isempty(cReference)
                    cReference.Value = inclusionCReference.Value;
                end
                refreshAcsPreview();
            end

            function refreshAcsPreview()
                try
                    config = settings.config;
                    backgroundAcs = settings.hom_alpha;
                    alphaPowerValue = settings.alpha_power;
                    alphaModeValue = settings.alpha_mode;
                    soundSpeedReference = settings.sound_speed_ref;
                    if ~isempty(homAlpha), backgroundAcs = homAlpha.Value; end
                    if ~isempty(alphaPower), alphaPowerValue = alphaPower.Value; end
                    if ~isempty(alphaMode), alphaModeValue = alphaMode.Value; end
                    if ~isempty(cReference), soundSpeedReference = cReference.Value; end
                    config.background = struct('sound_speed', app.VelsonidoEditField.Value, ...
                        'density', app.DensidadEditField.Value, 'acs', backgroundAcs, ...
                        'density_std', QUSConfigurationLogic.densityStdControl(app).Value);
                    config.alpha_power = alphaPowerValue;
                    config.alpha_mode = alphaModeValue;
                    config.sound_speed_ref = soundSpeedReference;
                    if ~isempty(inclusionTable)
                        config.inclusions = readInclusions(inclusionTable.Data);
                    elseif ~isempty(inclusionAcs)
                        if strcmp(config.kind, 'single_circle')
                            config.inclusions(1).shape = 'circle';
                            config.inclusions(1).geometry_mm = [size1.Value, 0];
                        else
                            config.inclusions(1).shape = shape.Value;
                            config.inclusions(1).geometry_mm = [size1.Value, size2.Value];
                        end
                        config.inclusions(1).center_mm = [centerX.Value, centerZ.Value];
                        config.inclusions(1).acoustic = regionWithGlobalProperties(inclusionAcs.Value);
                    elseif ~isempty(layersTable)
                        config.layers = readLayers(layersTable.Data);
                    end
                    axial = linspace(0, 1e3 * app.DimensionesEditField.Value, 180);
                    lateral = linspace(-5e2 * state.advanced.computation.grid_size_y, ...
                        5e2 * state.advanced.computation.grid_size_y, 150);
                    [~, ~, acs] = MediumConfigurationLogic.maps(config, axial, lateral, ...
                        state.advanced.reproducibility.rng_seed);
                    cla(acsPreview);
                    imagesc(acsPreview, lateral / 10, axial / 10, acs, [0.35 1.05]);
                    set(acsPreview, 'YDir', 'reverse'); axis(acsPreview, 'image');
                    % El preview es una verificación del dominio que verá
                    % k-Wave. Incluye la PML externa en los límites y deja
                    % el mapa ACS sólo dentro de la malla física.
                    dx = app.VelsonidoEditField.Value / ...
                        (app.ResolucinEditField.Value * app.FrecuenciaEditField.Value * 1e6);
                    pml = app.PMLCantcapasEditField.Value * dx;
                    lateralHalf = state.advanced.computation.grid_size_y / 2;
                    depth = app.DimensionesEditField.Value;
                    margin = max(0.002, 0.08 * max(depth, state.advanced.computation.grid_size_y));
                    hold(acsPreview, 'on');
                    rectangle(acsPreview, 'Position', [-100 * lateralHalf, 0, ...
                        200 * lateralHalf, 100 * depth], 'EdgeColor', [0.15 0.15 0.15], ...
                        'LineWidth', 1.3, 'LineStyle', '-');
                    rectangle(acsPreview, 'Position', [-100 * (lateralHalf + pml), -100 * pml, ...
                        200 * (lateralHalf + pml), 100 * (depth + 2 * pml)], ...
                        'EdgeColor', [0.45 0.45 0.45], 'LineWidth', 1.1, 'LineStyle', '--');
                    hold(acsPreview, 'off');
                    xlim(acsPreview, 100 * [-lateralHalf - pml - margin, lateralHalf + pml + margin]);
                    ylim(acsPreview, 100 * [-pml - margin, depth + pml + margin]);
                    colormap(acsPreview, turbo(256));
                    acsColorbar = colorbar(acsPreview);
                    acsColorbar.Label.String = 'ACS [dB/cm/MHz]';
                    acsColorbar.Ticks = 0.4:0.1:1.0;
                    acsColorbar.TickLabels = {'0.4', '', '0.6', '', '0.8', '', '1'};
                    title(acsPreview, 'ACS');
                    xlabel(acsPreview, 'x lateral [cm]'); ylabel(acsPreview, 'z [cm]');
                catch
                    cla(acsPreview); grid(acsPreview, 'on');
                    title(acsPreview, 'ACS');
                end
            end

            function updateLayerCount()
                settings.config.layers = readLayers(layersTable.Data);
                settings.config = MediumConfigurationLogic.setLayerCount(settings.config, ...
                    str2double(layerCount.Value), 1e3 * app.DimensionesEditField.Value);
                updateLayerTable();
                refreshAcsPreview();
            end

            function updateLayerTable()
                layerNumber = numel(settings.config.layers);
                data = cell(layerNumber, 1);
                for layerIndex = 1:layerNumber
                    item = settings.config.layers(layerIndex);
                    data(layerIndex, :) = {item.acoustic.acs};
                end
                layersTable.Data = data;
                layersTable.RowName = arrayfun(@(layerIndex) ...
                    sprintf('Capa %d', layerIndex), 1:layerNumber, 'UniformOutput', false);
                layerInfo.Text = sprintf('Espesor automático: %.3g mm (1/%d de la profundidad).', ...
                    1e3 * app.DimensionesEditField.Value / layerNumber, layerNumber);
            end

            function inclusions = readInclusions(data)
                inclusions = repmat(settings.config.inclusions(1), 1, size(data, 1));
                for index = 1:size(data, 1)
                    sourceIndex = min(index, numel(settings.config.inclusions));
                    inclusions(index) = settings.config.inclusions(sourceIndex);
                    inclusions(index).shape = char(string(data{index, 1}));
                    inclusions(index).center_mm = 10 * [data{index, 2}, data{index, 3}];
                    inclusions(index).acoustic = regionWithGlobalProperties( ...
                        settings.config.inclusions(sourceIndex).acoustic.acs);
                end
            end

            function layers = readLayers(data)
                layers = repmat(struct('thickness_mm', 0, ...
                    'acoustic', settings.config.background), 1, size(data, 1));
                thicknessMm = 1e3 * app.DimensionesEditField.Value / size(data, 1);
                for index = 1:size(data, 1)
                    layers(index).thickness_mm = thicknessMm;
                    layers(index).acoustic = regionWithGlobalProperties(data{index, 1});
                end
            end

            function region = regionWithGlobalProperties(acs)
                region = struct('sound_speed', app.VelsonidoEditField.Value, ...
                    'density', app.DensidadEditField.Value, 'acs', acs, ...
                    'density_std', QUSConfigurationLogic.densityStdControl(app).Value);
            end
        end

        function openTransducerSettings(app)
            state = QUSConfigurationLogic.prepare(app);
            settings = state.advanced.transducer;
            defaults = QUSConfigurationLogic.defaultAdvancedSettings();
            if ~isfield(settings, 'receive_directivity_size_factor')
                settings.receive_directivity_size_factor = ...
                    defaults.transducer.receive_directivity_size_factor;
            end
            if ~isfield(settings, 'receive_directivity_angle')
                settings.receive_directivity_angle = ...
                    defaults.transducer.receive_directivity_angle;
            end
            dialog = QUSConfigurationLogic.settingsDialog('Transductor: parámetros avanzados');
            tabs = uitabgroup(dialog, 'Position', [15 55 490 285]);

            arrayTab = uitab(tabs, 'Title', 'Arreglo');
            arrayGrid = uigridlayout(arrayTab, [3 2]);
            arrayGrid.ColumnWidth = {'1x', '1x'};
            focus = QUSConfigurationLogic.numericField(arrayGrid, 1, 'Focal depth [cm]', 1e2 * settings.source_focus);
            pitch = QUSConfigurationLogic.numericField(arrayGrid, 2, 'Pitch [mm]', 1e3 * settings.element_pitch);
            width = QUSConfigurationLogic.numericField(arrayGrid, 3, 'Element width [m]', settings.element_width);

            scanTab = uitab(tabs, 'Title', 'Apertura y escaneo');
            scanGrid = uigridlayout(scanTab, [7 2]);
            scanGrid.ColumnWidth = {'1x', '1x'};
            fNumberTx = QUSConfigurationLogic.numericField(scanGrid, 1, 'Focal number Tx', settings.focal_number_tx);
            activeTxElements = uilabel(scanGrid, 'Text', 'Active Tx elements');
            activeTxElements.Layout.Row = 2;
            activeTxElements.Layout.Column = 1;
            activeTxElementsValue = uilabel(scanGrid, 'HorizontalAlignment', 'right');
            activeTxElementsValue.Layout.Row = 2;
            activeTxElementsValue.Layout.Column = 2;
            fNumberRx = QUSConfigurationLogic.numericField(scanGrid, 3, 'Focal number Rx', settings.focal_number_rx);
            receiveElements = uilabel(scanGrid, 'Text', 'Receive elements');
            receiveElements.Layout.Row = 4;
            receiveElements.Layout.Column = 1;
            receiveElementsValue = uilabel(scanGrid, 'HorizontalAlignment', 'right');
            receiveElementsValue.Layout.Row = 4;
            receiveElementsValue.Layout.Column = 2;
            totalElements = uilabel(scanGrid, 'Text', 'Number of elements');
            totalElements.Layout.Row = 5;
            totalElements.Layout.Column = 1;
            totalElementsValue = uilabel(scanGrid, 'HorizontalAlignment', 'right');
            totalElementsValue.Layout.Row = 5;
            totalElementsValue.Layout.Column = 2;
            nLines = QUSConfigurationLogic.numericField(scanGrid, 6, 'Number of beams', settings.n_lines);
            note = uilabel(scanGrid, 'Text', 'Each beam is one lateral acquisition. In the current pipeline, Number of elements equals Receive elements.');
            note.WordWrap = 'on';
            note.Layout.Row = 7;
            note.Layout.Column = [1 2];

            positionTab = uitab(tabs, 'Title', 'Posición');
            positionGrid = uigridlayout(positionTab, [2 2]);
            positionGrid.ColumnWidth = {'1x', '1x'};
            baseX = QUSConfigurationLogic.numericField(positionGrid, 1, 'Axial translation [m]', settings.base_translation_x);
            baseY = QUSConfigurationLogic.numericField(positionGrid, 2, 'Lateral translation [m]', settings.base_translation_y);

            updateDerivedElements();
            focus.ValueChangedFcn = @(~, ~) updateDerivedElements();
            pitch.ValueChangedFcn = @(~, ~) updateDerivedElements();
            fNumberTx.ValueChangedFcn = @(~, ~) updateDerivedElements();
            fNumberRx.ValueChangedFcn = @(~, ~) updateDerivedElements();

            receiveTab = uitab(tabs, 'Title', 'Recepción');
            receiveGrid = uigridlayout(receiveTab, [3 2]);
            receiveGrid.ColumnWidth = {'1x', '1x'};
            directivityFactor = QUSConfigurationLogic.numericField(receiveGrid, 1, ...
                'Factor de directividad × dx', settings.receive_directivity_size_factor);
            directivityAngle = QUSConfigurationLogic.numericField(receiveGrid, 2, ...
                'Ángulo de directividad [rad]', settings.receive_directivity_angle);
            receiveNote = uilabel(receiveGrid, 'Text', ...
                'El mismo kWaveArray recibe las señales del pulso-eco.');
            receiveNote.WordWrap = 'on';
            receiveNote.Layout.Row = 3;
            receiveNote.Layout.Column = [1 2];

            QUSConfigurationLogic.dialogButtons(dialog, @applySettings);

            function updateDerivedElements()
                if all(isfinite([focus.Value, pitch.Value, fNumberTx.Value, fNumberRx.Value])) && ...
                        focus.Value > 0 && pitch.Value > 0 && ...
                        fNumberTx.Value > 0 && fNumberRx.Value > 0
                    focalDepthMeters = 1e-2 * focus.Value;
                    pitchMeters = 1e-3 * pitch.Value;
                    activeTxElementsValue.Text = string(floor( ...
                        (focalDepthMeters / fNumberTx.Value) / pitchMeters));
                    receiveElementsValue.Text = string(floor( ...
                        (focalDepthMeters / fNumberRx.Value) / pitchMeters));
                    totalElementsValue.Text = receiveElementsValue.Text;
                else
                    activeTxElementsValue.Text = '—';
                    receiveElementsValue.Text = '—';
                    totalElementsValue.Text = '—';
                end
            end

            function applySettings(~, ~)
                values = [focus.Value, pitch.Value, width.Value, fNumberTx.Value, ...
                    fNumberRx.Value, nLines.Value, directivityFactor.Value];
                positionValues = [baseX.Value, baseY.Value, directivityAngle.Value];
                if any(~isfinite(values)) || any(values <= 0) || any(~isfinite(positionValues))
                    uialert(dialog, 'Focal depth [cm], pitch [mm], element width, focal numbers y number of beams deben ser positivos. Las posiciones pueden ser cero.', ...
                        'Valores inválidos');
                    return
                end
                if nLines.Value ~= round(nLines.Value)
                    uialert(dialog, 'Number of beams debe ser un entero positivo.', ...
                        'Valor inválido');
                    return
                end
                focalDepthMeters = 1e-2 * focus.Value;
                pitchMeters = 1e-3 * pitch.Value;
                activeTxCount = floor((focalDepthMeters / fNumberTx.Value) / pitchMeters);
                receiveCount = floor((focalDepthMeters / fNumberRx.Value) / pitchMeters);
                if activeTxCount < 1 || receiveCount < 1
                    uialert(dialog, 'La apertura configurada debe generar al menos un elemento Tx y un elemento Rx.', ...
                        'Configuración no compatible');
                    return
                end
                if activeTxCount > receiveCount
                    uialert(dialog, 'Active Tx elements no puede exceder Receive elements en la implementación actual.', ...
                        'Configuración no compatible');
                    return
                end
                state.advanced.transducer = struct( ...
                    'source_focus', focalDepthMeters, ...
                    'element_pitch', pitchMeters, ...
                    'element_width', width.Value, ...
                    'focal_number_tx', fNumberTx.Value, ...
                    'focal_number_rx', fNumberRx.Value, ...
                    'n_lines', round(nLines.Value), ...
                    'base_translation_x', baseX.Value, ...
                    'base_translation_y', baseY.Value, ...
                    'rotation', 0, ...
                    'receive_directivity_size_factor', directivityFactor.Value, ...
                    'receive_directivity_angle', directivityAngle.Value);
                QUSConfigurationLogic.storeState(app, state);
                QUSConfigurationLogic.refreshPreviewIfAvailable(app);
                delete(dialog);
            end
        end

        function openSensorSettings(app)
            uialert(app.UIFigure, ...
                'La recepción usa el mismo kWaveArray que el transductor emisor. Configure su directividad en “Configurar Transductor”.', ...
                'Recepción integrada al transductor');
        end

        function openPipelineSettings(app)
            state = QUSConfigurationLogic.prepare(app);
            output = state.advanced.output;
            dialog = QUSConfigurationLogic.settingsDialog('Pipeline: salida');
            tabs = uitabgroup(dialog, 'Position', [15 55 490 285]);

            outputTab = uitab(tabs, 'Title', 'Salida');
            outputGrid = uigridlayout(outputTab, [2 2]);
            outputGrid.ColumnWidth = {'1x', '1x'};
            saveMedium = QUSConfigurationLogic.checkBoxField(outputGrid, 1, ...
                'Guardar vistas del medio (.fig y .png)', output.save_medium_previews);
            saveRf = QUSConfigurationLogic.checkBoxField(outputGrid, 2, ...
                'Guardar RF pre-beamforming (.mat)', output.save_rf_prebeamformed);
            QUSConfigurationLogic.dialogButtons(dialog, @applySettings);

            function applySettings(~, ~)
                state.advanced.output = struct( ...
                    'save_medium_previews', saveMedium.Value, ...
                    'save_rf_prebeamformed', saveRf.Value);
                QUSConfigurationLogic.configurePipelineSummaryControls(app, state.advanced);
                QUSConfigurationLogic.storeState(app, state);
                QUSConfigurationLogic.updateStatusSummary(app, state, ...
                    'Cambios pendientes: pulsa Set');
                delete(dialog);
            end
        end

        function onPipelineSummaryChanged(app)
            % Los campos del panel principal describen la configuración que
            % quedará en el siguiente Set. Set conserva después una copia
            % completa e inmutable en Ref o Case.
            dataCast = char(string(app.TipoDropDown_2.Value));
            plotSim = strcmpi(char(string(app.PlanoDropDown.Value)), 'true');

            state = QUSConfigurationLogic.prepare(app);
            state.advanced.computation.data_cast = dataCast;
            state.advanced.computation.plot_sim_flag = plotSim;
            QUSConfigurationLogic.storeState(app, state);
            QUSConfigurationLogic.configurePipelineSummaryControls(app, state.advanced);
            QUSConfigurationLogic.updateStatusSummary(app, state, ...
                'Cambios pendientes: pulsa Set');
        end
    end

    methods (Static, Access = private)
        
        % Se llama antes de acciones importantes como Set, Save, Open o Reset.
        function state = prepare(app)
            QUSConfigurationLogic.configureInitialBaselineLayout(app);
            if isprop(app, 'GridLayout15') && isvalid(app.GridLayout15)
                app.GridLayout15.Visible = 'off';
            end
            app.TextArea.Editable = 'off';
            app.TextArea.FontName = 'Courier New';
            app.TextArea.FontSize = 11;
            
            %Genera el estado inicial
            if isappdata(app.UIFigure, 'QUSConfigurationState')
                state = getappdata(app.UIFigure, 'QUSConfigurationState');
                QUSConfigurationLogic.configureDeleteButton(app, state);
                return
            end
            
            state = struct( ...
                'referenceDefined', false, ...
                'reference', struct(), ...
                'queue', QUSConfigurationLogic.emptyQueue(), ...
                'pipelinePath', '', ...
                'pipelineCases', struct([]), ...
                'previewCases', struct([]), ...
                'selectedPipelineCase', [], ...
                'advanced', QUSConfigurationLogic.defaultAdvancedSettings());

            QUSConfigurationLogic.applyDefaults(app);
            if isprop(app, 'DropDown')
                QUSConfigurationLogic.configureGroupSelector(app, 1, 1);
                app.DropDown.Enable = 'off';
            end
            QUSConfigurationLogic.storeState(app, state);
            QUSConfigurationLogic.configureDeleteButton(app, state);
            QUSConfigurationLogic.updateExecution(app, state);
        end
        
        %Guarda el estado actual de la configuración dentro de la ventana principal de la app.
        function storeState(app, state)
            setappdata(app.UIFigure, 'QUSConfigurationState', state);
        end

        function state = stateIfAvailable(app)
            state = [];
            if isappdata(app.UIFigure, 'QUSConfigurationState')
                state = getappdata(app.UIFigure, 'QUSConfigurationState');
            end
        end

        function configurePipelineSummaryControls(app, advanced)
            app.SensorPanel.Title = 'Cálculo y reproducibilidad';
            app.TipoDropDown_2Label.Text = 'DataCast:';
            app.TipoDropDown_2.Items = {'gpuArray-single', 'single'};
            QUSConfigurationLogic.setDropDown(app.TipoDropDown_2, ...
                advanced.computation.data_cast);
            app.TipoDropDown_2.Enable = 'on';
            app.TipoDropDown_2.Tooltip = [ ...
                'gpuArray-single usa GPU. single ejecuta k-Wave en la CPU. ' ...
                'El valor queda guardado al pulsar Set.'];
            app.TipoDropDown_2.ValueChangedFcn = @(~, ~) ...
                QUSConfigurationLogic.onPipelineSummaryChanged(app);

            app.PlanoDropDownLabel.Text = 'PlotSim:';
            app.PlanoDropDown.Items = {'false', 'true'};
            QUSConfigurationLogic.setDropDown(app.PlanoDropDown, ...
                char(string(logical(advanced.computation.plot_sim_flag))));
            app.PlanoDropDown.Enable = 'on';
            app.PlanoDropDown.Tooltip = [ ...
                'Muestra la simulación de k-Wave durante la ejecución. ' ...
                'El valor queda guardado al pulsar Set.'];
            app.PlanoDropDown.ValueChangedFcn = @(~, ~) ...
                QUSConfigurationLogic.onPipelineSummaryChanged(app);

            app.PosicindelplanoDropDownLabel.Text = 'Semilla global:';
            app.PosicindelplanoDropDown.Items = {num2str(advanced.reproducibility.rng_seed)};
            app.PosicindelplanoDropDown.Value = app.PosicindelplanoDropDown.Items{1};
            app.PosicindelplanoDropDown.Editable = 'off';
            app.PosicindelplanoDropDown.Enable = 'off';
            app.PosicindelplanoDropDown.Tooltip = ...
                'Semilla fija mostrada para trazabilidad de la simulación.';

            app.VariablesDropDownLabel.Text = 'Semilla base:';
            app.VariablesDropDown.Items = {num2str(advanced.reproducibility.ref_seed_base)};
            app.VariablesDropDown.Value = app.VariablesDropDown.Items{1};
            app.VariablesDropDown.Editable = 'off';
            app.VariablesDropDown.Enable = 'off';
            app.VariablesDropDown.Tooltip = ...
                'Semilla base fija mostrada para trazabilidad de las referencias.';

            app.ConfigurarPosicindelsensorButton.Text = 'Configurar Pipeline';
            app.ConfigurarPosicindelsensorButton.Tooltip = ...
                'Configura los archivos y las vistas que se guardarán.';
            app.ConfigurarPosicindelsensorButton.ButtonPushedFcn = @(~, ~) ...
                QUSConfigurationLogic.openPipelineSettings(app);
        end

        function field = densityStdControl(app)
            if isprop(app, 'DensidadStdEditField') && isvalid(app.DensidadStdEditField)
                field = app.DensidadStdEditField;
                return
            end
            field = findobj(app.GridLayout8, 'Tag', 'DensityStdEditField');
            if ~isempty(field)
                field = field(1);
                return
            end
            app.GridLayout8.RowHeight = {'1x', '1x', '1x', '1x', '1.3x'};
            app.ConfigurarMedioAcusticoButton.Layout.Row = 5;
            label = uilabel(app.GridLayout8, 'Text', 'Desv. densidad:');
            label.FontSize = 10;
            label.Layout.Row = 4;
            label.Layout.Column = 1;
            unit = uilabel(app.GridLayout8, 'Text', '[-]');
            unit.FontSize = 10;
            unit.Layout.Row = 4;
            unit.Layout.Column = 3;
            field = uieditfield(app.GridLayout8, 'numeric', 'Value', 0.04, ...
                'Tag', 'DensityStdEditField');
            field.Layout.Row = 4;
            field.Layout.Column = 2;
        end
        
        %Default settings para caso de cambio en atenuacion
        function settings = defaultAdvancedSettings()
            mediumConfig = MediumConfigurationLogic.defaultConfig();
            settings.medium = struct('hom_alpha', mediumConfig.background.acs, ...
                'density_std', mediumConfig.background.density_std, ...
                'alpha_power', mediumConfig.alpha_power, ...
                'alpha_mode', mediumConfig.alpha_mode, ...
                'sound_speed_ref', mediumConfig.sound_speed_ref, ...
                'config', mediumConfig);
            settings.transducer = struct('source_focus', 4e-2, 'element_pitch', 0.3e-3, ...
                'element_width', 0.25e-3, 'focal_number_tx', 4, 'focal_number_rx', 2, ...
                'n_lines', 128, 'base_translation_x', -2.7e-2, ...
                'base_translation_y', 0, 'rotation', 0, ...
                'receive_directivity_size_factor', 10, 'receive_directivity_angle', 0);
            settings.computation = struct('grid_size_y', 4e-2, 'pml_size_y', 41, ...
                'data_cast', 'gpuArray-single', 'plot_sim_flag', false);
            settings.reproducibility = struct('rng_seed', 23, 'ref_seed_base', 50000, ...
                'n_refs_target', 5, 'n_refs_reference', 10);
            settings.output = struct('save_medium_previews', true, ...
                'save_rf_prebeamformed', true);
        end

        % Ajusta la app existente al alcance de la primera etapa sin
        % modificar el archivo binario .mlapp. El pipeline de referencia
        % recibe con el mismo kWaveArray que emite; por ello no expone un
        % sensor independiente. La profundidad define el tiempo de cálculo
        % y pertenece a geometría y malla.
        function configureInitialBaselineLayout(app)
            app.UIAxes4.Visible = 'off';
            QUSConfigurationLogic.densityStdControl(app);
            app.GridSizeEditFieldLabel.Text = 'Malla (z, x):';
            app.GridSizeEditField.ValueChangedFcn = @(~, ~) ...
                QUSConfigurationLogic.onGridSizeChanged(app);
            app.DropDown.ValueChangedFcn = @(~, ~) ...
                QUSConfigurationLogic.onGroupSelected(app);
            app.PruebaButton.Text = 'Delete';
            app.PruebaButton.ButtonPushedFcn = @(~, ~) ...
                QUSConfigurationLogic.onDeleteSelectedCase(app);
            app.ModeloDropDown.Items = {'Homogeneo', 'Inclusión circular', ...
                'Inclusión irregular', ...
                'Medio por capas', 'Múltiples inclusiones'};
            app.ModeloDropDown.ValueChangedFcn = @(~, ~) ...
                QUSConfigurationLogic.onMediumModelChanged(app);

            app.DimensionesEditFieldLabel.Visible = 'on';
            app.DimensionesEditField.Visible = 'on';
            app.mLabel_3.Visible = 'on';
            app.DimensionesEditFieldLabel.Text = 'Profundidad:';
            app.mLabel_3.Text = '[m]';

            app.DescripcinLabel.Parent = app.GridLayout4;
            app.DescripcinLabel.Layout.Row = 2;
            app.DescripcinLabel.Layout.Column = 1;
            app.DescripcinLabel.Text = 'Tiempo calculado:';
            app.TiempoEditField.Parent = app.GridLayout4;
            app.TiempoEditField.Layout.Row = 2;
            app.TiempoEditField.Layout.Column = 2;
            app.TiempoEditField.Editable = 'off';
            app.DescripcinLabel_2.Parent = app.GridLayout4;
            app.DescripcinLabel_2.Layout.Row = 2;
            app.DescripcinLabel_2.Layout.Column = 3;
            app.DescripcinLabel_2.Text = '[µs]';

            app.SensorPanel.Visible = 'on';
            app.SensorPanel.Title = 'Experimento: cálculo y reproducibilidad';
            app.ExperimentoPanel.Layout.Row = 4;
            app.SensorPanel.Layout.Row = 5;
            app.GridLayout2.RowHeight = {'1.1x', '1.1x', '1.6x', '0.85x', '1.1x', '0.3x'};

            % Hasta la etapa 3 el generador solo implementa esta geometría,
            % señal y focalización del baseline; conservar otros menús
            % habilitados sugeriría opciones que todavía no llegan a k-Wave.
            QUSConfigurationLogic.setDropDown(app.TipoDropDown, 'Lineal Plano');
            QUSConfigurationLogic.setDropDown(app.SealDropDown, 'Tone Burst');
            QUSConfigurationLogic.setDropDown(app.MododehazDropDown, 'Focused');
            app.TipoDropDown.Enable = 'off';
            app.SealDropDown.Enable = 'off';
            app.MododehazDropDown.Enable = 'off';

            app.SolverDropDownLabel.Layout.Row = 3;
            app.SolverDropDown.Layout.Row = 3;
            app.GridLayout4.RowHeight = {'1x', '1x', '1x'};

            state = QUSConfigurationLogic.stateIfAvailable(app);
            if isempty(state)
                advanced = QUSConfigurationLogic.defaultAdvancedSettings();
            else
                advanced = state.advanced;
            end
            QUSConfigurationLogic.configurePipelineSummaryControls(app, advanced);
            QUSConfigurationLogic.updateCalculatedTime(app);
        end
        
        % Aqui se define algunos parametros default (en este caso el
        % inicial es del pipeline enviado)
        function applyDefaults(app)
            app.DimensionesEditFieldLabel.Text = 'Profundidad:';
            app.ResolucinEditFieldLabel.Text = 'PPW:';
            app.mLabel_3.Text = '[m]';
            app.DescripcinLabel.Text = 'Tiempo calculado:';
            app.DescripcinLabel_2.Text = '[µs]';
            app.DimensionesEditField.Value = 5.5e-2;
            app.ResolucinEditField.Value = 6;
            app.PMLCantcapasEditField.Value = 41;
            app.CFLEditField.Value = 0.3;
            app.VelsonidoEditField.Value = 1595;
            app.DensidadEditField.Value = 1060;
            densityStdField = QUSConfigurationLogic.densityStdControl(app);
            densityStdField.Value = 0.04;

            % La interfaz usa MHz y MPa; la configuración persistida y
            % k-Wave conservan Hz y Pa para no cambiar el contrato físico.
            app.FrecuenciaEditField.Value = 6.66;
            app.AmplitudEditField_2.Value = 1;
            app.NciclosEditField.Value = 3.5;
            app.NombreEditField.Value = 'homogeneous_benchmark';
            QUSConfigurationLogic.updateCalculatedTime(app);
            app.GridSizeEditField.Value = QUSConfigurationLogic.formatGridSize(5.6e-2, 4e-2);
            QUSConfigurationLogic.setDropDown(app.SolverDropDown, 'kspaceFirstoOrder2D');
            defaults = QUSConfigurationLogic.defaultAdvancedSettings();
            QUSConfigurationLogic.configureRealizationControls(app, defaults.reproducibility);
            app.EstadoEditField.Value = 'Sin configuración';
        end

        % Se aplica la logica de ultimo nRef como referenica y la cola en
        % la forma que se realiza en el pipeline de ejemplo.
        function configureRealizationControls(app, reproducibility)
            if isprop(app, 'NmeroderealizacionesSpinner')
                targetControl = app.NmeroderealizacionesSpinner;
                targetLabel = app.NmeroderealizacionesSpinnerLabel;
            elseif isprop(app, 'nRefsSpinner')
                targetControl = app.nRefsSpinner;
                targetLabel = app.nRefsSpinnerLabel;
            elseif isprop(app, 'Spinner')
                targetControl = app.Spinner;
                targetLabel = app.SpinnerLabel;
            else
                return
            end

            if isprop(app, 'RealizacionesporreferenciaSpinner')
                referenceControl = app.RealizacionesporreferenciaSpinner;
                referenceLabel = app.RealizacionesporreferenciaSpinnerLabel;
            elseif isprop(app, 'Spinner2')
                referenceControl = app.Spinner2;
                referenceLabel = [];
            else
                return
            end
            targetLabel.Text = 'Número de realizaciones';

            if isempty(referenceLabel)
                referenceLabel = findall(app.GridLayout16, 'Type', 'uilabel', ...
                    'Tag', 'ReferenceRealizationsLabel');
            end
            if isempty(referenceLabel)
                referenceLabel = uilabel(app.GridLayout16, ...
                    'Tag', 'ReferenceRealizationsLabel', ...
                    'HorizontalAlignment', 'right');
                referenceLabel.Layout.Row = 2;
                referenceLabel.Layout.Column = 1;
            end
            referenceLabel.Text = 'Realizaciones de referencia';

            controls = {targetControl, referenceControl};
            values = [reproducibility.n_refs_target, reproducibility.n_refs_reference];
            for index = 1:numel(controls)
                controls{index}.Limits = [1 Inf];
                controls{index}.Step = 1;
                controls{index}.RoundFractionalValues = 'on';
                controls{index}.Value = max(1, round(values(index)));
            end
        end
        
        %lee cuántas realizaciones eligió el usuario en los controles numéricos de la app.
        function reproducibility = readRealizationControls(app, reproducibility)
            if isprop(app, 'NmeroderealizacionesSpinner')
                reproducibility.n_refs_target = app.NmeroderealizacionesSpinner.Value;
            elseif isprop(app, 'nRefsSpinner')
                reproducibility.n_refs_target = app.nRefsSpinner.Value;
            elseif isprop(app, 'Spinner')
                reproducibility.n_refs_target = app.Spinner.Value;
            end
            if isprop(app, 'RealizacionesporreferenciaSpinner')
                reproducibility.n_refs_reference = app.RealizacionesporreferenciaSpinner.Value;
            elseif isprop(app, 'Spinner2')
                reproducibility.n_refs_reference = app.Spinner2.Value;
            end
        end
        
        %recoge todos los valores actuales de la interfaz y los organiza en una única estructura llamada configuration
        % para estructurarlos
        function configuration = readCurrentConfiguration(app, advanced)
            [gridSizeX, gridSizeY] = QUSConfigurationLogic.currentGridSize(app);
            mediumConfig = MediumConfigurationLogic.forModel(advanced.medium.config, app.ModeloDropDown.Value);
            mediumConfig.background.sound_speed = app.VelsonidoEditField.Value;
            mediumConfig.background.density = app.DensidadEditField.Value;
            mediumConfig.background.acs = advanced.medium.hom_alpha;
            mediumConfig.background.density_std = QUSConfigurationLogic.densityStdControl(app).Value;
            mediumConfig.alpha_power = advanced.medium.alpha_power;
            mediumConfig.alpha_mode = advanced.medium.alpha_mode;
            mediumConfig.sound_speed_ref = advanced.medium.sound_speed_ref;
            if strcmp(mediumConfig.kind, 'layers')
                mediumConfig = MediumConfigurationLogic.setLayerCount(mediumConfig, ...
                    numel(mediumConfig.layers), 1e3 * app.DimensionesEditField.Value);
            end
            configuration.geometry = struct('grid_size_x', gridSizeX, ...
                'grid_size_y', gridSizeY, 'ppw', app.ResolucinEditField.Value, ...
                'pml_size_x', app.PMLCantcapasEditField.Value, ...
                'pml_size_y', advanced.computation.pml_size_y, 'cfl', app.CFLEditField.Value, ...
                'depth', app.DimensionesEditField.Value);
            surfaceAlignedAxialTranslation = QUSConfigurationLogic.surfaceAlignedAxialTranslation( ...
                app.VelsonidoEditField.Value, app.ResolucinEditField.Value, ...
                app.FrecuenciaEditField.Value * 1e6, gridSizeX);
            configuration.medium = struct('model', char(app.ModeloDropDown.Value), ...
                'sound_speed', app.VelsonidoEditField.Value, 'density', app.DensidadEditField.Value, ...
                'hom_alpha', advanced.medium.hom_alpha, 'density_std', mediumConfig.background.density_std, ...
                'alpha_power', advanced.medium.alpha_power, 'alpha_mode', advanced.medium.alpha_mode, ...
                'sound_speed_ref', advanced.medium.sound_speed_ref, 'config', mediumConfig);
            configuration.transducer = struct('type', char(app.TipoDropDown.Value), ...
                'signal', char(app.SealDropDown.Value), 'beam_mode', char(app.MododehazDropDown.Value), ...
                'frequency', app.FrecuenciaEditField.Value * 1e6, ...
                'amplitude', app.AmplitudEditField_2.Value * 1e6, ...
                'cycles', app.NciclosEditField.Value, ...
                'source_focus', advanced.transducer.source_focus, 'element_pitch', advanced.transducer.element_pitch, ...
                'element_width', advanced.transducer.element_width, 'focal_number_tx', advanced.transducer.focal_number_tx, ...
                'focal_number_rx', advanced.transducer.focal_number_rx, 'n_lines', advanced.transducer.n_lines, ...
                'base_translation_x', surfaceAlignedAxialTranslation, ...
                'base_translation_y', advanced.transducer.base_translation_y, 'rotation', advanced.transducer.rotation, ...
                'receive_directivity_size_factor', advanced.transducer.receive_directivity_size_factor, ...
                'receive_directivity_angle', advanced.transducer.receive_directivity_angle);
            configuration.computation = struct('data_cast', advanced.computation.data_cast, ...
                'plot_sim_flag', advanced.computation.plot_sim_flag, ...
                'solver', char(app.SolverDropDown.Value));
            reproducibility = QUSConfigurationLogic.readRealizationControls( ...
                app, advanced.reproducibility);
            configuration.reproducibility = reproducibility;
            configuration.output = advanced.output;
            configuration.experiment = struct('name', char(app.NombreEditField.Value));
        end
        
        % Algunas llamadas de error
        function validateConfiguration(configuration)
            values = [configuration.geometry.grid_size_x, configuration.geometry.grid_size_y, ...
                configuration.geometry.ppw, configuration.geometry.pml_size_x, configuration.geometry.pml_size_y, ...
                configuration.geometry.depth, configuration.medium.sound_speed, configuration.medium.density, ...
                configuration.transducer.frequency, configuration.transducer.amplitude, configuration.transducer.cycles, ...
                configuration.transducer.source_focus, configuration.transducer.element_pitch, ...
                configuration.transducer.element_width, configuration.transducer.focal_number_tx, ...
                configuration.transducer.focal_number_rx, configuration.transducer.n_lines, ...
                configuration.reproducibility.n_refs_target, configuration.reproducibility.n_refs_reference];
            if any(~isfinite(values)) || any(values <= 0)
                error('Los parámetros físicos, PPW, PML, profundidad y nRefs deben ser positivos.');
            end
            seedValues = [configuration.reproducibility.rng_seed, ...
                configuration.reproducibility.ref_seed_base];
            if any(~isfinite(seedValues)) || any(seedValues <= 0) || ...
                    any(seedValues ~= round(seedValues))
                error('Las semillas deben ser enteros positivos.');
            end
            if configuration.geometry.cfl <= 0 || configuration.geometry.cfl > 1
                error('CFL debe ser mayor que 0 y menor o igual que 1.');
            end
            if configuration.medium.hom_alpha < 0 || configuration.medium.density_std < 0
                error('La atenuación y su desviación estándar no pueden ser negativas.');
            end
            QUSConfigurationLogic.validateLateralScanCoverage( ...
                configuration.geometry.grid_size_y, configuration.transducer.source_focus, ...
                configuration.transducer.element_pitch, configuration.transducer.element_width, ...
                configuration.transducer.focal_number_rx, configuration.transducer.n_lines, ...
                'La configuración actual');
            MediumConfigurationLogic.validate(configuration.medium.config, ...
                1e3 * configuration.geometry.depth, 1e3 * configuration.geometry.grid_size_y);
            if isempty(strtrim(configuration.experiment.name))
                error('Escribe un nombre para el experimento antes de pulsar Set.');
            end
        end
        
        % Detecta los cambios en los valores y realiza los cambios
        function changes = detectChanges(reference, current)
            referenceRecords = QUSConfigurationLogic.records(reference);
            currentRecords = QUSConfigurationLogic.records(current);
            changes = struct('section', {}, 'parameter', {}, 'value', {}, 'reference', {});
            for index = 1:numel(currentRecords)
                if ismember(string(currentRecords(index).parameter), ...
                        ["Active Tx elements", "Receive elements", "Number of elements"])
                    continue
                end
                if ~QUSConfigurationLogic.valuesEqual(currentRecords(index).value, referenceRecords(index).value)
                    changes(end + 1) = struct('section', currentRecords(index).section, ...
                        'parameter', currentRecords(index).parameter, 'value', currentRecords(index).value, ...
                        'reference', referenceRecords(index).value);
                end
            end
        end

        function queue = addChange(queue, change)
            match = [];
            for index = 1:numel(queue)
                if strcmp(queue(index).section, change.section) && ...
                        strcmp(queue(index).parameter, change.parameter)
                    match = index;
                    break
                end
            end
            if isempty(match)
                queue(end + 1) = struct('section', change.section, 'parameter', change.parameter, ...
                    'values', change.value, 'reference', change.reference);
                return
            end
            existing = queue(match).values;
            for index = 1:numel(existing)
                if QUSConfigurationLogic.valuesEqual(existing(index), change.value)
                    return
                end
            end
            if ~QUSConfigurationLogic.valuesEqual(change.value, change.reference)
                queue(match).values(end + 1) = change.value;
            end
        end

        function updateExecution(app, state)
            lines = ["PLAN DE EXPERIMENTOS"; "================================================"];
            if ~state.referenceDefined
                app.TextArea.Value = cellstr([lines; ""; "SIN CONFIGURACIÓN"; ""; ...
                    "Pulsa Set para guardar la configuración de referencia."]);
                return
            end

            selectedIndex = QUSConfigurationLogic.selectedCaseIndex(app, state);
            [selectedConfiguration, selectedLabel] = ...
                QUSConfigurationLogic.configurationForSelectedCase(app, state, selectedIndex);
            lines = QUSConfigurationLogic.appendCaseSelector(lines, state, selectedIndex);

            if isempty(state.queue)
                lines = [lines; ""; "TIPO: (i) CONFIGURACIÓN ÚNICA"; ""; ...
                    "REFERENCIA"; "------------------------------------------------"];
                lines = QUSConfigurationLogic.appendReference(lines, state.reference);
                app.EstadoEditField.Value = 'Referencia definida';
            else
                sections = unique(string({state.queue.section}), 'stable');
                if isscalar(sections)
                    lines = [lines; ""; "TIPO: (ii) UNA SECCIÓN VARIABLE"];
                else
                    lines = [lines; ""; "TIPO: (iii) VARIAS SECCIONES VARIABLES"];
                end
                for sectionIndex = 1:numel(sections)
                    section = sections(sectionIndex);
                    lines = [lines; ""; "SIMULACIÓN " + sectionIndex; ...
                        "------------------------------------------------"; upper(section)];
                    for queueIndex = 1:numel(state.queue)
                        item = state.queue(queueIndex);
                        if strcmp(item.section, section)
                            lines(end + 1) = "  " + item.parameter + ": [" + ...
                                QUSConfigurationLogic.formatValuesForParameter(item.parameter, item.values) + ", REF=" + ...
                                QUSConfigurationLogic.formatValueForParameter(item.parameter, item.reference) + "]";
                        end
                    end
                end
            end

            lines = [lines; ""; "================================================"; ...
                "CONFIGURACIÓN SELECCIONADA: " + selectedLabel; ...
                "------------------------------------------------"];
            lines = QUSConfigurationLogic.appendReference(lines, selectedConfiguration);
            lines = QUSConfigurationLogic.appendMediumDetails(lines, selectedConfiguration.medium.config);
            lines = QUSConfigurationLogic.appendOutputDetails(lines, selectedConfiguration.output);
            app.TextArea.Value = cellstr(lines);
            if ~isempty(state.queue)
                app.EstadoEditField.Value = sprintf('Referencia + %d sección(es)', numel(sections));
            end
        end

        function updateStatusSummary(app, state, statusText)
            if isempty(statusText)
                if state.referenceDefined
                    if isempty(state.queue)
                        statusText = 'Referencia definida';
                    else
                        statusText = 'Listo para ejecutar';
                    end
                else
                    statusText = 'Sin configuración';
                end
            end

            app.EstadoEditField.Value = statusText;
            app.ModoEditField.Value = 'Local';

            if state.referenceDefined
                if isempty(state.queue)
                    app.ConfiguracinEditField.Value = 'Referencia definida';
                else
                    app.ConfiguracinEditField.Value = 'Referencia + cambios';
                end
            else
                app.ConfiguracinEditField.Value = 'Sin referencia';
            end

            app.CambiosencolaEditField.Value = num2str(numel(state.queue));
        end

        function refreshPreviewIfAvailable(app)
            PreviewLogic.refreshIfAvailable(app);
        end

        function refreshAssociatedViews(app)
            % Mantiene sincronizados nombre, ruta de salida, árbol y preview
            % después de cualquier acción que cambie la configuración.
            if isprop(app, 'Tree') && isprop(app, 'NombreEditField') && ...
                    isprop(app, 'RepositorioEditField') && ...
                    isprop(app, 'ExperimentoActualEditField') && ...
                    isprop(app, 'RutadesalidaEditField')
                ProjectExplorerLogic.updateCurrentExperiment(app);
                ProjectExplorerLogic.refreshTree(app);
            end
            QUSConfigurationLogic.refreshPreviewIfAvailable(app);
        end

        function lines = appendReference(lines, reference)
            items = QUSConfigurationLogic.records(reference);
            sections = unique(string({items.section}), 'stable');
            for sectionIndex = 1:numel(sections)
                section = sections(sectionIndex);
                lines = [lines; ""; upper(section)];
                for itemIndex = 1:numel(items)
                    item = items(itemIndex);
                    if strcmp(item.section, section)
                        lines(end + 1) = "  " + item.parameter + ': ' + ...
                            QUSConfigurationLogic.formatValueForParameter(item.parameter, item.value);
                    end
                end
            end
        end

        function lines = appendCaseSelector(lines, state, selectedIndex)
            caseCount = QUSConfigurationLogic.availableCaseCount(state);
            lines = [lines; ""; "CASOS GUARDADOS"];
            for index = 1:caseCount
                marker = "  ";
                if index == selectedIndex
                    marker = "→ ";
                end
                if index == 1
                    description = "configuración de referencia";
                else
                    description = "configuración guardada en la cola";
                end
                lines(end + 1) = marker + QUSConfigurationLogic.caseLabel(index) + ...
                    ": " + description;
            end
        end

        function [configuration, label] = configurationForSelectedCase(app, state, selectedIndex)
            label = QUSConfigurationLogic.caseLabel(selectedIndex);
            if isfield(state, 'previewCases') && ...
                    selectedIndex <= numel(state.previewCases)
                configuration = state.previewCases(selectedIndex).configuration;
                return
            end
            if isfield(state, 'pipelineCases') && ...
                    selectedIndex <= numel(state.pipelineCases)
                % applyPipelineCase ya materializa esta configuración al
                % seleccionar el elemento del menú. Se conserva aquí como
                % fallback para la referencia recién abierta.
                configuration = state.reference;
                return
            end
            configuration = state.reference;
        end

        function index = selectedCaseIndex(app, state)
            index = 1;
            if isprop(app, 'DropDown') && isvalid(app.DropDown)
                parsedIndex = QUSConfigurationLogic.groupIndex(app.DropDown.Value);
                if parsedIndex >= 1 && parsedIndex <= QUSConfigurationLogic.availableCaseCount(state)
                    index = parsedIndex;
                end
            end
        end

        function count = availableCaseCount(state)
            count = 1;
            if isfield(state, 'previewCases') && ~isempty(state.previewCases)
                count = numel(state.previewCases);
            elseif isfield(state, 'pipelineCases') && ~isempty(state.pipelineCases)
                count = numel(state.pipelineCases);
            end
        end

        function label = caseLabel(index)
            if index == 1
                label = "Ref";
            else
                label = "Case " + (index - 1);
            end
        end

        function lines = appendMediumDetails(lines, config)
            lines = [lines; ""; "DETALLE DEL MEDIO CONFIGURADO"; ...
                "  Tipo: " + string(config.kind)];
            switch config.kind
                case 'homogeneous'
                    lines(end + 1) = "  Sin inclusiones ni capas.";
                case {'single_circle', 'single_shape', 'multiple'}
                    inclusionCount = 1;
                    if strcmp(config.kind, 'multiple')
                        inclusionCount = numel(config.inclusions);
                    end
                    for index = 1:inclusionCount
                        item = config.inclusions(index);
                        lines = QUSConfigurationLogic.appendInclusionDetails(lines, ...
                            sprintf('Inclusión %d', index), item);
                    end
                case 'layers'
                    for index = 1:numel(config.layers)
                        layer = config.layers(index);
                        lines(end + 1) = "  Capa " + index + ": espesor [mm] = " + ...
                            QUSConfigurationLogic.formatValue(layer.thickness_mm);
                        lines = QUSConfigurationLogic.appendAcousticRegion(lines, ...
                            "    Propiedades", layer.acoustic);
                    end
            end
        end

        function lines = appendInclusionDetails(lines, label, item)
            lines(end + 1) = "  " + string(label) + ": forma = " + string(item.shape);
            lines(end + 1) = "    Centro x [mm] = " + ...
                QUSConfigurationLogic.formatValue(item.center_mm(1));
            if isnan(item.center_mm(2))
                lines(end + 1) = "    Centro z [mm] = automático (mitad de la profundidad)";
            else
                lines(end + 1) = "    Centro z [mm] = " + ...
                    QUSConfigurationLogic.formatValue(item.center_mm(2));
            end
            switch item.shape
                case 'circle'
                    lines(end + 1) = "    Radio [mm] = " + ...
                        QUSConfigurationLogic.formatValue(item.geometry_mm(1));
                case 'ellipse'
                    lines(end + 1) = "    Semieje lateral [mm] = " + ...
                        QUSConfigurationLogic.formatValue(item.geometry_mm(1));
                    lines(end + 1) = "    Semieje axial [mm] = " + ...
                        QUSConfigurationLogic.formatValue(item.geometry_mm(2));
                case 'irregular'
                    lines(end + 1) = "    Radio medio [mm] = " + ...
                        QUSConfigurationLogic.formatValue(item.geometry_mm(1));
                    lines(end + 1) = "    Perturbación = " + ...
                        QUSConfigurationLogic.formatValue(item.geometry_mm(2));
            end
            lines = QUSConfigurationLogic.appendAcousticRegion(lines, ...
                "    Propiedades", item.acoustic);
        end

        function lines = appendAcousticRegion(lines, label, region)
            lines(end + 1) = string(label) + ": c [m/s] = " + ...
                QUSConfigurationLogic.formatValue(region.sound_speed) + ...
                ", ρ [kg/m³] = " + QUSConfigurationLogic.formatValue(region.density) + ...
                ", ACS [dB/cm/MHz] = " + QUSConfigurationLogic.formatValue(region.acs) + ...
                ", σρ = " + QUSConfigurationLogic.formatValue(region.density_std);
        end

        function lines = appendOutputDetails(lines, output)
            lines = [lines; ""; "SALIDAS"; ...
                "  Guardar preview del medio = " + string(output.save_medium_previews); ...
                "  Guardar RF prebeamformed = " + string(output.save_rf_prebeamformed)];
        end
        
        %tiene que ver con la GUI
        function items = records(configuration)
            items = struct('section', {}, 'parameter', {}, 'value', {});
            add = @(section, parameter, value) struct('section', section, 'parameter', parameter, 'value', value);
            items(end + 1) = add('Geometría y malla', 'Tamaño axial [m]', configuration.geometry.grid_size_x);
            items(end + 1) = add('Geometría y malla', 'Tamaño lateral [m]', configuration.geometry.grid_size_y);
            items(end + 1) = add('Geometría y malla', 'PPW', configuration.geometry.ppw);
            items(end + 1) = add('Geometría y malla', 'PML axial', configuration.geometry.pml_size_x);
            items(end + 1) = add('Geometría y malla', 'PML lateral', configuration.geometry.pml_size_y);
            items(end + 1) = add('Geometría y malla', 'CFL', configuration.geometry.cfl);
            items(end + 1) = add('Geometría y malla', 'Profundidad [m]', configuration.geometry.depth);
            items(end + 1) = add('Medio acústico', 'Modelo', string(configuration.medium.model));
            items(end + 1) = add('Medio acústico', 'Velocidad de sonido [m/s]', configuration.medium.sound_speed);
            items(end + 1) = add('Medio acústico', 'Densidad [kg/m^3]', configuration.medium.density);
            items(end + 1) = add('Medio acústico', 'ACS [dB/cm/MHz]', configuration.medium.hom_alpha);
            items(end + 1) = add('Medio acústico', 'Desviación de densidad', configuration.medium.density_std);
            items(end + 1) = add('Medio acústico', 'Alpha power', configuration.medium.alpha_power);
            items(end + 1) = add('Medio acústico', 'Modo de absorción', string(configuration.medium.alpha_mode));
            items(end + 1) = add('Medio acústico', 'Velocidad de referencia [m/s]', configuration.medium.sound_speed_ref);
            items(end + 1) = add('Transductor emisor', 'Tipo', string(configuration.transducer.type));
            items(end + 1) = add('Transductor emisor', 'Señal', string(configuration.transducer.signal));
            items(end + 1) = add('Transductor emisor', 'Modo de haz', string(configuration.transducer.beam_mode));
            
            % Los valores permanecen en SI dentro de la configuración. Solo
            % se convierten al mostrarlos en el plan de experimentos.
            items(end + 1) = add('Transductor emisor', 'Frecuencia [MHz]', configuration.transducer.frequency);
            items(end + 1) = add('Transductor emisor', 'Amplitud [MPa]', configuration.transducer.amplitude);
            items(end + 1) = add('Transductor emisor', 'N.º ciclos', configuration.transducer.cycles);
            items(end + 1) = add('Transductor emisor', 'Focal depth [m]', configuration.transducer.source_focus);
            items(end + 1) = add('Transductor emisor', 'Pitch [m]', configuration.transducer.element_pitch);
            items(end + 1) = add('Transductor emisor', 'Element width [m]', configuration.transducer.element_width);
            items(end + 1) = add('Transductor emisor', 'Focal number Tx', configuration.transducer.focal_number_tx);
            items(end + 1) = add('Transductor emisor', 'Focal number Rx', configuration.transducer.focal_number_rx);
            activeTxElements = floor((configuration.transducer.source_focus / ...
                configuration.transducer.focal_number_tx) / configuration.transducer.element_pitch);
            receiveElements = floor((configuration.transducer.source_focus / ...
                configuration.transducer.focal_number_rx) / configuration.transducer.element_pitch);
            items(end + 1) = add('Transductor emisor', 'Active Tx elements', activeTxElements);
            items(end + 1) = add('Transductor emisor', 'Receive elements', receiveElements);
            items(end + 1) = add('Transductor emisor', 'Number of elements', receiveElements);
            items(end + 1) = add('Transductor emisor', 'Number of beams', configuration.transducer.n_lines);
            items(end + 1) = add('Posición', 'Axial translation [m]', configuration.transducer.base_translation_x);
            items(end + 1) = add('Posición', 'Lateral translation [m]', configuration.transducer.base_translation_y);
            items(end + 1) = add('Transductor emisor', 'Factor de directividad de recepción', ...
                configuration.transducer.receive_directivity_size_factor);
            items(end + 1) = add('Transductor emisor', 'Ángulo de directividad de recepción [rad]', ...
                configuration.transducer.receive_directivity_angle);
            items(end + 1) = add('Cálculo', 'DataCast', string(configuration.computation.data_cast));
            items(end + 1) = add('Cálculo', 'PlotSim', configuration.computation.plot_sim_flag);
            items(end + 1) = add('Cálculo', 'Solver', string(configuration.computation.solver));
            items(end + 1) = add('Reproducibilidad', 'Semilla global', configuration.reproducibility.rng_seed);
            items(end + 1) = add('Reproducibilidad', 'Semilla base de referencias', configuration.reproducibility.ref_seed_base);
            items(end + 1) = add('Reproducibilidad', 'nRefs de objetivos', configuration.reproducibility.n_refs_target);
            items(end + 1) = add('Reproducibilidad', 'nRefs de referencia', configuration.reproducibility.n_refs_reference);
        end

        function result = valuesEqual(first, second)
            if isnumeric(first) || islogical(first)
                result = isequaln(first, second);
            else
                result = strcmp(string(first), string(second));
            end
        end

        function text = formatValues(values)
            parts = strings(1, numel(values));
            for index = 1:numel(values)
                parts(index) = QUSConfigurationLogic.formatValue(values(index));
            end
            text = strjoin(parts, ', ');
        end

        function text = formatValuesForParameter(parameter, values)
            parts = strings(1, numel(values));
            for index = 1:numel(values)
                parts(index) = QUSConfigurationLogic.formatValueForParameter(parameter, values(index));
            end
            text = strjoin(parts, ', ');
        end
        
        % Las colas y los .mat siempre guardan SI. Esta función afecta
        % únicamente la presentación para que coincida con la GUI.
        function text = formatValueForParameter(parameter, value)
            switch string(parameter)
                case {"Frecuencia [MHz]", "Amplitud [MPa]"}
                    value = value / 1e6;
            end
            text = QUSConfigurationLogic.formatValue(value);
        end

        function text = formatValue(value)
            if islogical(value)
                text = string(value);
            elseif isnumeric(value)
                text = string(num2str(value, '%.8g'));
            else
                text = string(value);
            end
        end
        
        %Se genera cola vacia.
        function queue = emptyQueue()
            queue = struct('section', {}, 'parameter', {}, 'values', {}, 'reference', {});
        end
        
        function queue = normalizeQueueUnitLabels(queue)
            % Actualiza solo las etiquetas de archivos de configuración
            % previos. Sus valores siguen siendo Hz y Pa y no se modifican.
            for index = 1:numel(queue)
                switch string(queue(index).parameter)
                    case "Frecuencia [Hz]"
                        queue(index).parameter = 'Frecuencia [MHz]';
                    case "Amplitud [Pa]"
                        queue(index).parameter = 'Amplitud [MPa]';
                end
            end
        end
        
        %Algunas configuraciones mas avanzadas. 
        function advanced = advancedFromReference(reference)
            advanced.medium = struct('hom_alpha', reference.medium.hom_alpha, ...
                'density_std', reference.medium.density_std, 'alpha_power', reference.medium.alpha_power, ...
                'alpha_mode', reference.medium.alpha_mode, 'sound_speed_ref', reference.medium.sound_speed_ref);
            if isfield(reference.medium, 'config')
                advanced.medium.config = reference.medium.config;
            else
                advanced.medium.config = MediumConfigurationLogic.defaultConfig();
                advanced.medium.config.background.sound_speed = reference.medium.sound_speed;
                advanced.medium.config.background.density = reference.medium.density;
                advanced.medium.config.background.acs = reference.medium.hom_alpha;
                advanced.medium.config.background.density_std = reference.medium.density_std;
            end
            advanced.transducer = rmfield(reference.transducer, ...
                {'type', 'signal', 'beam_mode', 'frequency', 'amplitude', 'cycles'});
            if ~isfield(advanced.transducer, 'receive_directivity_size_factor')
                advanced.transducer.receive_directivity_size_factor = 10;
            end
            if ~isfield(advanced.transducer, 'receive_directivity_angle')
                advanced.transducer.receive_directivity_angle = 0;
            end
            if isfield(reference, 'sensor')
                if isfield(reference.sensor, 'directivity_size_factor')
                    advanced.transducer.receive_directivity_size_factor = ...
                        reference.sensor.directivity_size_factor;
                end
                if isfield(reference.sensor, 'directivity_angle')
                    advanced.transducer.receive_directivity_angle = ...
                        reference.sensor.directivity_angle;
                end
            end
            advanced.computation = struct('grid_size_y', reference.geometry.grid_size_y, ...
                'pml_size_y', reference.geometry.pml_size_y, ...
                'data_cast', reference.computation.data_cast, ...
                'plot_sim_flag', reference.computation.plot_sim_flag);
            advanced.reproducibility = reference.reproducibility;
            advanced.output = reference.output;
        end
        
        %Se aplican los cambios en la app de los valores cambiados
        function applyConfiguration(app, configuration)
            app.DimensionesEditField.Value = configuration.geometry.depth;
            app.GridSizeEditField.Value = QUSConfigurationLogic.formatGridSize( ...
                configuration.geometry.grid_size_x, configuration.geometry.grid_size_y);
            app.ResolucinEditField.Value = configuration.geometry.ppw;
            app.PMLCantcapasEditField.Value = configuration.geometry.pml_size_x;
            app.CFLEditField.Value = configuration.geometry.cfl;
            QUSConfigurationLogic.setDropDown(app.ModeloDropDown, configuration.medium.model);
            app.VelsonidoEditField.Value = configuration.medium.sound_speed;
            app.DensidadEditField.Value = configuration.medium.density;
            densityStdField = QUSConfigurationLogic.densityStdControl(app);
            densityStdField.Value = configuration.medium.density_std;
            QUSConfigurationLogic.updateCalculatedTime(app);
            QUSConfigurationLogic.setDropDown(app.TipoDropDown, configuration.transducer.type);
            QUSConfigurationLogic.setDropDown(app.SealDropDown, configuration.transducer.signal);
            QUSConfigurationLogic.setDropDown(app.MododehazDropDown, configuration.transducer.beam_mode);
            % Configuraciones existentes se guardaron en Hz y Pa. Convertir
            % únicamente al cargarlas en los campos de la interfaz.
            app.FrecuenciaEditField.Value = configuration.transducer.frequency / 1e6;
            app.AmplitudEditField_2.Value = configuration.transducer.amplitude / 1e6;
            app.NciclosEditField.Value = configuration.transducer.cycles;
            QUSConfigurationLogic.setDropDown(app.SolverDropDown, configuration.computation.solver);
            app.NombreEditField.Value = configuration.experiment.name;
            QUSConfigurationLogic.configureRealizationControls(app, configuration.reproducibility);
            state = QUSConfigurationLogic.stateIfAvailable(app);
            if ~isempty(state)
                state.advanced.computation.data_cast = configuration.computation.data_cast;
                state.advanced.computation.plot_sim_flag = configuration.computation.plot_sim_flag;
                state.advanced.reproducibility = configuration.reproducibility;
                QUSConfigurationLogic.configurePipelineSummaryControls(app, state.advanced);
            end
        end

        % Traduce la estructura de la GUI a los nombres del pipeline
        % original. Esto hace que el archivo MAT sea auditable por sí
        % mismo y evita números literales dispersos en el .m generado.
        function parameters = pipelineParametersFromConfiguration(configuration)
            parameters = struct( ...
                'c0', configuration.medium.sound_speed, ...
                'rho0', configuration.medium.density, ...
                'hom_alpha', configuration.medium.hom_alpha, ...
                'density_std', configuration.medium.density_std, ...
                'alpha_power', configuration.medium.alpha_power, ...
                'alpha_mode', configuration.medium.alpha_mode, ...
                'sound_speed_ref', configuration.medium.sound_speed_ref, ...
                'source_f0', configuration.transducer.frequency, ...
                'source_amp', configuration.transducer.amplitude, ...
                'source_cycles', configuration.transducer.cycles, ...
                'source_focus', configuration.transducer.source_focus, ...
                'element_pitch', configuration.transducer.element_pitch, ...
                'element_width', configuration.transducer.element_width, ...
                'focal_number_Tx', configuration.transducer.focal_number_tx, ...
                'focal_number_Rx', configuration.transducer.focal_number_rx, ...
                'nLines', configuration.transducer.n_lines, ...
                'grid_size_x', configuration.geometry.grid_size_x, ...
                'grid_size_y', configuration.geometry.grid_size_y, ...
                'PMLSize', [configuration.geometry.pml_size_x, configuration.geometry.pml_size_y], ...
                'ppw', configuration.geometry.ppw, ...
                'depth', configuration.geometry.depth, ...
                'cfl', configuration.geometry.cfl, ...
                'base_translation', [configuration.transducer.base_translation_x, ...
                    configuration.transducer.base_translation_y], ...
                'rotation', configuration.transducer.rotation, ...
                'DATA_CAST', configuration.computation.data_cast, ...
                'plotSimFlag', configuration.computation.plot_sim_flag, ...
                'solverName', configuration.computation.solver, ...
                'directivity_size_factor', configuration.transducer.receive_directivity_size_factor, ...
                'directivity_angle', configuration.transducer.receive_directivity_angle, ...
                'nRefsTarget', configuration.reproducibility.n_refs_target, ...
                'nRefsReference', configuration.reproducibility.n_refs_reference, ...
                'refSeedBase', configuration.reproducibility.ref_seed_base, ...
                'saveMediumPreviews', configuration.output.save_medium_previews, ...
                'saveRfPrebeamformed', configuration.output.save_rf_prebeamformed);
        end

        function axialTranslation = surfaceAlignedAxialTranslation(c0, ppw, frequency, gridSizeX)
            % El k-WaveGrid usa un eje axial centrado. Esta traslación coloca
            % su primera muestra en la superficie física z = 0, de modo que
            % la geometría configurada y los mapas guardados comparten origen.
            dx = c0 / (ppw * frequency);
            nx = 2 * round((gridSizeX / dx) / 2);
            axialTranslation = -floor(nx / 2) * dx;
        end

        function setDropDown(control, value)
            value = char(string(value));
            if any(strcmp(control.Items, value))
                control.Value = value;
            end
        end

        function [value, isValid] = editableDropDownInteger(control)
            value = str2double(strtrim(char(string(control.Value))));
            isValid = isscalar(value) && isfinite(value) && value > 0 && ...
                value == round(value);
            if isValid
                value = round(value);
            end
        end

        function parametersByCase = readPipelineCases(pipelinePath)
            if ~isfile(pipelinePath)
                error('No se encontró el pipeline: %s.', pipelinePath);
            end

            parametersByCase = QUSConfigurationLogic.readPipelineCaseMetadata(pipelinePath);
            if ~isempty(parametersByCase)
                for caseIndex = 1:numel(parametersByCase)
                    QUSConfigurationLogic.validatePipelineCaseParameters( ...
                        parametersByCase(caseIndex), caseIndex);
                end
                return
            end

            % Compatibilidad con los pipelines ya guardados por la versión
            % anterior, que eran funciones. Los scripts nuevos no pasan por
            % esta ruta y nunca se ejecutan al abrirlos desde la GUI.
            [pipelineFolder, pipelineFunctionName] = fileparts(pipelinePath);
            if ~isvarname(pipelineFunctionName)
                error(['El script no contiene metadatos de casos de la GUI y su nombre ' ...
                    'no permite abrirlo como pipeline legado.']);
            end

            addpath(pipelineFolder, '-begin');
            cleanup = onCleanup(@() rmpath(pipelineFolder));
            eval("clear " + string(pipelineFunctionName));
            parametersByCase = feval(pipelineFunctionName, 'gui_cases');
            if ~isstruct(parametersByCase) || isempty(parametersByCase)
                error(['El pipeline no devolvió casos válidos. Selecciona un .m guardado ' ...
                    'por esta versión de la aplicación.']);
            end
            for caseIndex = 1:numel(parametersByCase)
                QUSConfigurationLogic.validatePipelineCaseParameters(parametersByCase(caseIndex), caseIndex);
            end
            clear cleanup
        end

        function parametersByCase = readPipelineCaseMetadata(pipelinePath)
            prefix = '% QUS_GUI_CASE_JSON ';
            sourceLines = splitlines(string(fileread(pipelinePath)));
            payloadLines = sourceLines(startsWith(strtrim(sourceLines), prefix));
            if isempty(payloadLines)
                parametersByCase = struct([]);
                return
            end

            parametersByCase = struct([]);
            for caseIndex = 1:numel(payloadLines)
                payload = extractAfter(strtrim(payloadLines(caseIndex)), strlength(prefix));
                try
                    values = jsondecode(char(payload));
                catch exception
                    error('No se pudo leer el metadato del %s: %s.', ...
                        QUSConfigurationLogic.caseLabel(caseIndex), exception.message);
                end
                values = QUSConfigurationLogic.unwrapPipelineMetadata(values);
                normalized = QUSConfigurationLogic.normalizeMetadataCase(values);
                if caseIndex == 1
                    parametersByCase = normalized;
                else
                    parametersByCase(end + 1) = normalized;
                end
            end
        end

        function parameters = normalizeMetadataCase(parameters)
            % jsondecode devuelve algunos textos como char y otros como
            % celdas según su tamaño. Normalizar conserva el contrato del
            % lector de configuraciones y del generador de medios.
            textFields = {'DATA_CAST', 'alpha_mode', 'simuName', 'mediumModel', ...
                'transducerType', 'transducerSignal', 'transducerBeamMode', 'solverName'};
            for fieldIndex = 1:numel(textFields)
                fieldName = textFields{fieldIndex};
                if isfield(parameters, fieldName)
                    parameters.(fieldName) = char(string(parameters.(fieldName)));
                end
            end
            if isfield(parameters, 'inclusionShape')
                shapes = parameters.inclusionShape;
                if ischar(shapes) || isstring(shapes)
                    shapes = cellstr(string(shapes));
                elseif ~iscell(shapes)
                    shapes = cellstr(string(shapes));
                end
                parameters.inclusionShape = reshape(shapes, 1, []);
            end
            rowFields = {'inclusionAlpha', 'layerThicknessMm', 'layerAlpha'};
            for fieldIndex = 1:numel(rowFields)
                fieldName = rowFields{fieldIndex};
                if isfield(parameters, fieldName)
                    parameters.(fieldName) = reshape(double(parameters.(fieldName)), 1, []);
                end
            end
            matrixFields = {'inclusionCenterMm', 'inclusionGeometryMm'};
            for fieldIndex = 1:numel(matrixFields)
                fieldName = matrixFields{fieldIndex};
                if isfield(parameters, fieldName)
                    values = double(parameters.(fieldName));
                    if isvector(values) && numel(values) == 2
                        values = reshape(values, 1, 2);
                    end
                    parameters.(fieldName) = values;
                end
            end
        end

        function values = unwrapPipelineMetadata(values)
            % Versión 2 separa el contenedor del caso para poder añadir
            % trazabilidad sin romper Open Config. La versión 1 plana sigue
            % siendo legible para los pipelines existentes.
            if isstruct(values) && isfield(values, 'schema_version') && ...
                    isfield(values, 'case')
                if ~isscalar(values.schema_version) || values.schema_version ~= 2 || ...
                        ~isstruct(values.case)
                    error('El contenedor JSON de la GUI no tiene un esquema válido.');
                end
                values = values.case;
            end
        end

        function state = applyPipelineCase(app, state, caseIndex)
            parameters = state.pipelineCases(caseIndex);
            [configuration, advanced] = QUSConfigurationLogic.configurationFromPipelineParameters( ...
                app, state.advanced, parameters);
            state.referenceDefined = true;
            state.reference = configuration;
            state.advanced = advanced;
            state.selectedPipelineCase = caseIndex;
            QUSConfigurationLogic.applyConfiguration(app, configuration);
        end

        function state = recordPreviewCase(app, state, configuration)
            % Set conserva una instantánea completa para que Group restaure
            % exactamente lo que quedó en cola, incluido el medio avanzado.
            if ~isfield(state, 'previewCases') || isempty(state.previewCases)
                state.previewCases = struct('configuration', configuration);
            else
                state.previewCases(end + 1) = struct('configuration', configuration);
            end
            QUSConfigurationLogic.configureGroupSelector(app, ...
                numel(state.previewCases), numel(state.previewCases));
        end

        function queue = rebuildQueueFromPreviewCases(state)
            % La cola se deriva de las instantáneas restantes para que al
            % borrar un Case desaparezcan también sus valores del plan.
            queue = QUSConfigurationLogic.emptyQueue();
            for caseIndex = 2:numel(state.previewCases)
                current = state.previewCases(caseIndex).configuration;
                changes = QUSConfigurationLogic.detectChanges(state.reference, current);
                for changeIndex = 1:numel(changes)
                    queue = QUSConfigurationLogic.addChange(queue, changes(changeIndex));
                end
            end
        end

        function configureDeleteButton(app, state)
            if ~isprop(app, 'PruebaButton') || ~isvalid(app.PruebaButton)
                return
            end
            app.PruebaButton.Text = 'Delete';
            app.PruebaButton.ButtonPushedFcn = @(~, ~) ...
                QUSConfigurationLogic.onDeleteSelectedCase(app);
            selectedIndex = QUSConfigurationLogic.selectedCaseIndex(app, state);
            hasDeletableCase = selectedIndex > 1 && ...
                QUSConfigurationLogic.availableCaseCount(state) >= selectedIndex;
            if hasDeletableCase
                app.PruebaButton.Enable = 'on';
            else
                app.PruebaButton.Enable = 'off';
            end
        end

        function parametersByCase = referenceFirst(parametersByCase)
            referenceIndex = find([parametersByCase.isReference], 1, 'first');
            if isempty(referenceIndex)
                error('El pipeline abierto no contiene una configuración de referencia.');
            end
            otherIndexes = setdiff(1:numel(parametersByCase), referenceIndex, 'stable');
            parametersByCase = parametersByCase([referenceIndex, otherIndexes]);
        end

        function [configuration, advanced] = configurationFromPipelineParameters(app, advanced, parameters)
            configuration = QUSConfigurationLogic.readCurrentConfiguration(app, advanced);
            pmlSize = double(parameters.PMLSize(:).');
            if numel(pmlSize) ~= 2 || any(~isfinite(pmlSize)) || any(pmlSize <= 0)
                error('El parámetro PMLSize del pipeline debe contener dos valores positivos.');
            end

            advanced.medium.hom_alpha = parameters.hom_alpha;
            advanced.medium.density_std = parameters.density_std;
            advanced.medium.alpha_power = parameters.alpha_power;
            advanced.medium.alpha_mode = char(string(parameters.alpha_mode));
            advanced.medium.sound_speed_ref = parameters.sound_speed_ref;
            advanced.medium.config = QUSConfigurationLogic.mediumConfigFromPipelineParameters( ...
                parameters, advanced.medium);
            advanced.transducer.source_focus = parameters.source_focus;
            advanced.transducer.element_pitch = parameters.element_pitch;
            advanced.transducer.element_width = parameters.element_width;
            advanced.transducer.focal_number_tx = parameters.focal_number_Tx;
            advanced.transducer.focal_number_rx = parameters.focal_number_Rx;
            advanced.transducer.n_lines = parameters.nLines;
            advanced.transducer.base_translation_x = parameters.base_translation(1);
            advanced.transducer.base_translation_y = parameters.base_translation(2);
            advanced.transducer.rotation = parameters.rotation;
            advanced.computation.grid_size_y = parameters.grid_size_y;
            advanced.computation.pml_size_y = pmlSize(2);
            advanced.computation.data_cast = char(string(parameters.DATA_CAST));
            advanced.computation.plot_sim_flag = logical(parameters.plotSimFlag);
            advanced.reproducibility.ref_seed_base = parameters.refSeedBase;
            if parameters.isReference
                advanced.reproducibility.n_refs_reference = parameters.nRefs;
            else
                advanced.reproducibility.n_refs_target = parameters.nRefs;
            end
            advanced.output.save_medium_previews = logical(parameters.saveMediumPreviews);
            advanced.output.save_rf_prebeamformed = logical(parameters.saveRfPrebeamformed);
            advanced.transducer.receive_directivity_size_factor = parameters.directivity_size_factor;
            advanced.transducer.receive_directivity_angle = parameters.directivity_angle;

            configuration.geometry.grid_size_x = parameters.grid_size_x;
            configuration.geometry.grid_size_y = parameters.grid_size_y;
            configuration.geometry.ppw = parameters.ppw;
            configuration.geometry.pml_size_x = pmlSize(1);
            configuration.geometry.pml_size_y = pmlSize(2);
            configuration.geometry.cfl = parameters.cfl;
            configuration.geometry.depth = parameters.depth;
            configuration.medium.model = char(string(parameters.mediumModel));
            configuration.medium.sound_speed = parameters.c0;
            configuration.medium.density = parameters.rho0;
            configuration.medium.hom_alpha = parameters.hom_alpha;
            configuration.medium.density_std = parameters.density_std;
            configuration.medium.alpha_power = parameters.alpha_power;
            configuration.medium.alpha_mode = char(string(parameters.alpha_mode));
            configuration.medium.sound_speed_ref = parameters.sound_speed_ref;
            configuration.transducer.frequency = parameters.source_f0;
            configuration.transducer.amplitude = parameters.source_amp;
            configuration.transducer.cycles = parameters.source_cycles;
            configuration.transducer.type = char(string(parameters.transducerType));
            configuration.transducer.signal = char(string(parameters.transducerSignal));
            configuration.transducer.beam_mode = char(string(parameters.transducerBeamMode));
            configuration.transducer.source_focus = parameters.source_focus;
            configuration.transducer.element_pitch = parameters.element_pitch;
            configuration.transducer.element_width = parameters.element_width;
            configuration.transducer.focal_number_tx = parameters.focal_number_Tx;
            configuration.transducer.focal_number_rx = parameters.focal_number_Rx;
            configuration.transducer.n_lines = parameters.nLines;
            configuration.transducer.base_translation_x = parameters.base_translation(1);
            configuration.transducer.base_translation_y = parameters.base_translation(2);
            configuration.transducer.rotation = parameters.rotation;
            configuration.transducer.receive_directivity_size_factor = parameters.directivity_size_factor;
            configuration.transducer.receive_directivity_angle = parameters.directivity_angle;
            configuration.computation.data_cast = char(string(parameters.DATA_CAST));
            configuration.computation.plot_sim_flag = logical(parameters.plotSimFlag);
            configuration.computation.solver = char(string(parameters.solverName));
            advanced.reproducibility.rng_seed = parameters.rngSeed;
            configuration.reproducibility = advanced.reproducibility;
            configuration.output = advanced.output;
            configuration.experiment.name = char(string(parameters.simuName));
        end

        function config = mediumConfigFromPipelineParameters(parameters, mediumSettings)
            if isfield(mediumSettings, 'config')
                config = mediumSettings.config;
            else
                config = MediumConfigurationLogic.defaultConfig();
            end
            config = MediumConfigurationLogic.forModel(config, parameters.mediumModel);
            config.background = struct('sound_speed', parameters.c0, ...
                'density', parameters.rho0, 'acs', parameters.hom_alpha, ...
                'density_std', parameters.density_std);
            config.alpha_power = parameters.alpha_power;
            config.alpha_mode = char(string(parameters.alpha_mode));
            config.sound_speed_ref = parameters.sound_speed_ref;
            inclusionFields = {'inclusionShape', 'inclusionCenterMm', ...
                'inclusionGeometryMm', 'inclusionAlpha'};
            if all(isfield(parameters, inclusionFields))
                count = numel(parameters.inclusionAlpha);
                prototype = config.inclusions(1);
                inclusions = repmat(prototype, 1, count);
                for index = 1:count
                    inclusions(index).shape = char(string(parameters.inclusionShape{index}));
                    inclusions(index).center_mm = parameters.inclusionCenterMm(index, :);
                    inclusions(index).geometry_mm = parameters.inclusionGeometryMm(index, :);
                    inclusions(index).acoustic = struct( ...
                        'sound_speed', parameters.c0, ...
                        'density', parameters.rho0, ...
                        'acs', parameters.inclusionAlpha(index), ...
                        'density_std', parameters.density_std);
                end
                config.inclusions = inclusions;
            end
            layerFields = {'layerThicknessMm', 'layerAlpha'};
            if all(isfield(parameters, layerFields)) && ~isempty(parameters.layerAlpha)
                count = numel(parameters.layerAlpha);
                layers = repmat(struct('thickness_mm', 0, 'acoustic', config.background), 1, count);
                for index = 1:count
                    layers(index).thickness_mm = parameters.layerThicknessMm(index);
                    layers(index).acoustic = struct( ...
                        'sound_speed', parameters.c0, ...
                        'density', parameters.rho0, ...
                        'acs', parameters.layerAlpha(index), ...
                        'density_std', parameters.density_std);
                end
                config.layers = layers;
            end
        end

        function validatePipelineCaseParameters(parameters, caseIndex)
            required = {'isReference', 'nRefs', 'refSeedBase', 'c0', 'rho0', 'hom_alpha', ...
                'density_std', 'simuName', 'source_f0', 'source_amp', 'source_cycles', ...
                'source_focus', 'element_pitch', 'element_width', 'focal_number_Tx', ...
                'focal_number_Rx', 'nLines', 'grid_size_x', 'grid_size_y', ...
                'base_translation', 'rotation', 'DATA_CAST', 'ppw', 'depth', 'cfl', ...
                'PMLSize', 'plotSimFlag', 'alpha_power', 'alpha_mode', ...
                'sound_speed_ref', 'saveMediumPreviews', 'saveRfPrebeamformed', ...
                'directivity_size_factor', 'directivity_angle', 'solverName', 'rngSeed', 'mediumModel', ...
                'transducerType', 'transducerSignal', 'transducerBeamMode'};
            missing = required(~isfield(parameters, required));
            if ~isempty(missing)
                error('%s no tiene: %s.', QUSConfigurationLogic.caseLabel(caseIndex), ...
                    strjoin(missing, ', '));
            end
            numericValues = [parameters.nRefs, parameters.c0, parameters.rho0, ...
                parameters.source_f0, parameters.source_amp, parameters.source_cycles, ...
                parameters.source_focus, parameters.element_pitch, parameters.element_width, ...
                parameters.focal_number_Tx, parameters.focal_number_Rx, parameters.nLines, ...
                parameters.grid_size_x, parameters.grid_size_y, parameters.ppw, ...
                parameters.depth, parameters.cfl, parameters.alpha_power, parameters.sound_speed_ref];
            if any(~isfinite(numericValues)) || any(numericValues <= 0) || ...
                    numel(parameters.base_translation) ~= 2
                error('%s contiene parámetros físicos inválidos.', ...
                    QUSConfigurationLogic.caseLabel(caseIndex));
            end
        end

        function validateLateralScanCoverage(gridSizeY, sourceFocus, pitch, elementWidth, fNumberRx, nLines, context)
            % Verifica que cada arreglo Rx desplazado quede íntegro dentro
            % de la malla física. La banda de imagen sigue siendo
            % (nLines - 1)*pitch; la malla sólo debe contener además la
            % apertura Rx de sus líneas extremas.
            % Sin esto k-Wave recorta esas líneas y el B-mode adquiere
            % bandas negras laterales.
            receiveElements = floor(sourceFocus / fNumberRx / pitch);
            if receiveElements < 1
                error('%s: Focal number Rx genera menos de un elemento de recepción.', context);
            end
            receiveWidth = (receiveElements - 1) * pitch + elementWidth;
            requiredWidth = (nLines - 1) * pitch + receiveWidth;
            if gridSizeY + eps(max(gridSizeY, requiredWidth)) < requiredWidth
                maximumLines = max(0, floor((gridSizeY - receiveWidth) / pitch) + 1);
                error(["%s requiere una malla lateral de al menos %.3f mm para %d líneas " + ...
                    "(Rx: %d elementos, %.3f mm). El valor actual es %.3f mm y sólo admite %d líneas. " + ...
                    "Aumenta Tamaño lateral o reduce Number of beams antes de ejecutar k-Wave."], ...
                    context, 1e3 * requiredWidth, nLines, receiveElements, 1e3 * receiveWidth, ...
                    1e3 * gridSizeY, maximumLines);
            end
        end

        function configureGroupSelector(app, groupCount, selectedIndex)
            if ~isprop(app, 'DropDown') || ~isvalid(app.DropDown)
                return
            end
            items = cell(1, groupCount);
            for index = 1:groupCount
                items{index} = char(QUSConfigurationLogic.caseLabel(index));
            end
            app.DropDown.Items = items;
            app.DropDown.Value = items{selectedIndex};
            app.DropDown.Enable = 'on';
        end

        function index = groupIndex(groupName)
            groupName = string(groupName);
            if strcmpi(groupName, "Ref")
                index = 1;
                return
            end
            tokens = regexp(char(groupName), '^Case\s+(\d+)$', 'tokens', 'once');
            if isempty(tokens), index = 0; else, index = str2double(tokens{1}) + 1; end
        end

        function [gridSizeX, gridSizeY] = parseGridSize(value)
            tokens = regexp(strtrim(char(string(value))), '^\(\s*([^,]+)\s*,\s*([^\)]+)\s*\)$', ...
                'tokens', 'once');
            if isempty(tokens)
                error('Grid Size debe tener el formato (x,y) en metros, por ejemplo (0.056,0.04).');
            end
            gridSizeX = str2double(tokens{1});
            gridSizeY = str2double(tokens{2});
            if ~isfinite(gridSizeX) || ~isfinite(gridSizeY) || gridSizeX <= 0 || gridSizeY <= 0
                error('Los dos valores de Grid Size deben ser números positivos en metros.');
            end
        end

        function text = formatGridSize(gridSizeX, gridSizeY)
            text = sprintf('(%.12g,%.12g)', gridSizeX, gridSizeY);
        end

        % El pipeline .m es un script autocontenido, igual que el baseline.
        % Los casos que la GUI necesita para reabrirlo se guardan como
        % metadatos comentados al final; nunca convierten el pipeline en una
        % función ni afectan su ejecución en MATLAB o en el cluster.
        function writePipelineScript(pipelinePath, state)

            reference = state.reference;
            if isfield(state, 'previewCases') && ~isempty(state.previewCases)
                % Set guarda una instantánea completa por Case, incluido el
                % medio avanzado. Usarla evita reconstruir una inclusión o
                % capa con los valores de otro Case al generar el pipeline.
                cases = QUSConfigurationLogic.materializePreviewCases(state.previewCases);
            else
                cases = QUSConfigurationLogic.materializeExperimentCases(reference, state.queue);
            end
            isAlphaSweep = ~isempty(cases) && all([cases.isAlphaSweep]);
            lines = [ ...
                "%% Homogeneous reference simulations"; "clc"; ""; ...
                "scriptFolder = fileparts(mfilename('fullpath'));"; ...
                "if isempty(scriptFolder), scriptFolder = pwd; end;"; ...
                "cd(scriptFolder);"; ...
                "%% Reproducibility"; ...
                "rng(" + QUSConfigurationLogic.matlabLiteral(reference.reproducibility.rng_seed) + ")"; ...
                "addpath(genpath(scriptFolder))"; ""; ...
                "%% Output setup"];
            if isAlphaSweep
                alphaValues = arrayfun(@(item) item.configuration.medium.hom_alpha, cases);
                lines = [lines; ...
                    "% Reference is intentionally the final value, as in the baseline."; ...
                    "refValues = " + QUSConfigurationLogic.matlabLiteral(alphaValues) + ";"; ...
                    "for ii = 1:length(refValues)"];
                refValuesArgument = "refValues";
            else
                lines = [lines; "for ii = 1:" + num2str(numel(cases))];
                refValuesArgument = "[]";
            end
            lines = [lines; ...
                "    % Values are stored in the local function at the end of this file."; ...
                "    parameters = getGuiCaseParameters(ii, " + refValuesArgument + ");"; ""; ...
                "    nRefs = parameters.nRefs;"; ...
                "    refSeedBase = parameters.refSeedBase;"; ...
                "    saveMediumPreviews = parameters.saveMediumPreviews;"; ...
                "    saveRfPrebeamformed = parameters.saveRfPrebeamformed;"; ""; ...
                "    %% Medium parameters"; ...
                "    c0 = parameters.c0;"; ...
                "    rho0 = parameters.rho0;"; ...
                "    hom_alpha = parameters.hom_alpha;"; ...
                "    density_std = parameters.density_std;"; ...
                "    alpha_power = parameters.alpha_power;"; ...
                "    alpha_mode = parameters.alpha_mode;"; ...
                "    sound_speed_ref = parameters.sound_speed_ref;"; ...
                "    simuName = parameters.simuName;"; ""; ...
                "    outputFolder = fullfile(scriptFolder, 'out', simuName);"; ...
                "    if ~exist(outputFolder, 'dir')"; "        mkdir(outputFolder);"; "    end"; ""; ...
                "    %% Source parameters"; ""; ...
                "    source_f0 = parameters.source_f0;"; ...
                "    source_amp = parameters.source_amp;"; ...
                "    source_cycles = parameters.source_cycles;"; ...
                "    source_focus = parameters.source_focus;"; ...
                "    element_pitch = parameters.element_pitch;"; ...
                "    element_width = parameters.element_width;"; ...
                "    focal_number_Tx = parameters.focal_number_Tx;"; ...
                "    focal_number_Rx = parameters.focal_number_Rx;"; ...
                "    nLines = parameters.nLines;"; ""; ...
                "    %% Grid parameters"; ""; ...
                "    grid_size_x = parameters.grid_size_x;"; ...
                "    grid_size_y = parameters.grid_size_y;"; ""; ...
                "    %% Transducer position"; ""; ...
                "    base_translation = parameters.base_translation;"; ...
                "    rotation = parameters.rotation;"; ""; ...
                "    %% Computational parameters"; ""; ...
                "    DATA_CAST = parameters.DATA_CAST;"; ...
                "    ppw = parameters.ppw;"; ...
                "    depth = parameters.depth;"; ...
                "    cfl = parameters.cfl;"; ...
                "    PMLSize = parameters.PMLSize;"; ...
                "    plotSimFlag = parameters.plotSimFlag;"; ...
                "    solverName = parameters.solverName;"; ...
                "    if strcmpi(DATA_CAST, 'gpuArray-single')"; ...
                "        try"; ...
                "            parallel.gpu.enableCUDAForwardCompatibility(true);"; ...
                "        catch exception"; ...
                "            warning('QUS:GPUCompatibility', ..."; ...
                "                'No se pudo habilitar CUDA forward compatibility: %s', exception.message);"; ...
                "        end"; ...
                "    end"; ...
                "    %% Grid"; ""; ...
                "    % Calculate the grid spacing based on the PPW and F0"; ...
                "    dx = c0 / (ppw * source_f0);                                  % [m]"; ""; ...
                "    % Compute the size of the grid"; ...
                "    Nx = roundEven(grid_size_x / dx);"; ...
                "    Ny = roundEven(grid_size_y / dx);"; ""; ...
                "    base_translation(1) = -floor(Nx / 2) * dx; % Sitúa la superficie emisora en z = 0."; ""; ...
                "    % Create the computational grid"; ...
                "    kgrid = kWaveGrid(Nx, dx, Ny, dx);"; ""; ...
                "    % Create the time array"; ...
                "    t_end = depth * 2 / c0;                                        % [s]"; ...
                "    kgrid.makeTime(c0, cfl, t_end);"; ""; ...
                "    %% Source / array setup"; ""; ...
                "    aperture_Rx = source_focus / focal_number_Rx;"; ...
                "    aperture_Tx = source_focus / focal_number_Tx;"; ""; ...
                "    element_num_Tx = floor(aperture_Tx / element_pitch);"; ...
                "    element_num = floor(aperture_Rx / element_pitch);"; ""; ...
                "    amp_vector = source_amp * ones(element_num, 1);"; ""; ...
                "    inactive_Tx_elements = element_num - element_num_Tx;"; ...
                "    left_inactive_Tx = floor(inactive_Tx_elements / 2);"; ...
                "    right_inactive_Tx = ceil(inactive_Tx_elements / 2);"; ...
                "    if left_inactive_Tx > 0"; ...
                "        amp_vector(1:left_inactive_Tx) = 0;"; ...
                "    end"; ...
                "    if right_inactive_Tx > 0"; ...
                "        amp_vector(end-right_inactive_Tx+1:end) = 0;"; ...
                "    end"; ""; ...
                "    % Set indices for each element"; ...
                "    ids = (0:element_num-1) - (element_num-1)/2;"; ""; ...
                "    % Set time delays for each element to focus at source_focus"; ...
                "    time_delays = -(sqrt((ids .* element_pitch).^2 + source_focus.^2) - source_focus) ./ c0;"; ...
                "    time_delays = time_delays - min(time_delays);"; ""; ...
                "    % Create time-varying source signals"; ...
                "    source_sig = amp_vector .* toneBurst(1/kgrid.dt, source_f0, ..."; ...
                "        source_cycles, 'SignalOffset', round(time_delays / kgrid.dt));"; ""; ...
                "    % Create empty kWaveArray"; ...
                "    karray = kWaveArray('BLITolerance', 0.05, 'UpsamplingRate', 10);"; ""; ...
                "    % Add rectangular elements"; ...
                "    for ind = 1:element_num"; ...
                "        y_pos = 0 - (element_num * element_pitch/2 - element_pitch/2) ..."; ...
                "            + (ind-1) * element_pitch;"; ...
                "        karray.addRectElement([0, y_pos], element_width/4, element_width, rotation);"; ...
                "    end"; ""; ...
                "    %% Scanline coordinates"; ...
                "    yCords = ((0:nLines-1) - (nLines-1)/2) * element_pitch;"; ...
                "    assertLateralScanCoverage(grid_size_y, source_focus, element_pitch, element_width, ..."; ...
                "        focal_number_Rx, nLines, simuName); % Impide arreglos truncados en líneas extremas."; ""; ...
                "    %% Input options for k-Wave"; ...
                "    input_args = {..."; ...
                "        'PMLInside', false, ..."; ...
                "        'PMLSize', PMLSize, ..."; ...
                "        'DataCast', DATA_CAST, ..."; ...
                "        'DataRecast', true, ..."; ...
                "        'PlotSim', plotSimFlag};"; ""; ...
                "    %% Reference simulation loop"; ""; ...
                "    manifest = struct([]);"; ""; ...
                "    for iRef = 1:nRefs"; ""; ...
                "        refSeed = refSeedBase + iRef;"; ...
                "        rng(refSeed);"; ""; ...
                "        fprintf('\\n========================================\\n');"; ...
                "        fprintf('Running homogeneous reference %d of %d\\n', iRef, nRefs);"; ...
                "        fprintf('Seed: %d\\n', refSeed);"; ...
                "        fprintf('========================================\\n');"; ""; ...
                "        %% Acoustic medium"; ""; ...
                "        if strcmpi(parameters.mediumModel, 'Homogeneo')"; ...
                "            medium = makeHomogeneousDensityOnlyMedium( ..."; ...
                "                Nx, Ny, c0, rho0, density_std, hom_alpha);"; ...
                "        elseif strcmpi(parameters.mediumModel, 'Inclusión circular')"; ...
                "            medium = makeCircularInclusion(Nx, Ny, dx, base_translation(1), ..."; ...
                "                c0, rho0, density_std, hom_alpha, parameters.inclusionCenterMm, ..."; ...
                "                parameters.inclusionGeometryMm, parameters.inclusionAlpha);"; ...
                "        elseif any(strcmpi(parameters.mediumModel, {'Inclusión irregular', 'Inclusión elipsoidal'}))"; ...
                "            medium = makeIrregularInclusion(Nx, Ny, dx, base_translation(1), ..."; ...
                "                c0, rho0, density_std, hom_alpha, parameters.inclusionShape{1}, ..."; ...
                "                parameters.inclusionCenterMm(1, :), parameters.inclusionGeometryMm(1, :), ..."; ...
                "                parameters.inclusionAlpha(1));"; ...
                "        elseif strcmpi(parameters.mediumModel, 'Múltiples inclusiones')"; ...
                "            medium = makeMultipleInclusion(Nx, Ny, dx, base_translation(1), ..."; ...
                "                c0, rho0, density_std, hom_alpha, parameters.inclusionShape, ..."; ...
                "                parameters.inclusionCenterMm, parameters.inclusionGeometryMm, ..."; ...
                "                parameters.inclusionAlpha);"; ...
                "        elseif any(strcmpi(parameters.mediumModel, {'Medio por capas', 'Capas'}))"; ...
                "            medium = makeMultipleLayers(Nx, Ny, dx, base_translation(1), ..."; ...
                "                c0, rho0, density_std, hom_alpha, parameters.layerThicknessMm, ..."; ...
                "                parameters.layerAlpha);"; ...
                "        else"; ...
                "            error('Modelo acústico no reconocido: %s', parameters.mediumModel);"; ...
                "        end"; ""; ...
                "        medium.alpha_power = alpha_power;"; ...
                "        medium.alpha_mode = alpha_mode;"; ...
                "        medium.sound_speed_ref = sound_speed_ref;"; ""; ...
                "        %% Medium properties"; ...
                "        % Same sound-speed, density and ACS preview as the baseline."; ...
                "        if saveMediumPreviews"; ...
                "            saveMediumPreview(kgrid, medium, base_translation, depth, outputFolder, iRef);"; ...
                "        end"; ""; ...
                "        %% Allocate RF data"; ""; ...
                "        rf_prebf = zeros(kgrid.Nt, element_num, nLines);"; ""; ...
                "        %% Beam loop"; ""; ...
                "        for iLine = 1:nLines"; ...
                "            translation = base_translation;"; ...
                "            translation(2) = yCords(iLine);"; ...
                "            karray.setArrayPosition(translation, rotation)"; ""; ...
                "            source.p_mask = karray.getArrayBinaryMask(kgrid);"; ...
                "            source.p = karray.getDistributedSourceSignal(kgrid, source_sig);"; ""; ...
                "            fprintf('Reference %d/%d | Line %d/%d\\n', iRef, nRefs, iLine, nLines);"; ""; ...
                "            %% Sensor"; ...
                "            directivity_size_factor = parameters.directivity_size_factor;"; ...
                "            directivity_angle = parameters.directivity_angle;"; ...
                "            sensor.mask = karray.getArrayBinaryMask(kgrid);"; ...
                "            sensor.directivity_size = directivity_size_factor * kgrid.dx;"; ...
                "            sensor.directivity_angle = directivity_angle ..."; ...
                "                * ones(size(sensor.mask));"; ""; ...
                "            %% Simulation"; ...
                "            sensor_data = runKWaveSolver(solverName, ..."; ...
                "                kgrid, medium, source, sensor, input_args);"; ""; ...
                "            % Combine sensor data into element RF channels."; ...
                "            combined_sensor_data = karray.combineSensorData(kgrid, sensor_data);"; ...
                "            % Store as [time, element, line]."; ...
                "            rf_prebf(:, :, iLine) = combined_sensor_data';"; ...
                "        end"; ""; ...
                "        %% Axes and metadata"; ""; ...
                "        fs = 1 / kgrid.dt;"; ...
                "        offset = 1;"; ...
                "        axAxis = (0:kgrid.Nt-1) * kgrid.dt * c0 / 2;"; ...
                "        z = axAxis(offset:end);"; ...
                "        x = yCords;"; ""; ...
                "        active_tx_elements = element_num_Tx;"; ...
                "        activeTx = amp_vector ~= 0;"; ...
                "        txPositions = ids(activeTx) * element_pitch;"; ...
                "        txDelays = round(time_delays(activeTx) / kgrid.dt) * kgrid.dt;"; ...
                "        pulseDuration = floor(source_cycles / source_f0 * fs) / fs;"; ...
                "        time_zero_s = median(txDelays + (sqrt(source_focus^2 + txPositions.^2) - source_focus) / c0) ..."; ...
                "            + pulseDuration / 2; % Referencia temporal de eco compatible con los retardos Tx guardados."; ...
                "        density_map = medium.density;"; ...
                "        alpha_coeff = medium.alpha_coeff;"; ...
                "        sound_speed = medium.sound_speed;"; ""; ...
                "        outFile = fullfile(outputFolder, sprintf('rf_prebf_homRef_%03d.mat', iRef));"; ...
                "        if saveRfPrebeamformed"; ...
                "            save(outFile, ..."; ...
                "                'rf_prebf', 'x', 'z', 'fs', 'time_delays', ..."; ...
                "                'density_map', 'alpha_coeff', 'sound_speed', ..."; ...
                "                'density_std', 'hom_alpha', 'c0', 'rho0', ..."; ...
                "                'source_f0', 'source_amp', 'source_cycles', 'source_focus', ..."; ...
                "                'element_pitch', 'element_width', ..."; ...
                "                'focal_number_Tx', 'focal_number_Rx', 'active_tx_elements', 'time_zero_s', 'nLines', 'depth', ..."; ...
                "                'grid_size_x', 'grid_size_y', 'dx', 'ppw', 'cfl', 'PMLSize', ..."; ...
                "                'refSeed', 'iRef', 'simuName', '-v7.3');"; ...
                "        else"; ...
                "            outFile = '';"; ...
                "        end"; ""; ...
                "        manifest(iRef).file = outFile;"; ...
                "        manifest(iRef).seed = refSeed;"; ...
                "        manifest(iRef).density_std = density_std;"; ...
                "        manifest(iRef).alpha_coeff = hom_alpha;"; ...
                "    end"; ""; ...
                "    save(fullfile(outputFolder, 'reference_manifest.mat'), ..."; ...
                "        'manifest', 'nRefs', 'refSeedBase', 'density_std', 'hom_alpha');"; ""; ...
                "    fprintf('\\nDone. Saved %d homogeneous reference files in:\\n%s\\n', ..."; ...
                "        nRefs, outputFolder);"; "end"; ""; ...
                "%% Funciones"; ""; ...
                QUSConfigurationLogic.generatedCaseParametersFunction(cases, isAlphaSweep); ""; ...
                QUSConfigurationLogic.generatedHelperFunctions(); ""; ...
                QUSConfigurationLogic.generatedGuiCaseMetadata(cases, isAlphaSweep)];

            fileId = fopen(pipelinePath, 'w');
            if fileId == -1
                error('No se pudo crear el pipeline: %s.', pipelinePath);
            end
            cleanup = onCleanup(@() fclose(fileId));
            fprintf(fileId, '%s\n', lines);
            clear cleanup
        end
        
        % Genera el lanzador Slurm al lado del script MATLAB. Conserva la
        % estructura del baseline y usa run para ejecutar un script (no una función).
        function writeSbatchScript(sbatchPath, pipelinePath)
            [~, pipelineStem, pipelineExtension] = fileparts(pipelinePath);
            if ~strcmpi(pipelineExtension, '.m')
                error('El pipeline para Slurm debe tener extensión .m: %s.', pipelinePath);
            end
            pipelineFileName = [pipelineStem, pipelineExtension];
            matlabCommand = ['run(''' ...
                QUSConfigurationLogic.escapeMatlabText(pipelineFileName) ...
                '''); exit'];
            outputDirective = sprintf('#SBATCH --output="%s-%%j.out"', pipelineStem);
            runDirective = sprintf( ...
                'srun matlab -nosplash -nodesktop -nodisplay -r "%s"', matlabCommand);
            lines = [ ...
                "#!/usr/bin/bash"; ""; ...
                "#SBATCH --gpus-per-node=1"; ...
                "#SBATCH --nodes=1"; ...
                "#SBATCH --partition=thinkstation"; ...
                "#SBATCH --nodelist=worker7"; ...
                string(outputDirective); ""; string(runDirective) ...
            ];
            fileId = fopen(sbatchPath, 'w');
            if fileId == -1
                error('No se pudo crear el script Slurm: %s.', sbatchPath);
            end
            cleanup = onCleanup(@() fclose(fileId));
            fprintf(fileId, '%s\n', lines);
            clear cleanup
        end

        % Escribe una vista legible del mismo contrato que Open Config lee
        % en comentarios. No incluye marcas de tiempo para que dos guardados
        % de la misma configuración produzcan el mismo contenido JSON.
        function writePipelineCaseJson(metadataPath, state)
            reference = state.reference;
            if isfield(state, 'previewCases') && ~isempty(state.previewCases)
                cases = QUSConfigurationLogic.materializePreviewCases(state.previewCases);
            else
                cases = QUSConfigurationLogic.materializeExperimentCases(reference, state.queue);
            end
            isAlphaSweep = ~isempty(cases) && all([cases.isAlphaSweep]);
            records = struct([]);
            for caseIndex = 1:numel(cases)
                scientificParameters = QUSConfigurationLogic.pipelineParametersFromConfiguration( ...
                    cases(caseIndex).configuration);
                values = QUSConfigurationLogic.pipelineCaseValues(scientificParameters, ...
                    cases(caseIndex).isReference, ...
                    QUSConfigurationLogic.materializedSimulationName(cases(caseIndex)), ...
                    cases(caseIndex).configuration);
                if isAlphaSweep
                    values.hom_alpha = cases(caseIndex).configuration.medium.hom_alpha;
                end
                if caseIndex == 1
                    records = values;
                else
                    records(end + 1) = values;
                end
            end
            % Una celda fuerza un arreglo JSON incluso cuando sólo hay un
            % caso. Así un consumidor externo no necesita tratar dos
            % formas distintas para `cases`.
            recordList = num2cell(records);
            referenceIndex = find([records.isReference], 1, 'first');
            metadata = struct('schema_version', 2, 'record_type', ...
                'qus_gui_pipeline', 'case_count', numel(records), ...
                'reference_case_index', referenceIndex, 'cases', {recordList});
            fileId = fopen(metadataPath, 'w');
            if fileId == -1
                error('No se pudo crear el JSON de configuración: %s.', metadataPath);
            end
            cleanup = onCleanup(@() fclose(fileId));
            fprintf(fileId, '%s\n', jsonencode(metadata, 'PrettyPrint', true));
            clear cleanup
        end

        %Para los logs
        function path = queuePath(item)
            path = '';
            key = [char(item.section), '|', char(item.parameter)];
            paths = containers.Map( ...
                {'Geometría y malla|Tamaño axial [m]', 'Geometría y malla|Tamaño lateral [m]', ...
                 'Geometría y malla|PPW', 'Geometría y malla|PML axial', ...
                 'Geometría y malla|PML lateral', 'Geometría y malla|CFL', ...
                 'Geometría y malla|Profundidad [m]', 'Medio acústico|Modelo', ...
                 'Medio acústico|Velocidad de sonido [m/s]', 'Medio acústico|Densidad [kg/m^3]', ...
                 'Medio acústico|ACS [dB/cm/MHz]', 'Medio acústico|Desviación de densidad', ...
                 'Medio acústico|Alpha power', 'Medio acústico|Modo de absorción', ...
                 'Medio acústico|Velocidad de referencia [m/s]', 'Transductor emisor|Frecuencia [MHz]', ...
                 'Transductor emisor|Amplitud [MPa]', 'Transductor emisor|N.º ciclos', ...
                 'Transductor emisor|Focal depth [m]', 'Transductor emisor|Pitch [m]', ...
                 'Transductor emisor|Element width [m]', 'Transductor emisor|Focal number Tx', ...
                 'Transductor emisor|Focal number Rx', 'Transductor emisor|Number of beams', ...
                 'Posición|Axial translation [m]', 'Posición|Lateral translation [m]', ...
                 'Transductor emisor|Factor de directividad de recepción', ...
                 'Transductor emisor|Ángulo de directividad de recepción [rad]', 'Cálculo|DataCast', ...
                 'Cálculo|PlotSim', 'Cálculo|Solver', 'Reproducibilidad|Semilla global', ...
                 'Reproducibilidad|Semilla base de referencias', 'Reproducibilidad|nRefs de objetivos', ...
                 'Reproducibilidad|nRefs de referencia'}, ...
                {'geometry.grid_size_x', 'geometry.grid_size_y', 'geometry.ppw', 'geometry.pml_size_x', ...
                 'geometry.pml_size_y', 'geometry.cfl', 'geometry.depth', 'medium.model', ...
                 'medium.sound_speed', 'medium.density', 'medium.hom_alpha', 'medium.density_std', ...
                 'medium.alpha_power', 'medium.alpha_mode', 'medium.sound_speed_ref', ...
                 'transducer.frequency', 'transducer.amplitude', 'transducer.cycles', ...
                 'transducer.source_focus', 'transducer.element_pitch', 'transducer.element_width', ...
                 'transducer.focal_number_tx', 'transducer.focal_number_rx', 'transducer.n_lines', ...
                 'transducer.base_translation_x', 'transducer.base_translation_y', ...
                 'transducer.receive_directivity_size_factor', ...
                 'transducer.receive_directivity_angle', 'computation.data_cast', ...
                 'computation.plot_sim_flag', 'computation.solver', 'reproducibility.rng_seed', ...
                 'reproducibility.ref_seed_base', 'reproducibility.n_refs_target', ...
                 'reproducibility.n_refs_reference'});
            if isKey(paths, key)
                path = paths(key);
            end
        end
        
        %para generar una lista valida al .m
        function literal = matlabCellLiteral(values)
            elements = strings(1, numel(values));
            for index = 1:numel(values)
                elements(index) = QUSConfigurationLogic.matlabLiteral(values(index));
            end
            literal = '{' + strjoin(elements, ', ') + '}';
        end
       
        %para valores validos al .m
        function literal = matlabLiteral(value)
            if islogical(value)
                literal = string(lower(mat2str(value)));
            elseif isnumeric(value)
                if isscalar(value)
                    literal = string(num2str(value, '%.16g'));
                else
                    literal = string(mat2str(value, 16));
                end
            elseif iscell(value)
                elements = strings(1, numel(value));
                for index = 1:numel(value)
                    elements(index) = QUSConfigurationLogic.matlabLiteral(value{index});
                end
                literal = '{' + strjoin(elements, ', ') + '}';
            else
                literal = "'" + QUSConfigurationLogic.escapeMatlabText(value) + "'";
            end
        end
        
        % Serializa una estructura como asignaciones MATLAB legibles, para que 
        % no se necesite usar un .mat adicional para generar el .m .
        function lines = matlabStructureAssignments(variableName, value)
            
            lines = string(variableName) + " = struct;";
            fields = fieldnames(value);
            for index = 1:numel(fields)
                fieldName = fields{index};
                fieldValue = value.(fieldName);
                target = string(variableName) + "." + fieldName;
                if isstruct(fieldValue)
                    nestedLines = QUSConfigurationLogic.matlabStructureAssignments(target, fieldValue);
                    lines = [lines; nestedLines(2:end)];
                else
                    lines(end + 1, 1) = target + " = " + ...
                        QUSConfigurationLogic.matlabLiteral(fieldValue) + ";";
                end
            end
        end
        
        % Valores literales que viajan en el .m y permiten reabrir la GUI.
        function values = pipelineCaseValues(parameters, isReference, simulationName, configuration)
            if nargin < 4
                error('La configuración completa es necesaria para serializar un caso de la GUI.');
            end
            if isReference
                nRefs = parameters.nRefsReference;
            else
                nRefs = parameters.nRefsTarget;
            end
            mediumFields = QUSConfigurationLogic.mediumPipelineFields(configuration.medium);
            values = struct( ...
                'isReference', logical(isReference), 'nRefs', nRefs, ...
                'refSeedBase', parameters.refSeedBase, 'c0', parameters.c0, ...
                'rho0', parameters.rho0, 'hom_alpha', parameters.hom_alpha, ...
                'density_std', parameters.density_std, 'simuName', simulationName, ...
                'source_f0', parameters.source_f0, 'source_amp', parameters.source_amp, ...
                'source_cycles', parameters.source_cycles, 'source_focus', parameters.source_focus, ...
                'element_pitch', parameters.element_pitch, 'element_width', parameters.element_width, ...
                'focal_number_Tx', parameters.focal_number_Tx, ...
                'focal_number_Rx', parameters.focal_number_Rx, 'nLines', parameters.nLines, ...
                'grid_size_x', parameters.grid_size_x, 'grid_size_y', parameters.grid_size_y, ...
                'base_translation', parameters.base_translation, 'rotation', parameters.rotation, ...
                'DATA_CAST', parameters.DATA_CAST, 'ppw', parameters.ppw, ...
                'depth', parameters.depth, 'cfl', parameters.cfl, 'PMLSize', parameters.PMLSize, ...
                'plotSimFlag', parameters.plotSimFlag, 'alpha_power', parameters.alpha_power, ...
                'alpha_mode', parameters.alpha_mode, 'sound_speed_ref', parameters.sound_speed_ref, ...
                'saveMediumPreviews', parameters.saveMediumPreviews, ...
                'saveRfPrebeamformed', parameters.saveRfPrebeamformed, ...
                'directivity_size_factor', parameters.directivity_size_factor, ...
                'directivity_angle', parameters.directivity_angle, 'solverName', parameters.solverName, ...
                'rngSeed', configuration.reproducibility.rng_seed, ...
                'mediumModel', configuration.medium.model, ...
                'transducerType', configuration.transducer.type, ...
                'transducerSignal', configuration.transducer.signal, ...
                'transducerBeamMode', configuration.transducer.beam_mode);
            fields = fieldnames(mediumFields);
            for index = 1:numel(fields)
                values.(fields{index}) = mediumFields.(fields{index});
            end
        end

        function fields = mediumPipelineFields(mediumConfiguration)
            config = mediumConfiguration.config;
            if ~isfield(config, 'inclusions') || isempty(config.inclusions)
                config.inclusions = MediumConfigurationLogic.defaultConfig().inclusions;
            end
            inclusions = config.inclusions;
            count = numel(inclusions);
            fields = struct( ...
                'inclusionShape', {cell(1, count)}, ...
                'inclusionCenterMm', zeros(count, 2), ...
                'inclusionGeometryMm', zeros(count, 2), ...
                'inclusionAlpha', zeros(1, count), ...
                'layerThicknessMm', zeros(1, 0), ...
                'layerAlpha', zeros(1, 0));
            for index = 1:count
                item = inclusions(index);
                fields.inclusionShape{index} = item.shape;
                fields.inclusionCenterMm(index, :) = item.center_mm;
                fields.inclusionGeometryMm(index, :) = item.geometry_mm;
                fields.inclusionAlpha(index) = item.acoustic.acs;
            end
            if isfield(config, 'layers') && ~isempty(config.layers)
                layers = config.layers;
                layerCount = numel(layers);
                fields.layerThicknessMm = zeros(1, layerCount);
                fields.layerAlpha = zeros(1, layerCount);
                for index = 1:layerCount
                    item = layers(index);
                    fields.layerThicknessMm(index) = item.thickness_mm;
                    fields.layerAlpha(index) = item.acoustic.acs;
                end
            end
        end
        
        % Este es solo el formato para que sea lo mas parecido al pipeline
        % original.
        function lines = generatedCaseParametersFunction(cases, isAlphaSweep)
            
            lines = [ ...
                "% getGuiCaseParameters devuelve el snapshot serializado de cada caso de la GUI."; ...
                "function parameters = getGuiCaseParameters(ii, refValues)"; ...
                "    % Snapshot autónomo de los valores seleccionados en la GUI."; ...
                "    % No carga MAT: este M se puede enviar solo al cluster."; ...
                "    switch ii"];
            for index = 1:numel(cases)
                scientificParameters = QUSConfigurationLogic.pipelineParametersFromConfiguration( ...
                    cases(index).configuration);
                values = QUSConfigurationLogic.pipelineCaseValues(scientificParameters, ...
                    cases(index).isReference, ...
                    QUSConfigurationLogic.materializedSimulationName(cases(index)), ...
                    cases(index).configuration);
                fields = fieldnames(values);
                lines = [lines; "        case " + index; "            parameters = struct;"];
                for fieldIndex = 1:numel(fields)
                    fieldName = fields{fieldIndex};
                    if isAlphaSweep && strcmp(fieldName, 'hom_alpha')
                        lines(end + 1, 1) = "            parameters.hom_alpha = refValues(ii);";
                    else
                        lines(end + 1, 1) = "            parameters." + fieldName + " = " + ...
                            QUSConfigurationLogic.matlabLiteral(values.(fieldName)) + ";";
                    end
                end
            end
            lines = [lines; ...
                "        otherwise"; ...
                "            error('Unknown experiment case: %d', ii);"; ...
                "    end"; ...
                "end"];
        end

        function lines = generatedCaseCatalogFunction(cases, isAlphaSweep)
            if isAlphaSweep
                alphaValues = arrayfun(@(item) item.configuration.medium.hom_alpha, cases);
                refValuesLiteral = QUSConfigurationLogic.matlabLiteral(alphaValues);
            else
                refValuesLiteral = "[]";
            end
            lines = [ ...
                "% getGuiCaseCatalog reúne los casos serializados sin ejecutar ninguna simulación."; ...
                "function parametersByCase = getGuiCaseCatalog()"; ...
                "    refValues = " + refValuesLiteral + ";"; ...
                "    parametersByCase = getGuiCaseParameters(1, refValues);"; ...
                "    for caseIndex = 2:" + num2str(numel(cases)); ...
                "        parametersByCase(caseIndex) = getGuiCaseParameters(caseIndex, refValues);"; ...
                "    end"; ...
                "end"];
        end

        function lines = generatedGuiCaseMetadata(cases, isAlphaSweep)
            % Comentarios de una línea: el script sigue siendo independiente
            % de su nombre y se ejecuta sin argumentos, igual que el baseline.
            % Open Config los lee sin evaluar el archivo.
            lines = ["%% GUI case metadata (read by App_v5; ignored by MATLAB execution)"; ...
                "% QUS_GUI_CASE_METADATA_VERSION 2"];
            for index = 1:numel(cases)
                scientificParameters = QUSConfigurationLogic.pipelineParametersFromConfiguration( ...
                    cases(index).configuration);
                values = QUSConfigurationLogic.pipelineCaseValues(scientificParameters, ...
                    cases(index).isReference, ...
                    QUSConfigurationLogic.materializedSimulationName(cases(index)), ...
                    cases(index).configuration);
                if isAlphaSweep
                    values.hom_alpha = cases(index).configuration.medium.hom_alpha;
                end
                metadata = struct('schema_version', 2, 'case', values);
                lines(end + 1, 1) = "% QUS_GUI_CASE_JSON " + string(jsonencode(metadata));
            end
        end
        
        %transforma los parámetros de un caso en líneas de código MATLAB listas para escribir en un pipeline.
        function lines = pipelineLiteralAssignments(parameters, isReference, simulationName, configuration)
            values = QUSConfigurationLogic.pipelineCaseValues( ...
                parameters, isReference, simulationName, configuration);
            lines = strings(0, 1);
            fields = fieldnames(values);
            for index = 1:numel(fields)
                fieldName = fields{index};
                lines(end + 1, 1) = string(fieldName) + " = " + ...
                    QUSConfigurationLogic.matlabLiteral(values.(fieldName)) + ";";
            end
        end
        
        %Logica del save
        function cases = materializeExperimentCases(reference, queue)
            % Expande la cola en Save; el pipeline del cluster recibe ya los
            % casos concretos, no la lógica de configuración de la GUI.
            if isempty(queue)
                cases = struct('configuration', reference, 'isReference', true, ...
                    'isAlphaSweep', false, 'tag', 'reference');
                return
            end

            paths = strings(1, numel(queue));
            indexVectors = cell(1, numel(queue));
            for index = 1:numel(queue)
                paths(index) = QUSConfigurationLogic.queuePath(queue(index));
                if paths(index) == ""
                    error('No se puede generar el pipeline para: %s / %s.', ...
                        queue(index).section, queue(index).parameter);
                end
                indexVectors{index} = 1:numel(queue(index).values);
            end
            grids = cell(1, numel(queue));
            [grids{:}] = ndgrid(indexVectors{:});
            targetCount = numel(grids{1});
            isAlphaSweep = numel(queue) == 1 && paths(1) == "medium.hom_alpha";
            cases = repmat(struct('configuration', struct(), 'isReference', false, ...
                'isAlphaSweep', isAlphaSweep, 'tag', ''), 1, targetCount + 1);

            for caseIndex = 1:targetCount
                current = reference;
                tags = strings(1, numel(queue));
                for parameterIndex = 1:numel(queue)
                    valueIndex = grids{parameterIndex}(caseIndex);
                    queueValues = queue(parameterIndex).values;
                    if iscell(queueValues)
                        value = queueValues{valueIndex};
                    else
                        value = queueValues(valueIndex);
                    end
                    parts = strsplit(paths(parameterIndex), '.');
                    current.(parts{1}).(parts{2}) = value;
                    tags(parameterIndex) = paths(parameterIndex) + "_" + ...
                        QUSConfigurationLogic.valueToken(value);
                end
                cases(caseIndex).configuration = current;
                cases(caseIndex).tag = char(strjoin(tags, '__'));
            end
            cases(end).configuration = reference;
            cases(end).isReference = true;
            cases(end).tag = 'reference';
        end

        function cases = materializePreviewCases(previewCases)
            count = numel(previewCases);
            cases = repmat(struct('configuration', struct(), 'isReference', false, ...
                'isAlphaSweep', false, 'tag', ''), 1, count);
            for index = 1:count
                cases(index).configuration = previewCases(index).configuration;
                cases(index).isReference = index == 1;
                if index == 1
                    cases(index).tag = 'reference';
                else
                    cases(index).tag = char(lower(QUSConfigurationLogic.caseLabel(index)));
                end
            end
        end
        
        % transforma los parámetros de un caso en líneas de código MATLAB listas para escribir en un pipeline.
        function name = materializedSimulationName(caseInfo)
            parameters = QUSConfigurationLogic.pipelineParametersFromConfiguration(caseInfo.configuration);
            if caseInfo.isAlphaSweep
                role = 'target';
                if caseInfo.isReference
                    role = 'ref';
                end
                name = ['homogeneus_', role, '_alpha', ...
                    QUSConfigurationLogic.valueToken(parameters.hom_alpha), '_std', ...
                    QUSConfigurationLogic.valueToken(parameters.density_std)];
            elseif caseInfo.isReference
                name = 'homogeneous_ref';
            else
                name = ['homogeneous_target_', caseInfo.tag];
            end
        end
        
        % convierte cualquier valor en texto seguro para usar dentro de nombres de archivos y carpetas.
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
        
        % prepara un texto para insertarlo de forma segura dentro de código MATLAB generado.
        function text = escapeMatlabText(value)
            text = strrep(char(string(value)), '''', '''''');
        end
        
        %Folder donde se guardan los scripts
        function folder = codeFolder(app, experimentFolderName)
            if isprop(app, 'Tree') && isprop(app, 'UIFigure')
                parentFolder = ProjectExplorerLogic.getOutputParentFolder(app);
            else
                parentFolder = fullfile(fileparts(mfilename('fullpath')), 'code');
            end
            folder = fullfile(parentFolder, experimentFolderName);
        end
        % transforma los parámetros de un caso en líneas de código MATLAB listas para escribir en un pipeline.
        function lines = generatedHelperFunctions()
            lines = [ ...
                "% saveMediumPreview exporta los mapas usando la misma profundidad física que la GUI."; ...
                "function saveMediumPreview(kgrid, medium, base_translation, depth, outputFolder, iRef)"; ...
                "    rx = kgrid.y;"; ...
                "    rz = kgrid.x - base_translation(1); % Expresa z desde la superficie del transductor."; ...
                "    figMedium = figure('Units', 'centimeters', 'Position', [5 5 25 10], 'Visible', 'off');"; ...
                "    colormap(figMedium, turbo(256));"; ...
                "    tiledlayout(1, 3)"; ...
                "    nexttile; imagesc(100 * rx(1,:), 100 * rz(:,1), medium.sound_speed);"; ...
                "    xlabel('x [cm]'); ylabel('z [cm]'); title('Sound speed'); c = colorbar; ylabel(c, 'm/s'); axis image; ylim([0, 100 * depth]); set(gca, 'YDir', 'reverse');"; ...
                "    nexttile; imagesc(100 * rx(1,:), 100 * rz(:,1), medium.density);"; ...
                "    xlabel('x [cm]'); ylabel('z [cm]'); title('Density'); c = colorbar; ylabel(c, 'kg/m^3'); axis image; ylim([0, 100 * depth]); set(gca, 'YDir', 'reverse');"; ...
                "    nexttile; imagesc(100 * rx(1,:), 100 * rz(:,1), medium.alpha_coeff, [0.35 1.05]);"; ...
                "    xlabel('x [cm]'); ylabel('z [cm]'); title('ACS'); c = colorbar; c.Ticks = 0.4:0.1:1.0; c.TickLabels = {'0.4','','0.6','','0.8','','1'}; ylabel(c, 'ACS [dB/cm/MHz]'); axis image; ylim([0, 100 * depth]); set(gca, 'YDir', 'reverse');"; ...
                "    sgtitle(sprintf('Homogeneous reference %03d', iRef))"; ...
                "    savefig(figMedium, fullfile(outputFolder, sprintf('medium_homRef_%03d.fig', iRef)));"; ...
                "    saveas(figMedium, fullfile(outputFolder, sprintf('medium_homRef_%03d.png', iRef)));"; ...
                "    close(figMedium)"; ...
                "end"; ""; ...
                "% assertLateralScanCoverage detiene adquisiciones con arreglos fuera de la malla lateral."; ...
                "function assertLateralScanCoverage(gridSizeY, sourceFocus, pitch, elementWidth, fNumberRx, nLines, caseName)"; ...
                "    receiveElements = floor(sourceFocus / fNumberRx / pitch);"; ...
                "    receiveWidth = (receiveElements - 1) * pitch + elementWidth;"; ...
                "    requiredWidth = (nLines - 1) * pitch + receiveWidth;"; ...
                "    if receiveElements < 1 || gridSizeY + eps(max(gridSizeY, requiredWidth)) < requiredWidth"; ...
                "        maxLines = max(0, floor((gridSizeY - receiveWidth) / pitch) + 1);"; ...
                "        error(['%s: malla lateral insuficiente. Se requieren %.3f mm para %d líneas; ' ..."; ...
                "            'la malla actual es %.3f mm y admite como máximo %d líneas.'], ..."; ...
                "            caseName, 1e3 * requiredWidth, nLines, 1e3 * gridSizeY, maxLines);"; ...
                "    end"; ...
                "end"; ""; ...
                "% runKWaveSolver ejecuta el solver seleccionado y normaliza el nombre legado."; ...
                "function sensor_data = runKWaveSolver(solverName, kgrid, medium, source, sensor, input_args)"; ...
                "    if strcmpi(solverName, 'kspaceFirstoOrder2D')"; ...
                "        solverName = 'kspaceFirstOrder2D'; % Corrige la grafía histórica guardada por configuraciones previas."; ...
                "    end"; ...
                "    sensor_data = feval(solverName, kgrid, medium, source, sensor, input_args{:});"; ...
                "end"; ""; ...
                "% makeHomogeneousDensityOnlyMedium crea un medio uniforme con variación aleatoria de densidad."; ...
                "function medium = makeHomogeneousDensityOnlyMedium(Nx, Ny, c0, rho0, densityStd, alpha)"; ...
                "    medium.sound_speed = c0 * ones(Nx, Ny);"; ...
                "    medium.density = rho0 .* (1 + densityStd * randn(Nx, Ny)); % Introduce dispersores sin cambiar c0 ni ACS."; ...
                "    medium.alpha_coeff = alpha * ones(Nx, Ny);"; ...
                "end"; ""; ...
                "% makeCircularInclusion aplica ACS distinto dentro de una inclusión circular."; ...
                "function medium = makeCircularInclusion(Nx, Ny, dx, baseAxialTranslation, c0, rho0, densityStd, bgAlpha, centerMm, geometryMm, incAlpha)"; ...
                "    medium = makeHomogeneousDensityOnlyMedium(Nx, Ny, c0, rho0, densityStd, bgAlpha);"; ...
                "    [zMm, xMm] = mediumCoordinates(Nx, Ny, dx, baseAxialTranslation);"; ...
                "    if ~isfinite(centerMm(2)), centerMm(2) = mean(zMm(:)); end"; ...
                "    mask = (xMm - centerMm(1)).^2 + (zMm - centerMm(2)).^2 <= geometryMm(1).^2;"; ...
                "    medium.alpha_coeff(mask) = incAlpha(1); % Solo la región circular recibe el ACS de inclusión."; ...
                "end"; ""; ...
                "% makeIrregularInclusion construye una inclusión elíptica, rectangular o irregular."; ...
                "function medium = makeIrregularInclusion(Nx, Ny, dx, baseAxialTranslation, c0, rho0, densityStd, bgAlpha, shape, centerMm, geometryMm, incAlpha)"; ...
                "    medium = makeHomogeneousDensityOnlyMedium(Nx, Ny, c0, rho0, densityStd, bgAlpha);"; ...
                "    [zMm, xMm] = mediumCoordinates(Nx, Ny, dx, baseAxialTranslation);"; ...
                "    if ~isfinite(centerMm(2)), centerMm(2) = mean(zMm(:)); end"; ...
                "    mask = inclusionMask(xMm, zMm, shape, centerMm, geometryMm);"; ...
                "    medium.alpha_coeff(mask) = incAlpha;"; ...
                "end"; ""; ...
                "% makeMultipleInclusion asigna ACS independiente a cada inclusión sin permitir solapamientos."; ...
                "function medium = makeMultipleInclusion(Nx, Ny, dx, baseAxialTranslation, c0, rho0, densityStd, bgAlpha, shapes, centersMm, geometriesMm, incAlpha)"; ...
                "    medium = makeHomogeneousDensityOnlyMedium(Nx, Ny, c0, rho0, densityStd, bgAlpha);"; ...
                "    [zMm, xMm] = mediumCoordinates(Nx, Ny, dx, baseAxialTranslation);"; ...
                "    occupied = false(Nx, Ny);"; ...
                "    for incIndex = 1:numel(incAlpha)"; ...
                "        centerMm = centersMm(incIndex, :);"; ...
                "        if ~isfinite(centerMm(2)), centerMm(2) = mean(zMm(:)); end"; ...
                "        mask = inclusionMask(xMm, zMm, shapes{incIndex}, centerMm, geometriesMm(incIndex, :));"; ...
                "        if any(mask(:) & occupied(:)), error('Las inclusiones no pueden solaparse.'); end % Evita que el último ACS sobrescriba otro."; ...
                "        medium.alpha_coeff(mask) = incAlpha(incIndex);"; ...
                "        occupied = occupied | mask;"; ...
                "    end"; ...
                "end"; ""; ...
                "% makeMultipleLayers distribuye ACS por estratos axiales desde z = 0."; ...
                "function medium = makeMultipleLayers(Nx, Ny, dx, baseAxialTranslation, c0, rho0, densityStd, bgAlpha, thicknessMm, layerAlpha)"; ...
                "    medium = makeHomogeneousDensityOnlyMedium(Nx, Ny, c0, rho0, densityStd, bgAlpha);"; ...
                "    [zMm, ~] = mediumCoordinates(Nx, Ny, dx, baseAxialTranslation);"; ...
                "    % zMm is referenced to the transducer surface: layer 1 starts at z = 0."; ...
                "    zFromTransducer = zMm;"; ...
                "    lower = 0;"; ...
                "    for layerIndex = 1:numel(layerAlpha)"; ...
                "        upper = lower + thicknessMm(layerIndex);"; ...
                "        if layerIndex == numel(layerAlpha), mask = zFromTransducer >= lower; else, mask = zFromTransducer >= lower & zFromTransducer < upper; end % La última capa cubre el resto del dominio."; ...
                "        medium.alpha_coeff(mask) = layerAlpha(layerIndex);"; ...
                "        lower = upper;"; ...
                "    end"; ...
                "end"; ""; ...
                "% mediumCoordinates devuelve coordenadas en mm con z referido a la superficie emisora."; ...
                "function [zMm, xMm] = mediumCoordinates(Nx, Ny, dx, baseAxialTranslation)"; ...
                "    axialMm = 1e3 .* (((0:Nx-1) - floor(Nx/2)) .* dx - baseAxialTranslation); % Convierte el eje centrado de k-Wave a profundidad física."; ...
                "    lateralMm = 1e3 .* ((0:Ny-1) - floor(Ny/2)) .* dx;"; ...
                "    [zMm, xMm] = ndgrid(axialMm, lateralMm);"; ...
                "end"; ""; ...
                "% inclusionMask devuelve la máscara geométrica para la forma solicitada."; ...
                "function mask = inclusionMask(xMm, zMm, shape, centerMm, geometryMm)"; ...
                "    switch lower(char(shape))"; ...
                "        case 'circle'"; ...
                "            mask = (xMm - centerMm(1)).^2 + (zMm - centerMm(2)).^2 <= geometryMm(1).^2;"; ...
                "        case 'ellipse'"; ...
                "            mask = ((xMm - centerMm(1)) ./ geometryMm(1)).^2 + ((zMm - centerMm(2)) ./ geometryMm(2)).^2 <= 1;"; ...
                "        case 'rectangle'"; ...
                "            mask = abs(xMm - centerMm(1)) <= geometryMm(1) / 2 & abs(zMm - centerMm(2)) <= geometryMm(2) / 2;"; ...
                "        case 'irregular'"; ...
                "            perturbation = min(max(geometryMm(2), 0), 0.30);"; ...
                "            theta = atan2(zMm - centerMm(2), xMm - centerMm(1));"; ...
                "            boundary = geometryMm(1) .* (1 + perturbation .* (0.65 .* cos(3 .* theta) + 0.35 .* sin(5 .* theta))); % Perturbación angular controlada del radio."; ...
                "            mask = hypot(xMm - centerMm(1), zMm - centerMm(2)) <= boundary;"; ...
                "        otherwise"; ...
                "            error('Forma de inclusión no reconocida: %s', shape);"; ...
                "    end"; ...
                "end"];
        end
        
        %Guarda el archivo
        function name = safeFileName(name)
            name = regexprep(char(name), '[^A-Za-z0-9_]', '_');
            if isempty(name)
                name = 'qus_benchmark'; %Default
            end
            if ~isletter(name(1))
                name = ['qus_', name];
            end
        end
        
        %Funcion para encontrar el nombre de un archivo
        function fileName = getFileName(filePath)
            [~, name, extension] = fileparts(filePath);
            fileName = [name, extension];
        end

        function dialog = settingsDialog(titleText)
            dialog = uifigure('Name', titleText, 'Position', [360 260 520 410], ...
                'WindowStyle', 'modal', 'Resize', 'off');
        end

        function field = numericField(parent, row, labelText, value)
            label = uilabel(parent, 'Text', labelText);
            label.Layout.Row = row;
            label.Layout.Column = 1;
            field = uieditfield(parent, 'numeric', 'Value', value);
            field.Layout.Row = row;
            field.Layout.Column = 2;
        end

        function field = dropDownField(parent, row, labelText, items, value)
            label = uilabel(parent, 'Text', labelText);
            label.Layout.Row = row;
            label.Layout.Column = 1;
            field = uidropdown(parent, 'Items', items, 'Value', value);
            field.Layout.Row = row;
            field.Layout.Column = 2;
        end
        
        function field = checkBoxField(parent, row, labelText, value)
            field = uicheckbox(parent, 'Text', labelText, 'Value', value);
            field.Layout.Row = row;
            field.Layout.Column = [1 2];
        end
        
        function dialogButtons(dialog, applyCallback)
            apply = uibutton(dialog, 'push', 'Text', 'Aplicar', ...
                'Position', [290 15 100 28], 'ButtonPushedFcn', applyCallback);
            apply.BackgroundColor = [0.7922 0.9882 0.9176];
            uibutton(dialog, 'push', 'Text', 'Cancelar', 'Position', [400 15 90 28], ...
                'ButtonPushedFcn', @(~,~) delete(dialog));
        end
        
        %Mostrar algun error de estado
        function showError(app, message)
            app.EstadoEditField.Value = 'Configuración inválida';
            uialert(app.UIFigure, message, 'No se pudo completar la acción');
        end
    end
end
