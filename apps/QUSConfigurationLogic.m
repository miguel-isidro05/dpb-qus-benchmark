classdef QUSConfigurationLogic
    % QUSConfigurationLogic
    % Gestiona la configuración reproducible compartida por las apps.
    % Prepara y guarda los datos, pero no ejecuta k-Wave.

    methods (Static)
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
            QUSConfigurationLogic.storeState(app, state);
            QUSConfigurationLogic.updateExecution(app, state);
            QUSConfigurationLogic.updateStatusSummary(app, state, '');
            QUSConfigurationLogic.refreshAssociatedViews(app);
        end

        function onTest(app)
            state = QUSConfigurationLogic.prepare(app);
            QUSConfigurationLogic.updateExecution(app, state);
            QUSConfigurationLogic.updateStatusSummary(app, state, '');
            QUSConfigurationLogic.refreshAssociatedViews(app);
        end

        function onReset(app)
            state = QUSConfigurationLogic.prepare(app);
            state.referenceDefined = false;
            state.reference = struct();
            state.queue = QUSConfigurationLogic.emptyQueue();
            QUSConfigurationLogic.storeState(app, state);
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
            QUSConfigurationLogic.updateExecution(app, state);

            configuration = struct( ...
                'schema_version', 'qus-benchmark-configuration-v1', ...
                'created_at', char(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
                'reference', state.reference, ...
                'queue', state.queue, ...
                'description', ['Configuración reproducible. No contiene RF ni resultados ' ...
                    'de k-Wave.']);

            fileStem = QUSConfigurationLogic.safeFileName(state.reference.experiment.name);
            outputFolder = QUSConfigurationLogic.codeFolder(app, fileStem);
            if ~exist(outputFolder, 'dir')
                mkdir(outputFolder);
            end
            configurationFileName = [fileStem, '_configuration.mat'];
            pipelineFileName = [fileStem, '_pipeline.m'];
            configurationPath = fullfile(outputFolder, configurationFileName);
            pipelinePath = fullfile(outputFolder, pipelineFileName);
            % El MAT es el contrato entre la interfaz y el pipeline: conserva
            % la configuración completa y un juego de variables con los
            % nombres científicos usados por el script de k-Wave.
            pipelineParameters = QUSConfigurationLogic.pipelineParametersFromConfiguration( ...
                state.reference);

            try
                save(configurationPath, 'configuration', 'pipelineParameters');
                QUSConfigurationLogic.writePipelineScript(pipelinePath, configurationPath, configuration);
            catch exception
                QUSConfigurationLogic.showError(app, exception.message);
                return
            end

            QUSConfigurationLogic.updateStatusSummary(app, state, 'Configuración guardada');
            QUSConfigurationLogic.refreshAssociatedViews(app);
            if isprop(app, 'Tree') && isprop(app, 'NombreEditField')
                ProjectExplorerLogic.selectExperimentOutputFolder(app);
            end
        end

        function onOpen(app)
            state = QUSConfigurationLogic.prepare(app);
            [fileName, folder] = uigetfile({'*.mat', 'Configuración MATLAB (*.mat)'}, ...
                'Abrir configuración reproducible');
            if isequal(fileName, 0)
                return
            end

            try
                loaded = load(fullfile(folder, fileName), 'configuration');
                if ~isfield(loaded, 'configuration') || ...
                        ~isfield(loaded.configuration, 'reference') || ...
                        ~isfield(loaded.configuration, 'queue')
                    error('El archivo no tiene el formato de configuración QUS esperado.');
                end

                state.referenceDefined = true;
                state.reference = loaded.configuration.reference;
                state.queue = loaded.configuration.queue;
                state.advanced = QUSConfigurationLogic.advancedFromReference(state.reference);
                QUSConfigurationLogic.applyConfiguration(app, state.reference);
            catch exception
                QUSConfigurationLogic.showError(app, exception.message);
                return
            end

            QUSConfigurationLogic.storeState(app, state);
            QUSConfigurationLogic.updateExecution(app, state);
            QUSConfigurationLogic.updateStatusSummary(app, state, 'Configuración cargada');
            QUSConfigurationLogic.refreshAssociatedViews(app);
        end

        function openMediumSettings(app)
            state = QUSConfigurationLogic.prepare(app);
            settings = state.advanced.medium;
            dialog = QUSConfigurationLogic.settingsDialog('Medio acústico: parámetros avanzados');
            tabs = uitabgroup(dialog, 'Position', [15 55 490 285]);

            homogeneousTab = uitab(tabs, 'Title', 'Medio homogéneo');
            homogeneousGrid = uigridlayout(homogeneousTab, [2 2]);
            homogeneousGrid.ColumnWidth = {'1x', '1x'};
            homAlpha = QUSConfigurationLogic.numericField(homogeneousGrid, 1, ...
                'Atenuación [dB/(MHz^y cm)]', settings.hom_alpha);
            densityStd = QUSConfigurationLogic.numericField(homogeneousGrid, 2, ...
                'Desviación estándar de densidad', settings.density_std);

            absorptionTab = uitab(tabs, 'Title', 'Absorción');
            absorptionGrid = uigridlayout(absorptionTab, [3 2]);
            absorptionGrid.ColumnWidth = {'1x', '1x'};
            alphaPower = QUSConfigurationLogic.numericField(absorptionGrid, 1, ...
                'Alpha power', settings.alpha_power);
            alphaMode = QUSConfigurationLogic.dropDownField(absorptionGrid, 2, ...
                'Modo de absorción', {'no_dispersion', 'default'}, settings.alpha_mode);
            cReference = QUSConfigurationLogic.numericField(absorptionGrid, 3, ...
                'Velocidad de referencia [m/s]', settings.sound_speed_ref);

            QUSConfigurationLogic.dialogButtons(dialog, @applySettings);

            function applySettings(~, ~)
                if homAlpha.Value < 0 || densityStd.Value < 0 || ...
                        alphaPower.Value <= 0 || cReference.Value <= 0
                    uialert(dialog, 'Revisa los valores del medio acústico.', 'Valores inválidos');
                    return
                end
                state.advanced.medium = struct( ...
                    'hom_alpha', homAlpha.Value, ...
                    'density_std', densityStd.Value, ...
                    'alpha_power', alphaPower.Value, ...
                    'alpha_mode', alphaMode.Value, ...
                    'sound_speed_ref', cReference.Value);
                QUSConfigurationLogic.storeState(app, state);
                QUSConfigurationLogic.refreshPreviewIfAvailable(app);
                delete(dialog);
            end
        end

        function openTransducerSettings(app)
            state = QUSConfigurationLogic.prepare(app);
            settings = state.advanced.transducer;
            dialog = QUSConfigurationLogic.settingsDialog('Transductor: parámetros avanzados');
            tabs = uitabgroup(dialog, 'Position', [15 55 490 285]);

            arrayTab = uitab(tabs, 'Title', 'Arreglo');
            arrayGrid = uigridlayout(arrayTab, [4 2]);
            arrayGrid.ColumnWidth = {'1x', '1x'};
            focus = QUSConfigurationLogic.numericField(arrayGrid, 1, 'Foco [m]', settings.source_focus);
            pitch = QUSConfigurationLogic.numericField(arrayGrid, 2, 'Pitch [m]', settings.element_pitch);
            width = QUSConfigurationLogic.numericField(arrayGrid, 3, 'Ancho del elemento [m]', settings.element_width);
            rotation = QUSConfigurationLogic.numericField(arrayGrid, 4, 'Rotación [rad]', settings.rotation);

            scanTab = uitab(tabs, 'Title', 'Apertura y escaneo');
            scanGrid = uigridlayout(scanTab, [6 2]);
            scanGrid.ColumnWidth = {'1x', '1x'};
            fNumberTx = QUSConfigurationLogic.numericField(scanGrid, 1, 'F-number Tx', settings.focal_number_tx);
            fNumberRx = QUSConfigurationLogic.numericField(scanGrid, 2, 'F-number Rx', settings.focal_number_rx);
            nLines = QUSConfigurationLogic.numericField(scanGrid, 3, 'Número de líneas', settings.n_lines);
            baseX = QUSConfigurationLogic.numericField(scanGrid, 4, 'Traslación axial [m]', settings.base_translation_x);
            baseY = QUSConfigurationLogic.numericField(scanGrid, 5, 'Traslación lateral [m]', settings.base_translation_y);
            note = uilabel(scanGrid, 'Text', 'Los elementos y retardos se derivan de estos parámetros.');
            note.Layout.Row = 6;
            note.Layout.Column = [1 2];

            QUSConfigurationLogic.dialogButtons(dialog, @applySettings);

            function applySettings(~, ~)
                values = [focus.Value, pitch.Value, width.Value, fNumberTx.Value, ...
                    fNumberRx.Value, nLines.Value];
                if any(~isfinite(values)) || any(values <= 0)
                    uialert(dialog, 'Foco, pitch, ancho, F-numbers y líneas deben ser positivos.', ...
                        'Valores inválidos');
                    return
                end
                state.advanced.transducer = struct( ...
                    'source_focus', focus.Value, ...
                    'element_pitch', pitch.Value, ...
                    'element_width', width.Value, ...
                    'focal_number_tx', fNumberTx.Value, ...
                    'focal_number_rx', fNumberRx.Value, ...
                    'n_lines', round(nLines.Value), ...
                    'base_translation_x', baseX.Value, ...
                    'base_translation_y', baseY.Value, ...
                    'rotation', rotation.Value);
                QUSConfigurationLogic.storeState(app, state);
                QUSConfigurationLogic.refreshPreviewIfAvailable(app);
                delete(dialog);
            end
        end

        function openSensorSettings(app)
            state = QUSConfigurationLogic.prepare(app);
            settings = QUSConfigurationLogic.normalizeSensorSettings(state.advanced.sensor);
            sensorType = char(string(app.TipoDropDown_2.Value));
            dialog = QUSConfigurationLogic.settingsDialog(['Sensor: ', sensorType]);
            tabs = uitabgroup(dialog, 'Position', [15 55 490 285]);

            variablesTab = uitab(tabs, 'Title', 'Variables a guardar');
            variablesGrid = uigridlayout(variablesTab, [5 2]);
            variablesGrid.ColumnWidth = {'1x', '1x'};
            pressure = QUSConfigurationLogic.checkBoxField(variablesGrid, 1, ...
                'Presión instantánea (p)', settings.record_pressure);
            rmsPressure = QUSConfigurationLogic.checkBoxField(variablesGrid, 2, ...
                'Presión RMS (p_rms)', settings.record_rms);
            peakPressure = QUSConfigurationLogic.checkBoxField(variablesGrid, 3, ...
                'Presión máxima (p_max)', settings.record_peak);
            variableNote = uilabel(variablesGrid, 'Text', ...
                'Selecciona al menos una variable. El resumen se mostrará en el panel Sensor.');
            variableNote.WordWrap = 'on';
            variableNote.Layout.Row = [4 5];
            variableNote.Layout.Column = [1 2];

            if strcmp(sensorType, 'Transductor emisor')
                receiveTab = uitab(tabs, 'Title', 'Recepción');
                receiveGrid = uigridlayout(receiveTab, [4 2]);
                receiveGrid.ColumnWidth = {'1x', '1x'};
                sharedArray = QUSConfigurationLogic.checkBoxField(receiveGrid, 1, ...
                    'Usar el mismo kWaveArray para recibir', settings.shared_array);
                directivityFactor = QUSConfigurationLogic.numericField(receiveGrid, 2, ...
                    'Factor de directividad × dx', settings.directivity_size_factor);
                directivityAngle = QUSConfigurationLogic.numericField(receiveGrid, 3, ...
                    'Ángulo de directividad [rad]', settings.directivity_angle);
                note = uilabel(receiveGrid, 'Text', ...
                    'El sensor usa la geometría del transductor emisor.');
                note.Layout.Row = 4;
                note.Layout.Column = [1 2];
            else
                configurationTab = uitab(tabs, 'Title', sensorType);
                configurationGrid = uigridlayout(configurationTab, [2 1]);
                configurationGrid.RowHeight = {'fit', '1x'};
                message = uilabel(configurationGrid, 'Text', ...
                    'El plano y su posición se definen en el panel principal de Sensor.');
                message.WordWrap = 'on';
                message.Layout.Row = 1;
            end
            QUSConfigurationLogic.dialogButtons(dialog, @applySettings);

            function applySettings(~, ~)
                if ~pressure.Value && ~rmsPressure.Value && ~peakPressure.Value
                    uialert(dialog, 'Selecciona al menos una variable para guardar.', ...
                        'Variables requeridas');
                    return
                end
                settings.record_pressure = pressure.Value;
                settings.record_rms = rmsPressure.Value;
                settings.record_peak = peakPressure.Value;

                if strcmp(sensorType, 'Transductor emisor')
                    if directivityFactor.Value <= 0 || ~isfinite(directivityAngle.Value)
                        uialert(dialog, 'El factor y el ángulo de directividad no son válidos.', ...
                            'Valores inválidos');
                        return
                    end
                    settings.shared_array = sharedArray.Value;
                    settings.directivity_size_factor = directivityFactor.Value;
                    settings.directivity_angle = directivityAngle.Value;
                end

                state.advanced.sensor = settings;
                QUSConfigurationLogic.setSensorVariablesSummary(app, settings);
                QUSConfigurationLogic.storeState(app, state);
                QUSConfigurationLogic.refreshPreviewIfAvailable(app);
                delete(dialog);
            end
        end

        function openPipelineSettings(app)
            state = QUSConfigurationLogic.prepare(app);
            computation = state.advanced.computation;
            reproducibility = state.advanced.reproducibility;
            reproducibility = QUSConfigurationLogic.readRealizationControls(app, reproducibility);
            output = state.advanced.output;
            dialog = QUSConfigurationLogic.settingsDialog('Pipeline: cálculo, reproducibilidad y salida');
            tabs = uitabgroup(dialog, 'Position', [15 55 490 285]);

            calculationTab = uitab(tabs, 'Title', 'Malla y cálculo');
            calculationGrid = uigridlayout(calculationTab, [4 2]);
            calculationGrid.ColumnWidth = {'1x', '1x'};
            sizeY = QUSConfigurationLogic.numericField(calculationGrid, 1, 'Tamaño lateral [m]', computation.grid_size_y);
            pmlY = QUSConfigurationLogic.numericField(calculationGrid, 2, 'PML lateral', computation.pml_size_y);
            dataCast = QUSConfigurationLogic.dropDownField(calculationGrid, 3, ...
                'DataCast', {'gpuArray-single', 'single'}, computation.data_cast);
            plotSim = QUSConfigurationLogic.checkBoxField(calculationGrid, 4, ...
                'Mostrar PlotSim durante k-Wave', computation.plot_sim_flag);

            reproducibilityTab = uitab(tabs, 'Title', 'Reproducibilidad');
            reproducibilityGrid = uigridlayout(reproducibilityTab, [4 2]);
            reproducibilityGrid.ColumnWidth = {'1x', '1x'};
            rngSeed = QUSConfigurationLogic.numericField(reproducibilityGrid, 1, 'Semilla global', reproducibility.rng_seed);
            referenceSeed = QUSConfigurationLogic.numericField(reproducibilityGrid, 2, 'Semilla base de referencias', reproducibility.ref_seed_base);
            targetRefs = QUSConfigurationLogic.numericField(reproducibilityGrid, 3, 'nRefs para cada objetivo', reproducibility.n_refs_target);
            referenceRefs = QUSConfigurationLogic.numericField(reproducibilityGrid, 4, 'nRefs para la referencia', reproducibility.n_refs_reference);

            outputTab = uitab(tabs, 'Title', 'Salida');
            outputGrid = uigridlayout(outputTab, [2 2]);
            outputGrid.ColumnWidth = {'1x', '1x'};
            saveMedium = QUSConfigurationLogic.checkBoxField(outputGrid, 1, ...
                'Guardar vistas del medio (.fig y .png)', output.save_medium_previews);
            saveRf = QUSConfigurationLogic.checkBoxField(outputGrid, 2, ...
                'Guardar RF pre-beamforming (.mat)', output.save_rf_prebeamformed);
            QUSConfigurationLogic.dialogButtons(dialog, @applySettings);

            function applySettings(~, ~)
                values = [sizeY.Value, pmlY.Value, rngSeed.Value, referenceSeed.Value, ...
                    targetRefs.Value, referenceRefs.Value];
                if any(~isfinite(values)) || any(values <= 0)
                    uialert(dialog, 'Malla, semillas y nRefs deben ser positivos.', 'Valores inválidos');
                    return
                end
                state.advanced.computation = struct( ...
                    'grid_size_y', sizeY.Value, ...
                    'pml_size_y', round(pmlY.Value), ...
                    'data_cast', dataCast.Value, ...
                    'plot_sim_flag', plotSim.Value);
                state.advanced.reproducibility = struct( ...
                    'rng_seed', round(rngSeed.Value), ...
                    'ref_seed_base', round(referenceSeed.Value), ...
                    'n_refs_target', round(targetRefs.Value), ...
                    'n_refs_reference', round(referenceRefs.Value));
                state.advanced.output = struct( ...
                    'save_medium_previews', saveMedium.Value, ...
                    'save_rf_prebeamformed', saveRf.Value);
                QUSConfigurationLogic.configureRealizationControls(app, state.advanced.reproducibility);
                QUSConfigurationLogic.storeState(app, state);
                QUSConfigurationLogic.refreshPreviewIfAvailable(app);
                delete(dialog);
            end
        end
    end

    methods (Static, Access = private)
        function state = prepare(app)
            if isprop(app, 'GridLayout15') && isvalid(app.GridLayout15)
                app.GridLayout15.Visible = 'off';
            end
            app.TextArea.Editable = 'off';
            app.TextArea.FontName = 'Courier New';
            app.TextArea.FontSize = 11;

            if isappdata(app.UIFigure, 'QUSConfigurationState')
                state = getappdata(app.UIFigure, 'QUSConfigurationState');
                return
            end

            state = struct( ...
                'referenceDefined', false, ...
                'reference', struct(), ...
                'queue', QUSConfigurationLogic.emptyQueue(), ...
                'advanced', QUSConfigurationLogic.defaultAdvancedSettings());
            QUSConfigurationLogic.applyDefaults(app);
            QUSConfigurationLogic.storeState(app, state);
            QUSConfigurationLogic.updateExecution(app, state);
        end

        function storeState(app, state)
            setappdata(app.UIFigure, 'QUSConfigurationState', state);
        end

        function settings = defaultAdvancedSettings()
            settings.medium = struct('hom_alpha', 0.53, 'density_std', 0.04, ...
                'alpha_power', 1, 'alpha_mode', 'no_dispersion', 'sound_speed_ref', 1540);
            settings.transducer = struct('source_focus', 4e-2, 'element_pitch', 0.3e-3, ...
                'element_width', 0.25e-3, 'focal_number_tx', 4, 'focal_number_rx', 2, ...
                'n_lines', 128, 'base_translation_x', -2.7e-2, ...
                'base_translation_y', 0, 'rotation', 0);
            settings.sensor = struct('shared_array', true, 'directivity_size_factor', 10, ...
                'directivity_angle', 0, 'record_pressure', true, ...
                'record_rms', true, 'record_peak', true);
            settings.computation = struct('grid_size_y', 4e-2, 'pml_size_y', 41, ...
                'data_cast', 'gpuArray-single', 'plot_sim_flag', false);
            settings.reproducibility = struct('rng_seed', 23, 'ref_seed_base', 50000, ...
                'n_refs_target', 5, 'n_refs_reference', 10);
            settings.output = struct('save_medium_previews', true, ...
                'save_rf_prebeamformed', true);
        end

        function settings = normalizeSensorSettings(settings)
            defaults = QUSConfigurationLogic.defaultAdvancedSettings();
            defaultSensor = defaults.sensor;
            fields = fieldnames(defaultSensor);
            for index = 1:numel(fields)
                fieldName = fields{index};
                if ~isfield(settings, fieldName)
                    settings.(fieldName) = defaultSensor.(fieldName);
                end
            end
        end

        function setSensorVariablesSummary(app, settings)
            variables = {};
            if settings.record_pressure
                variables{end + 1} = 'p';
            end
            if settings.record_rms
                variables{end + 1} = 'p_rms';
            end
            if settings.record_peak
                variables{end + 1} = 'p_max';
            end

            summary = strjoin(variables, ', ');
            app.VariablesDropDown.Items = {summary};
            app.VariablesDropDown.Value = summary;
        end

        function applyDefaults(app)
            app.DimensionesEditFieldLabel.Text = 'Tamaño axial:';
            app.ResolucinEditFieldLabel.Text = 'PPW:';
            app.mLabel_3.Text = '';
            app.DescripcinLabel.Text = 'Profundidad:';
            app.DescripcinLabel_2.Text = '[m]';
            app.DimensionesEditField.Value = 5.6e-2;
            app.ResolucinEditField.Value = 6;
            app.PMLCantcapasEditField.Value = 41;
            app.CFLEditField.Value = 0.3;
            app.VelsonidoEditField.Value = 1540;
            app.DensidadEditField.Value = 1000;
            app.FrecuenciaEditField.Value = 6.66e6;
            app.AmplitudEditField_2.Value = 1e6;
            app.NciclosEditField.Value = 3.5;
            app.NombreEditField.Value = 'homogeneous_benchmark';
            app.TiempoEditField.Value = 5.5e-2;
            QUSConfigurationLogic.setDropDown(app.SolverDropDown, 'kspaceFirstoOrder2D');
            defaults = QUSConfigurationLogic.defaultAdvancedSettings();
            QUSConfigurationLogic.configureRealizationControls(app, defaults.reproducibility);
            app.EstadoEditField.Value = 'Sin configuración';
        end

        function configureRealizationControls(app, reproducibility)
            % Estos controles aplican a todos los casos de la cola. El último
            % caso de referencia usa el segundo valor, igual que el pipeline.
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

        function configuration = readCurrentConfiguration(app, advanced)
            advanced.sensor = QUSConfigurationLogic.normalizeSensorSettings(advanced.sensor);
            configuration.geometry = struct('grid_size_x', app.DimensionesEditField.Value, ...
                'grid_size_y', advanced.computation.grid_size_y, 'ppw', app.ResolucinEditField.Value, ...
                'pml_size_x', app.PMLCantcapasEditField.Value, ...
                'pml_size_y', advanced.computation.pml_size_y, 'cfl', app.CFLEditField.Value, ...
                'depth', app.TiempoEditField.Value);
            configuration.medium = struct('model', char(app.ModeloDropDown.Value), ...
                'sound_speed', app.VelsonidoEditField.Value, 'density', app.DensidadEditField.Value, ...
                'hom_alpha', advanced.medium.hom_alpha, 'density_std', advanced.medium.density_std, ...
                'alpha_power', advanced.medium.alpha_power, 'alpha_mode', advanced.medium.alpha_mode, ...
                'sound_speed_ref', advanced.medium.sound_speed_ref);
            configuration.transducer = struct('type', char(app.TipoDropDown.Value), ...
                'signal', char(app.SealDropDown.Value), 'beam_mode', char(app.MododehazDropDown.Value), ...
                'frequency', app.FrecuenciaEditField.Value, 'amplitude', app.AmplitudEditField_2.Value, ...
                'cycles', app.NciclosEditField.Value, ...
                'source_focus', advanced.transducer.source_focus, 'element_pitch', advanced.transducer.element_pitch, ...
                'element_width', advanced.transducer.element_width, 'focal_number_tx', advanced.transducer.focal_number_tx, ...
                'focal_number_rx', advanced.transducer.focal_number_rx, 'n_lines', advanced.transducer.n_lines, ...
                'base_translation_x', advanced.transducer.base_translation_x, ...
                'base_translation_y', advanced.transducer.base_translation_y, 'rotation', advanced.transducer.rotation);
            configuration.sensor = struct('type', char(app.TipoDropDown_2.Value), ...
                'plane', char(app.PlanoDropDown.Value), 'plane_position', char(app.PosicindelplanoDropDown.Value), ...
                'variables', char(app.VariablesDropDown.Value), 'shared_array', advanced.sensor.shared_array, ...
                'directivity_size_factor', advanced.sensor.directivity_size_factor, ...
                'directivity_angle', advanced.sensor.directivity_angle, ...
                'record_pressure', advanced.sensor.record_pressure, ...
                'record_rms', advanced.sensor.record_rms, ...
                'record_peak', advanced.sensor.record_peak);
            configuration.computation = struct('data_cast', advanced.computation.data_cast, ...
                'plot_sim_flag', advanced.computation.plot_sim_flag, ...
                'solver', char(app.SolverDropDown.Value), 'dt_mode', char(app.dtDropDown.Value));
            reproducibility = QUSConfigurationLogic.readRealizationControls( ...
                app, advanced.reproducibility);
            configuration.reproducibility = reproducibility;
            configuration.output = advanced.output;
            configuration.experiment = struct('name', char(app.NombreEditField.Value));
        end

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
            if configuration.geometry.cfl <= 0 || configuration.geometry.cfl > 1
                error('CFL debe ser mayor que 0 y menor o igual que 1.');
            end
            if configuration.medium.hom_alpha < 0 || configuration.medium.density_std < 0
                error('La atenuación y su desviación estándar no pueden ser negativas.');
            end
            if isempty(strtrim(configuration.experiment.name))
                error('Escribe un nombre para el experimento antes de pulsar Set.');
            end
        end

        function changes = detectChanges(reference, current)
            referenceRecords = QUSConfigurationLogic.records(reference);
            currentRecords = QUSConfigurationLogic.records(current);
            changes = struct('section', {}, 'parameter', {}, 'value', {}, 'reference', {});
            for index = 1:numel(currentRecords)
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
            if isempty(state.queue)
                lines = [lines; ""; "TIPO: (i) CONFIGURACIÓN ÚNICA"; ""; ...
                    "SIMULACIÓN 1"; "------------------------------------------------"];
                lines = QUSConfigurationLogic.appendReference(lines, state.reference);
                app.TextArea.Value = cellstr([lines; ""; "------------------------------------------------"; "Configuraciones: 1"]);
                app.EstadoEditField.Value = 'Referencia definida';
                return
            end

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
                            QUSConfigurationLogic.formatValues(item.values) + ", REF=" + ...
                            QUSConfigurationLogic.formatValue(item.reference) + "]";
                    end
                end
            end
            app.TextArea.Value = cellstr([lines; ""; "================================================"; ...
                "Secciones variables: " + numel(sections)]);
            app.EstadoEditField.Value = sprintf('Referencia + %d sección(es)', numel(sections));
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
                            QUSConfigurationLogic.formatValue(item.value);
                    end
                end
            end
        end

        function items = records(configuration)
            configuration.sensor = QUSConfigurationLogic.normalizeSensorSettings(configuration.sensor);
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
            items(end + 1) = add('Medio acústico', 'Atenuación [dB/(MHz^y cm)]', configuration.medium.hom_alpha);
            items(end + 1) = add('Medio acústico', 'Desviación de densidad', configuration.medium.density_std);
            items(end + 1) = add('Medio acústico', 'Alpha power', configuration.medium.alpha_power);
            items(end + 1) = add('Medio acústico', 'Modo de absorción', string(configuration.medium.alpha_mode));
            items(end + 1) = add('Medio acústico', 'Velocidad de referencia [m/s]', configuration.medium.sound_speed_ref);
            items(end + 1) = add('Transductor emisor', 'Tipo', string(configuration.transducer.type));
            items(end + 1) = add('Transductor emisor', 'Señal', string(configuration.transducer.signal));
            items(end + 1) = add('Transductor emisor', 'Modo de haz', string(configuration.transducer.beam_mode));
            items(end + 1) = add('Transductor emisor', 'Frecuencia [Hz]', configuration.transducer.frequency);
            items(end + 1) = add('Transductor emisor', 'Amplitud [Pa]', configuration.transducer.amplitude);
            items(end + 1) = add('Transductor emisor', 'N.º ciclos', configuration.transducer.cycles);
            items(end + 1) = add('Transductor emisor', 'Foco [m]', configuration.transducer.source_focus);
            items(end + 1) = add('Transductor emisor', 'Pitch [m]', configuration.transducer.element_pitch);
            items(end + 1) = add('Transductor emisor', 'Ancho [m]', configuration.transducer.element_width);
            items(end + 1) = add('Transductor emisor', 'F-number Tx', configuration.transducer.focal_number_tx);
            items(end + 1) = add('Transductor emisor', 'F-number Rx', configuration.transducer.focal_number_rx);
            items(end + 1) = add('Transductor emisor', 'Líneas de escaneo', configuration.transducer.n_lines);
            items(end + 1) = add('Transductor emisor', 'Traslación axial [m]', configuration.transducer.base_translation_x);
            items(end + 1) = add('Transductor emisor', 'Traslación lateral [m]', configuration.transducer.base_translation_y);
            items(end + 1) = add('Transductor emisor', 'Rotación [rad]', configuration.transducer.rotation);
            items(end + 1) = add('Sensor', 'Tipo', string(configuration.sensor.type));
            items(end + 1) = add('Sensor', 'Plano', string(configuration.sensor.plane));
            items(end + 1) = add('Sensor', 'Posición', string(configuration.sensor.plane_position));
            items(end + 1) = add('Sensor', 'Variables', string(configuration.sensor.variables));
            items(end + 1) = add('Sensor', 'Arreglo compartido', configuration.sensor.shared_array);
            items(end + 1) = add('Sensor', 'Factor de directividad', configuration.sensor.directivity_size_factor);
            items(end + 1) = add('Sensor', 'Ángulo de directividad [rad]', configuration.sensor.directivity_angle);
            items(end + 1) = add('Sensor', 'Guardar p', configuration.sensor.record_pressure);
            items(end + 1) = add('Sensor', 'Guardar p_rms', configuration.sensor.record_rms);
            items(end + 1) = add('Sensor', 'Guardar p_max', configuration.sensor.record_peak);
            items(end + 1) = add('Cálculo', 'DataCast', string(configuration.computation.data_cast));
            items(end + 1) = add('Cálculo', 'PlotSim', configuration.computation.plot_sim_flag);
            items(end + 1) = add('Cálculo', 'Solver', string(configuration.computation.solver));
            items(end + 1) = add('Cálculo', 'Modo dt', string(configuration.computation.dt_mode));
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

        function text = formatValue(value)
            if islogical(value)
                text = string(value);
            elseif isnumeric(value)
                text = string(num2str(value, '%.8g'));
            else
                text = string(value);
            end
        end

        function queue = emptyQueue()
            queue = struct('section', {}, 'parameter', {}, 'values', {}, 'reference', {});
        end

        function advanced = advancedFromReference(reference)
            advanced.medium = struct('hom_alpha', reference.medium.hom_alpha, ...
                'density_std', reference.medium.density_std, 'alpha_power', reference.medium.alpha_power, ...
                'alpha_mode', reference.medium.alpha_mode, 'sound_speed_ref', reference.medium.sound_speed_ref);
            advanced.transducer = rmfield(reference.transducer, ...
                {'type', 'signal', 'beam_mode', 'frequency', 'amplitude', 'cycles'});
            advanced.sensor = QUSConfigurationLogic.normalizeSensorSettings(reference.sensor);
            advanced.computation = struct('grid_size_y', reference.geometry.grid_size_y, ...
                'pml_size_y', reference.geometry.pml_size_y, ...
                'data_cast', reference.computation.data_cast, ...
                'plot_sim_flag', reference.computation.plot_sim_flag);
            advanced.reproducibility = reference.reproducibility;
            advanced.output = reference.output;
        end

        function applyConfiguration(app, configuration)
            app.DimensionesEditField.Value = configuration.geometry.grid_size_x;
            app.ResolucinEditField.Value = configuration.geometry.ppw;
            app.PMLCantcapasEditField.Value = configuration.geometry.pml_size_x;
            app.CFLEditField.Value = configuration.geometry.cfl;
            app.TiempoEditField.Value = configuration.geometry.depth;
            QUSConfigurationLogic.setDropDown(app.ModeloDropDown, configuration.medium.model);
            app.VelsonidoEditField.Value = configuration.medium.sound_speed;
            app.DensidadEditField.Value = configuration.medium.density;
            QUSConfigurationLogic.setDropDown(app.TipoDropDown, configuration.transducer.type);
            QUSConfigurationLogic.setDropDown(app.SealDropDown, configuration.transducer.signal);
            QUSConfigurationLogic.setDropDown(app.MododehazDropDown, configuration.transducer.beam_mode);
            app.FrecuenciaEditField.Value = configuration.transducer.frequency;
            app.AmplitudEditField_2.Value = configuration.transducer.amplitude;
            app.NciclosEditField.Value = configuration.transducer.cycles;
            QUSConfigurationLogic.setDropDown(app.TipoDropDown_2, configuration.sensor.type);
            SensorPanelLogic.updateForSensorType(app);
            QUSConfigurationLogic.setDropDown(app.PlanoDropDown, configuration.sensor.plane);
            QUSConfigurationLogic.setDropDown(app.PosicindelplanoDropDown, configuration.sensor.plane_position);
            QUSConfigurationLogic.setDropDown(app.VariablesDropDown, configuration.sensor.variables);
            QUSConfigurationLogic.setDropDown(app.SolverDropDown, configuration.computation.solver);
            QUSConfigurationLogic.setDropDown(app.dtDropDown, configuration.computation.dt_mode);
            app.NombreEditField.Value = configuration.experiment.name;
            QUSConfigurationLogic.configureRealizationControls(app, configuration.reproducibility);
        end

        function parameters = pipelineParametersFromConfiguration(configuration)
            % Traduce la estructura de la GUI a los nombres del pipeline
            % original. Esto hace que el archivo MAT sea auditable por sí
            % mismo y evita números literales dispersos en el .m generado.
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
                'directivity_size_factor', configuration.sensor.directivity_size_factor, ...
                'directivity_angle', configuration.sensor.directivity_angle, ...
                'nRefsTarget', configuration.reproducibility.n_refs_target, ...
                'nRefsReference', configuration.reproducibility.n_refs_reference, ...
                'refSeedBase', configuration.reproducibility.ref_seed_base, ...
                'saveMediumPreviews', configuration.output.save_medium_previews, ...
                'saveRfPrebeamformed', configuration.output.save_rf_prebeamformed);
        end

        function setDropDown(control, value)
            value = char(string(value));
            if any(strcmp(control.Items, value))
                control.Value = value;
            end
        end

        function writePipelineScript(pipelinePath, ~, configuration)
            % El MAT queda disponible para Open Config, pero el pipeline se
            % genera autocontenido para poder enviarlo solo al cluster.
            reference = configuration.reference;
            if ~strcmpi(reference.medium.model, 'Homogeneo')
                error(['El generador actual crea el pipeline homogéneo de k-Wave. ' ...
                    'Selecciona el modelo Homogeneo para esta primera versión.']);
            end

            cases = QUSConfigurationLogic.materializeExperimentCases(reference, configuration.queue);
            isAlphaSweep = ~isempty(cases) && all([cases.isAlphaSweep]);
            lines = [ ...
                "%% Homogeneous reference simulations"; "clearvars"; "clc"; ""; ...
                "scriptFolder = fileparts(mfilename('fullpath'));"; ...
                "if isempty(scriptFolder), scriptFolder = pwd; end;"; ...
                "cd(scriptFolder);"; ...
                "parallel.gpu.enableCUDAForwardCompatibility(true)"; ""; ...
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
                "    %% Grid"; ""; ...
                "    % Calculate the grid spacing based on the PPW and F0"; ...
                "    dx = c0 / (ppw * source_f0);                                  % [m]"; ""; ...
                "    % Compute the size of the grid"; ...
                "    Nx = roundEven(grid_size_x / dx);"; ...
                "    Ny = roundEven(grid_size_y / dx);"; ""; ...
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
                "    no_Tx_elements = floor((element_num - element_num_Tx) / 2);"; ...
                "    amp_vector(1:no_Tx_elements) = 0;"; ...
                "    amp_vector(end-no_Tx_elements+1:end) = 0;"; ""; ...
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
                "    yCords = ((0:nLines-1) - (nLines-1)/2) * element_pitch;"; ""; ...
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
                "        %% Homogeneous medium"; ""; ...
                "        medium = makeHomogeneousDensityOnlyMedium( ..."; ...
                "            Nx, Ny, c0, rho0, density_std, hom_alpha);"; ""; ...
                "        medium.alpha_power = alpha_power;"; ...
                "        medium.alpha_mode = alpha_mode;"; ...
                "        medium.sound_speed_ref = sound_speed_ref;"; ""; ...
                "        %% Medium properties"; ...
                "        % Same sound-speed, density and absorption preview as the baseline."; ...
                "        if saveMediumPreviews"; ...
                "            saveMediumPreview(kgrid, medium, base_translation, outputFolder, iRef);"; ...
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
                "                'focal_number_Tx', 'focal_number_Rx', 'nLines', 'depth', ..."; ...
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
                "%% Local helper functions"; ""; ...
                QUSConfigurationLogic.generatedCaseParametersFunction(cases, isAlphaSweep); ""; ...
                QUSConfigurationLogic.generatedHelperFunctions()];

            fileId = fopen(pipelinePath, 'w');
            if fileId == -1
                error('No se pudo crear el pipeline: %s.', pipelinePath);
            end
            cleanup = onCleanup(@() fclose(fileId));
            fprintf(fileId, '%s\n', lines);
            clear cleanup
        end

        function path = queuePath(item)
            path = '';
            key = [char(item.section), '|', char(item.parameter)];
            paths = containers.Map( ...
                {'Geometría y malla|Tamaño axial [m]', 'Geometría y malla|Tamaño lateral [m]', ...
                 'Geometría y malla|PPW', 'Geometría y malla|PML axial', ...
                 'Geometría y malla|PML lateral', 'Geometría y malla|CFL', ...
                 'Geometría y malla|Profundidad [m]', 'Medio acústico|Modelo', ...
                 'Medio acústico|Velocidad de sonido [m/s]', 'Medio acústico|Densidad [kg/m^3]', ...
                 'Medio acústico|Atenuación [dB/(MHz^y cm)]', 'Medio acústico|Desviación de densidad', ...
                 'Medio acústico|Alpha power', 'Medio acústico|Modo de absorción', ...
                 'Medio acústico|Velocidad de referencia [m/s]', 'Transductor emisor|Frecuencia [Hz]', ...
                 'Transductor emisor|Amplitud [Pa]', 'Transductor emisor|N.º ciclos', ...
                 'Transductor emisor|Foco [m]', 'Transductor emisor|Pitch [m]', ...
                 'Transductor emisor|Ancho [m]', 'Transductor emisor|F-number Tx', ...
                 'Transductor emisor|F-number Rx', 'Transductor emisor|Líneas de escaneo', ...
                 'Transductor emisor|Traslación axial [m]', 'Transductor emisor|Traslación lateral [m]', ...
                 'Transductor emisor|Rotación [rad]', 'Sensor|Factor de directividad', ...
                 'Sensor|Ángulo de directividad [rad]', 'Cálculo|DataCast', ...
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
                 'transducer.base_translation_x', 'transducer.base_translation_y', 'transducer.rotation', ...
                 'sensor.directivity_size_factor', 'sensor.directivity_angle', 'computation.data_cast', ...
                 'computation.plot_sim_flag', 'computation.solver', 'reproducibility.rng_seed', ...
                 'reproducibility.ref_seed_base', 'reproducibility.n_refs_target', ...
                 'reproducibility.n_refs_reference'});
            if isKey(paths, key)
                path = paths(key);
            end
        end

        function literal = matlabCellLiteral(values)
            elements = strings(1, numel(values));
            for index = 1:numel(values)
                elements(index) = QUSConfigurationLogic.matlabLiteral(values(index));
            end
            literal = '{' + strjoin(elements, ', ') + '}';
        end

        function literal = matlabLiteral(value)
            if islogical(value)
                literal = string(lower(mat2str(value)));
            elseif isnumeric(value)
                if isscalar(value)
                    literal = string(num2str(value, '%.16g'));
                else
                    literal = string(mat2str(value, 16));
                end
            else
                literal = "'" + QUSConfigurationLogic.escapeMatlabText(value) + "'";
            end
        end

        function lines = matlabStructureAssignments(variableName, value)
            % Serializa una estructura como asignaciones MATLAB legibles.
            % Es el snapshot autónomo que permite ejecutar el M sin su MAT.
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

        function values = pipelineCaseValues(parameters, isReference, simulationName)
            % Snapshot de un caso: valores literales que viajarán en el M.
            % El MAT permanece solo como formato de lectura para Open Config.
            if isReference
                nRefs = parameters.nRefsReference;
            else
                nRefs = parameters.nRefsTarget;
            end
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
                'directivity_angle', parameters.directivity_angle, 'solverName', parameters.solverName);
        end

        function lines = generatedCaseParametersFunction(cases, isAlphaSweep)
            % Encapsula las variaciones de la GUI al final del pipeline. Así
            % el cuerpo principal conserva la organización del baseline.
            lines = [ ...
                "function parameters = getGuiCaseParameters(ii, refValues)"; ...
                "    % Snapshot autónomo de los valores seleccionados en la GUI."; ...
                "    % No carga MAT: este M se puede enviar solo al cluster."; ...
                "    switch ii"];
            for index = 1:numel(cases)
                scientificParameters = QUSConfigurationLogic.pipelineParametersFromConfiguration( ...
                    cases(index).configuration);
                values = QUSConfigurationLogic.pipelineCaseValues(scientificParameters, ...
                    cases(index).isReference, ...
                    QUSConfigurationLogic.materializedSimulationName(cases(index)));
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

        function lines = pipelineLiteralAssignments(parameters, isReference, simulationName)
            % Conservado para compatibilidad con herramientas internas.
            values = QUSConfigurationLogic.pipelineCaseValues(parameters, isReference, simulationName);
            lines = strings(0, 1);
            fields = fieldnames(values);
            for index = 1:numel(fields)
                fieldName = fields{index};
                lines(end + 1, 1) = string(fieldName) + " = " + ...
                    QUSConfigurationLogic.matlabLiteral(values.(fieldName)) + ";";
            end
        end

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

        function text = escapeMatlabText(value)
            text = strrep(char(string(value)), '''', '''''');
        end

        function folder = codeFolder(app, experimentFolderName)
            if isprop(app, 'Tree') && isprop(app, 'UIFigure')
                parentFolder = ProjectExplorerLogic.getOutputParentFolder(app);
            else
                parentFolder = fullfile(fileparts(mfilename('fullpath')), 'code');
            end
            folder = fullfile(parentFolder, experimentFolderName);
        end

        function lines = generatedHelperFunctions()
            lines = [ ...
                "function saveMediumPreview(kgrid, medium, base_translation, outputFolder, iRef)"; ...
                "    rx = kgrid.y;"; ...
                "    rz = kgrid.x - base_translation(1);"; ...
                "    figMedium = figure('Units', 'centimeters', 'Position', [5 5 25 10], 'Visible', 'off');"; ...
                "    tiledlayout(1, 3)"; ...
                "    nexttile; imagesc(100 * rx(1,:), 100 * rz(:,1), medium.sound_speed);"; ...
                "    xlabel('x [cm]'); ylabel('z [cm]'); title('Sound speed'); c = colorbar; ylabel(c, 'm/s'); axis image"; ...
                "    nexttile; imagesc(100 * rx(1,:), 100 * rz(:,1), medium.density);"; ...
                "    xlabel('x [cm]'); ylabel('z [cm]'); title('Density'); c = colorbar; ylabel(c, 'kg/m^3'); axis image"; ...
                "    nexttile; imagesc(100 * rx(1,:), 100 * rz(:,1), medium.alpha_coeff, [0.4 1.0]);"; ...
                "    xlabel('x [cm]'); ylabel('z [cm]'); title('Absorption'); c = colorbar; ylabel(c, 'dB/cm/MHz'); axis image"; ...
                "    sgtitle(sprintf('Homogeneous reference %03d', iRef))"; ...
                "    savefig(figMedium, fullfile(outputFolder, sprintf('medium_homRef_%03d.fig', iRef)));"; ...
                "    saveas(figMedium, fullfile(outputFolder, sprintf('medium_homRef_%03d.png', iRef)));"; ...
                "    close(figMedium)"; ...
                "end"; ""; ...
                "function sensor_data = runKWaveSolver(solverName, kgrid, medium, source, sensor, input_args)"; ...
                "    if strcmpi(solverName, 'kspaceFirstoOrder2D')"; ...
                "        solverName = 'kspaceFirstOrder2D';"; ...
                "    end"; ...
                "    sensor_data = feval(solverName, kgrid, medium, source, sensor, input_args{:});"; ...
                "end"; ""; ...
                "function medium = makeHomogeneousDensityOnlyMedium(Nx, Ny, c0, rho0, densityStd, alpha)"; ...
                "    medium.sound_speed = c0 * ones(Nx, Ny);"; ...
                "    medium.density = rho0 .* (1 + densityStd * randn(Nx, Ny));"; ...
                "    medium.alpha_coeff = alpha * ones(Nx, Ny);"; ...
                "end"];
        end

        function name = safeFileName(name)
            name = regexprep(char(name), '[^A-Za-z0-9_-]', '_');
            if isempty(name)
                name = 'qus_benchmark';
            end
        end

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

        function showError(app, message)
            app.EstadoEditField.Value = 'Configuración inválida';
            uialert(app.UIFigure, message, 'No se pudo completar la acción');
        end
    end
end
