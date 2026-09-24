classdef PreviewLogic
    % Logica para el preview 2D de la configuración. 
    methods (Static)

        function initialize(app)
            % Inicializa los valores físicos del baseline antes de dibujar.
            % startupFcn crea el preview antes de su llamada final a onTest;
            % sin este paso los ejes aparecen vacíos aunque exista una
            % configuración inicial definida para la app.
            QUSConfigurationLogic.onTest(app);

            % Mantiene la nomenclatura científica de las tres pestañas.
            app.GeometricoTab.Title = 'Geometric';
            if isprop(app, 'PropiedadesTab')
                app.PropiedadesTab.Title = 'Properties';
            end
            app.SealTab.Title = 'Signal';
            PreviewLogic.createPreviewAxes(app);
            PreviewLogic.installRefreshCallbacks(app);
            PreviewLogic.refresh(app);
        end
        
        % V2 no tiene pestañas de preview. V3 sí, y puede redibujarse.
        function refreshIfAvailable(app)
            if isprop(app, 'GeometricoTab') && isprop(app, 'SealTab')
                PreviewLogic.refresh(app);
            end
        end

        % Redibuja la vista previa con los valores actuales de la interfaz.
        % No modifica la configuración de referencia ni la cola.
        function refresh(app)

            handles = getappdata(app.UIFigure, 'PreviewLogicHandles');
            if isempty(handles) || ~isvalid(handles.geometryAxes)
                PreviewLogic.createPreviewAxes(app);
                PreviewLogic.installRefreshCallbacks(app);
                handles = getappdata(app.UIFigure, 'PreviewLogicHandles');
            end

            if ~PreviewLogic.hasSavedConfiguration(app)
                PreviewLogic.drawEmptyPreview(handles);
                return
            end

            configuration = PreviewLogic.readConfiguration(app);
            PreviewLogic.drawGeometry(handles.geometryAxes, configuration);
            PreviewLogic.drawMediumDomain(handles.mediumAxes, configuration);
            if isfield(handles, 'soundSpeedAxes') && isvalid(handles.soundSpeedAxes)
                PreviewLogic.drawMediumProperties(handles, configuration);
            end
            PreviewLogic.drawSignal(handles.timeAxes, handles.frequencyAxes, configuration);
        end
    end

    methods (Static, Access = private)

        function createPreviewAxes(app)
            delete(app.GeometricoTab.Children);
            delete(app.SealTab.Children);
            
            geometryGrid = uigridlayout(app.GeometricoTab, [1 2]);
            geometryGrid.ColumnWidth = {'1x', '1x'};
            geometryGrid.ColumnSpacing = 10;
            geometryGrid.Padding = [10 10 10 10];

            geometryAxes = uiaxes(geometryGrid);
            mediumAxes = uiaxes(geometryGrid);

            propertyAxes = [];
            if isprop(app, 'PropiedadesTab')
                delete(app.PropiedadesTab.Children);
                propertiesGrid = uigridlayout(app.PropiedadesTab, [1 3]);
                
                % Cada mapa tiene su propia barra de color. El margen evita
                % que su etiqueta invada el eje z del mapa vecino.
                propertiesGrid.ColumnWidth = {'1x', '1x', '1x'};
                propertiesGrid.ColumnSpacing = 45;
                propertiesGrid.Padding = [22 10 22 10];
                propertyAxes = [uiaxes(propertiesGrid), uiaxes(propertiesGrid), ...
                    uiaxes(propertiesGrid)];
            end

            signalGrid = uigridlayout(app.SealTab, [1 2]);
            signalGrid.ColumnWidth = {'1x', '1x'};
            signalGrid.ColumnSpacing = 10;
            signalGrid.Padding = [10 10 10 10];

            timeAxes = uiaxes(signalGrid);
            frequencyAxes = uiaxes(signalGrid);

            handles = struct( ...
                'geometryAxes', geometryAxes, ...
                'mediumAxes', mediumAxes, ...
                'timeAxes', timeAxes, ...
                'frequencyAxes', frequencyAxes);
            if ~isempty(propertyAxes)
                handles.soundSpeedAxes = propertyAxes(1);
                handles.densityAxes = propertyAxes(2);
                handles.absorptionAxes = propertyAxes(3);
            end
            axesHandles = [geometryAxes, mediumAxes, timeAxes, frequencyAxes, propertyAxes];
            for axesIndex = 1:numel(axesHandles)
                if isprop(axesHandles(axesIndex), 'Toolbar')
                    axesHandles(axesIndex).Toolbar.Visible = 'off';
                end
            end
            setappdata(app.UIFigure, 'PreviewLogicHandles', handles);
        end

        function hasConfiguration = hasSavedConfiguration(app)
            hasConfiguration = false;
            if isappdata(app.UIFigure, 'QUSConfigurationState')
                state = getappdata(app.UIFigure, 'QUSConfigurationState');
                hasConfiguration = state.referenceDefined;
            end
        end

        function drawEmptyPreview(handles)
            PreviewLogic.drawEmptyGrid(handles.geometryAxes, ...
                'Geometry preview', 'x [cm]', 'z [cm]');
            PreviewLogic.drawEmptyGrid(handles.mediumAxes, ...
                'Medium preview', 'x [cm]', 'z [cm]');
            if isfield(handles, 'soundSpeedAxes') && isvalid(handles.soundSpeedAxes)
                PreviewLogic.drawEmptyGrid(handles.soundSpeedAxes, ...
                    'Sound speed', 'x lateral [cm]', 'z [cm]');
                PreviewLogic.drawEmptyGrid(handles.densityAxes, ...
                    'Density', 'x lateral [cm]', 'z [cm]');
                PreviewLogic.drawEmptyGrid(handles.absorptionAxes, ...
                    'ACS', 'x lateral [cm]', 'z [cm]');
            end
            PreviewLogic.drawEmptyGrid(handles.timeAxes, ...
                'Signal preview', 'Time [µs]', 'Pressure [MPa]');
            PreviewLogic.drawEmptyGrid(handles.frequencyAxes, ...
                'Spectrum preview', 'Frequency [MHz]', 'Amplitude [MPa]');
        end

        function drawEmptyGrid(axesHandle, titleText, xLabelText, yLabelText)
            cla(axesHandle);
            colorbar(axesHandle, 'off');
            axis(axesHandle, 'on');
            box(axesHandle, 'on');
            grid(axesHandle, 'on');
            xlim(axesHandle, [0 1]);
            ylim(axesHandle, [0 1]);
            title(axesHandle, titleText);
            xlabel(axesHandle, xLabelText);
            ylabel(axesHandle, yLabelText);
        end

        function installRefreshCallbacks(app)
            controls = { ...
                app.DimensionesEditField, app.ResolucinEditField, ...
                app.PMLCantcapasEditField, app.CFLEditField, ...
                app.VelsonidoEditField, app.DensidadEditField, ...
                app.FrecuenciaEditField, app.AmplitudEditField_2, ...
                app.NciclosEditField, app.ModeloDropDown, ...
                app.SealDropDown, app.MododehazDropDown};

            for index = 1:numel(controls)
                if controls{index} == app.ModeloDropDown
                    % El modelo cambia la estructura del medio, pero el
                    % preview se redibuja únicamente al pulsar Set o elegir
                    % un Group ya guardado.
                    controls{index}.ValueChangedFcn = @(~, ~) ...
                        QUSConfigurationLogic.onMediumModelChanged(app);
                else
                    controls{index}.ValueChangedFcn = @(~, ~) ...
                        PreviewLogic.onMainControlChanged(app);
                end
            end
        end

        function onMainControlChanged(app)
            QUSConfigurationLogic.updateCalculatedTime(app);
        end

        function configuration = readConfiguration(app)
            [configuration.axialSize, configuration.lateralSize] = ...
                QUSConfigurationLogic.currentGridSize(app);
            configuration.ppw = app.ResolucinEditField.Value;
            configuration.pmlLayers = app.PMLCantcapasEditField.Value;
            configuration.cfl = app.CFLEditField.Value;
            configuration.depth = app.DimensionesEditField.Value;
            configuration.soundSpeed = app.VelsonidoEditField.Value;
            configuration.density = app.DensidadEditField.Value;
            
            % Los controles de la interfaz están expresados en MHz y MPa.
            % El preview y k-Wave trabajan en Hz y Pa.
            configuration.frequency = app.FrecuenciaEditField.Value * 1e6;
            configuration.amplitude = app.AmplitudEditField_2.Value * 1e6;
            configuration.cycles = app.NciclosEditField.Value;
            configuration.dx = configuration.soundSpeed / ...
                (configuration.ppw * configuration.frequency);
            configuration.model = char(string(app.ModeloDropDown.Value));
            configuration.transducerType = char(string(app.TipoDropDown.Value));
            configuration.signalType = char(string(app.SealDropDown.Value));
            configuration.beamMode = char(string(app.MododehazDropDown.Value));

            state = [];
            if isappdata(app.UIFigure, 'QUSConfigurationState')
                state = getappdata(app.UIFigure, 'QUSConfigurationState');
            end

            if isempty(state)
                configuration.lateralSize = NaN;
                configuration.elementPitch = NaN;
                configuration.elementWidth = NaN;
                configuration.focus = NaN;
                configuration.fNumberTx = NaN;
                configuration.fNumberRx = NaN;
                configuration.emitterAxial = NaN;
                configuration.emitterLateral = NaN;
                configuration.rotation = NaN;
                return
            end

            configuration.lateralSize = state.advanced.computation.grid_size_y;
            configuration.elementPitch = state.advanced.transducer.element_pitch;
            configuration.elementWidth = state.advanced.transducer.element_width;
            configuration.focus = state.advanced.transducer.source_focus;
            configuration.fNumberTx = state.advanced.transducer.focal_number_tx;
            configuration.fNumberRx = state.advanced.transducer.focal_number_rx;
            configuration.emitterAxial = state.advanced.transducer.base_translation_x;
            configuration.emitterLateral = state.advanced.transducer.base_translation_y;
            configuration.rotation = state.advanced.transducer.rotation;
            configuration.nLines = state.advanced.transducer.n_lines;
            configuration.densityStd = state.advanced.medium.density_std;
            configuration.homAlpha = state.advanced.medium.hom_alpha;
            if isfield(state.advanced.medium, 'config')
                configuration.mediumConfig = state.advanced.medium.config;
            else
                configuration.mediumConfig = MediumConfigurationLogic.defaultConfig();
            end
            configuration.rngSeed = state.advanced.reproducibility.rng_seed;
        end

        function drawGeometry(axesHandle, configuration)
            cla(axesHandle);
            if ~PreviewLogic.isGeometryValid(configuration)
                PreviewLogic.showIncomplete(axesHandle, 'Completa la geometría y el emisor para previsualizarlos.');
                return
            end

            PreviewLogic.drawDomain(axesHandle, configuration, true);
            title(axesHandle, '2-D domain, PML and transmitter');
        end

        function drawMediumDomain(axesHandle, configuration)
            cla(axesHandle);
            if ~PreviewLogic.isGeometryValid(configuration)
                PreviewLogic.showIncomplete(axesHandle, 'El dominio del medio aparecerá con una geometría válida.');
                return
            end

            PreviewLogic.drawDomain(axesHandle, configuration, false);
            title(axesHandle, 'Medium domain and PML');
        end

        function drawMediumProperties(handles, configuration)
            axesHandles = [handles.soundSpeedAxes, handles.densityAxes, ...
                handles.absorptionAxes];
            if ~PreviewLogic.isGeometryValid(configuration)
                for axesHandle = axesHandles
                    PreviewLogic.showIncomplete(axesHandle, ...
                        'Las propiedades aparecerán con una geometría válida.');
                end
                return
            end

            frame = PreviewLogic.geometryFrame(configuration);
            lateral = linspace(frame.lateralMin, frame.lateralMax, 160) * 100;
            axial = linspace(frame.axialMin, frame.axialMax, 200) * 100;
            mediumConfig = configuration.mediumConfig;
            mediumConfig.background.sound_speed = configuration.soundSpeed;
            mediumConfig.background.density = configuration.density;
            [soundSpeed, density, acs] = MediumConfigurationLogic.maps( ...
                mediumConfig, axial * 10, lateral * 10, configuration.rngSeed);

            PreviewLogic.drawPropertyMap(handles.soundSpeedAxes, lateral, axial, soundSpeed, ...
                'Sound speed', 'm/s', [], configuration);
            PreviewLogic.drawPropertyMap(handles.densityAxes, lateral, axial, density, ...
                'Density', 'kg/m^3', [], configuration);
            PreviewLogic.drawPropertyMap(handles.absorptionAxes, lateral, axial, acs, ...
                'ACS', 'ACS [dB/cm/MHz]', [0.35, 1.05], configuration);
        end

        function drawPropertyMap(axesHandle, lateral, axial, mediumMap, titleText, colorbarText, limits, configuration)
            cla(axesHandle);
            % showIncomplete oculta el eje; cada redibujado válido debe
            % restaurar sus reglas, marcas y etiquetas dimensionales.
            axis(axesHandle, 'on');
            imagesc(axesHandle, lateral, axial, mediumMap);
            set(axesHandle, 'YDir', 'reverse');
            axis(axesHandle, 'image');
            box(axesHandle, 'on');
            grid(axesHandle, 'off');
            axesHandle.LineWidth = 1.2;
            colormap(axesHandle, turbo(256));
            if ~isempty(limits)
                clim(axesHandle, limits);
            end
            colorbarHandle = colorbar(axesHandle);
            colorbarHandle.Label.String = colorbarText;
            if isequal(limits, [0.35, 1.05])
                colorbarHandle.Ticks = 0.4:0.1:1.0;
                colorbarHandle.TickLabels = {'0.4', '', '0.6', '', '0.8', '', '1'};
            end
            title(axesHandle, titleText);
            xlabel(axesHandle, 'x lateral [cm]');
            ylabel(axesHandle, 'z [cm]');

            % Los mapas contienen solamente el medio físico. El marco
            % discontinuo marca la PML externa que también calcula k-Wave,
            % de modo que Properties y Geometric comparten el mismo dominio.
            frame = PreviewLogic.geometryFrame(configuration);
            hold(axesHandle, 'on');
            rectangle(axesHandle, 'Position', ...
                [(frame.lateralMin - frame.pml) * 100, ...
                 (frame.axialMin - frame.pml) * 100, ...
                 (frame.lateralSize + 2 * frame.pml) * 100, ...
                 (frame.axialSize + 2 * frame.pml) * 100], ...
                'EdgeColor', [0.45 0.45 0.45], 'LineWidth', 1.1, 'LineStyle', '--');
            rectangle(axesHandle, 'Position', ...
                [frame.lateralMin * 100, frame.axialMin * 100, ...
                 frame.lateralSize * 100, frame.axialSize * 100], ...
                'EdgeColor', [0.15 0.15 0.15], 'LineWidth', 1.3, 'LineStyle', '-');
            hold(axesHandle, 'off');
            PreviewLogic.setComputedViewport(axesHandle, frame);
        end

        function drawDomain(axesHandle, configuration, showEmitter)
            axis(axesHandle, 'on');
            box(axesHandle, 'on');
            hold(axesHandle, 'on');

            frame = PreviewLogic.geometryFrame(configuration);

            % El pipeline usa PMLInside = false. La capa absorbente se
            % encuentra fuera de la malla física, no dentro de ella.
            rectangle(axesHandle, 'Position', ...
                [(frame.lateralMin - frame.pml) * 100, ...
                 (frame.axialMin - frame.pml) * 100, ...
                 (frame.lateralSize + 2 * frame.pml) * 100, ...
                 (frame.axialSize + 2 * frame.pml) * 100], ...
                'FaceColor', [0.92 0.92 0.92], ...
                'EdgeColor', [0.45 0.45 0.45], 'LineWidth', 1.1, 'LineStyle', '--');
            rectangle(axesHandle, 'Position', ...
                [frame.lateralMin * 100, frame.axialMin * 100, ...
                 frame.lateralSize * 100, frame.axialSize * 100], ...
                'FaceColor', [1 1 1], ...
                'EdgeColor', [0.15 0.15 0.15], 'LineWidth', 1.3, 'LineStyle', '-');

            if showEmitter
                PreviewLogic.drawEmitter(axesHandle, configuration);
                PreviewLogic.drawFocus(axesHandle, configuration);
            end

            axis(axesHandle, 'equal');
            PreviewLogic.setGeometryLimits(axesHandle, frame);
            set(axesHandle, 'YDir', 'reverse');
            xlabel(axesHandle, 'x [cm]');
            ylabel(axesHandle, 'z [cm]');
            grid(axesHandle, 'on');
            hold(axesHandle, 'off');
        end

        function drawEmitter(axesHandle, configuration)
            apertureRx = configuration.focus / configuration.fNumberRx;
            apertureTx = configuration.focus / configuration.fNumberTx;
            elementCount = max(1, floor(apertureRx / configuration.elementPitch));
            elementCount = min(elementCount, 128);
            elementIndices = (0:elementCount - 1) - (elementCount - 1) / 2;
            activeCount = min(elementCount, max(1, floor(apertureTx / configuration.elementPitch)));
            activeMask = abs(elementIndices) <= (activeCount - 1) / 2;

            tangent = [sin(configuration.rotation), cos(configuration.rotation)];
            center = [configuration.emitterAxial, configuration.emitterLateral];
            segmentHalfLength = configuration.elementWidth / 2;

            for index = 1:elementCount
                elementCenter = center + elementIndices(index) * configuration.elementPitch * tangent;
                firstPoint = elementCenter - segmentHalfLength * tangent;
                lastPoint = elementCenter + segmentHalfLength * tangent;
                color = [0.1 0.1 0.1];
                lineWidth = 2;
                if activeMask(index)
                    color = [0 0.35 0.75];
                    lineWidth = 3;
                end
                line(axesHandle, [firstPoint(2), lastPoint(2)] * 100, ...
                    [firstPoint(1) - configuration.emitterAxial, ...
                     lastPoint(1) - configuration.emitterAxial] * 100, ...
                    'Color', color, 'LineWidth', lineWidth);
            end
        end

        function drawFocus(axesHandle, configuration)
            normal = [cos(configuration.rotation), -sin(configuration.rotation)];
            focusPoint = [configuration.emitterAxial, configuration.emitterLateral] + ...
                configuration.focus * normal;
            plot(axesHandle, focusPoint(2) * 100, ...
                (focusPoint(1) - configuration.emitterAxial) * 100, ...
                'o', 'MarkerSize', 6, 'MarkerFaceColor', [0.85 0.35 0], ...
                'MarkerEdgeColor', [0.25 0.12 0]);
        end

        function frame = geometryFrame(configuration)
            % El dominio numérico de k-Wave está centrado en cero, pero la
            % interfaz se expresa respecto a la superficie del transductor.
            % La profundidad configurada define el intervalo físico que se
            % adquiere: z = 0 en el emisor y z = depth al final de la imagen.
            % base_translation solo posiciona el array dentro de k-Wave; no
            % debe desplazar el origen mostrado al usuario.
            frame.axialSize = configuration.depth;
            frame.lateralSize = configuration.lateralSize;
            frame.pml = configuration.pmlLayers * configuration.dx;
            frame.lateralMin = -configuration.lateralSize / 2;
            frame.lateralMax = configuration.lateralSize / 2;
            frame.axialMin = 0;
            frame.axialMax = configuration.depth;
        end

        function setGeometryLimits(axesHandle, frame)
            PreviewLogic.setComputedViewport(axesHandle, frame);
        end

        function setComputedViewport(axesHandles, frame)
            % La vista muestra el dominio físico y la PML externa que usa el
            % solver. Así ninguna pestaña oculta parte de lo que se calcula.
            margin = max(0.002, 0.08 * max(frame.axialSize, frame.lateralSize));
            for axesHandle = axesHandles
                xlim(axesHandle, [(frame.lateralMin - frame.pml - margin) * 100, ...
                    (frame.lateralMax + frame.pml + margin) * 100]);
                ylim(axesHandle, [(frame.axialMin - frame.pml - margin) * 100, ...
                    (frame.axialMax + frame.pml + margin) * 100]);
            end
        end

        function drawSignal(timeAxes, frequencyAxes, configuration)
            cla(timeAxes);
            cla(frequencyAxes);
            timeAxes.XLimMode = 'auto';
            timeAxes.YLimMode = 'auto';
            frequencyAxes.XLimMode = 'auto';
            frequencyAxes.YLimMode = 'auto';
            if ~PreviewLogic.isSignalValid(configuration)
                PreviewLogic.showIncomplete(timeAxes, 'Completa frecuencia, amplitud y ciclos.');
                PreviewLogic.showIncomplete(frequencyAxes, 'El espectro aparecerá al definir la señal.');
                return
            end

            [time, signal, samplingFrequency] = PreviewLogic.makeToneBurst(configuration);

            time = double(time(:)');
            signal = double(signal(:)');
            timeUs = time * 1e6;
            signalMPa = signal / 1e6;
            pulseDurationUs = configuration.cycles / configuration.frequency * 1e6;
            timeMarginUs = max(3 / samplingFrequency * 1e6, 0.08 * pulseDurationUs);
            peakMPa = max(abs(signalMPa));
            if peakMPa == 0, peakMPa = configuration.amplitude / 1e6; end

            axis(timeAxes, 'on');
            box(timeAxes, 'on');
            hold(timeAxes, 'on');
            yline(timeAxes, 0, ':', 'Color', [0.4 0.4 0.4]);
            plot(timeAxes, timeUs, signalMPa, 'Color', [0 0.35 0.75], 'LineWidth', 1.3);
            hold(timeAxes, 'off');
            grid(timeAxes, 'on');
            title(timeAxes, sprintf('Tone Burst (%.2f MHz, %.1f ciclos)', ...
                configuration.frequency / 1e6, configuration.cycles));
            xlabel(timeAxes, 'Time [µs]');
            ylabel(timeAxes, 'Pressure [MPa]');
            xlim(timeAxes, [0, pulseDurationUs + timeMarginUs]);
            ylim(timeAxes, 1.15 * peakMPa * [-1, 1]);

            signalLength = numel(signal);
            spectrumLength = 2^nextpow2(max(2048, 16 * signalLength));
            spectrumTwoSided = abs(fft(signal, spectrumLength) / signalLength);
            spectrum = spectrumTwoSided(1:floor(spectrumLength / 2) + 1);
            if rem(spectrumLength, 2) == 0
                spectrum(2:end - 1) = 2 * spectrum(2:end - 1);
            else
                spectrum(2:end) = 2 * spectrum(2:end);
            end
            frequencyAxis = samplingFrequency * (0:floor(spectrumLength / 2)) / spectrumLength;
            axis(frequencyAxes, 'on');
            box(frequencyAxes, 'on');
            plot(frequencyAxes, frequencyAxis / 1e6, spectrum / 1e6, ...
                'Color', [0.85 0.35 0], 'LineWidth', 1.3);
            grid(frequencyAxes, 'on');
            title(frequencyAxes, 'One-sided amplitude spectrum');
            xlabel(frequencyAxes, 'Frequency [MHz]');
            ylabel(frequencyAxes, 'Amplitude [MPa]');
            xlim(frequencyAxes, [0, min(samplingFrequency / 2, ...
                max(2 * configuration.frequency, 1e6)) / 1e6]);
        end

        function [time, signal, samplingFrequency] = makeToneBurst(configuration)
            try
                dx = configuration.soundSpeed / ...
                    (configuration.ppw * configuration.frequency);
                nx = roundEven(configuration.axialSize / dx);
                ny = roundEven(configuration.lateralSize / dx);
                kgrid = kWaveGrid(nx, dx, ny, dx);
                endTime = configuration.depth * 2 / configuration.soundSpeed;
                kgrid.makeTime(configuration.soundSpeed, configuration.cfl, endTime);
                samplingFrequency = 1 / kgrid.dt;
                signal = configuration.amplitude * toneBurst( ...
                    samplingFrequency, configuration.frequency, configuration.cycles);
                time = (0:numel(signal) - 1) * kgrid.dt;
            catch
                samplingFrequency = max(40 * configuration.frequency, 20e6);
                duration = configuration.cycles / configuration.frequency;
                sampleCount = max(256, ceil(1.2 * duration * samplingFrequency));
                time = (0:sampleCount - 1) / samplingFrequency;
                active = time <= duration;
                signal = zeros(size(time));
                signal(active) = configuration.amplitude * ...
                    sin(2 * pi * configuration.frequency * time(active));
            end
        end

        function showIncomplete(axesHandle, message)
            cla(axesHandle);
            axis(axesHandle, 'off');
            text(axesHandle, 0.5, 0.5, message, 'Units', 'normalized', ...
                'HorizontalAlignment', 'center', 'VerticalAlignment', 'middle', ...
                'Color', [0.25 0.25 0.25], 'FontSize', 11);
        end

        function valid = isGeometryValid(configuration)
            valid = all(isfinite([configuration.axialSize, configuration.lateralSize, ...
                configuration.ppw, configuration.pmlLayers, configuration.soundSpeed, ...
                configuration.frequency, configuration.elementPitch, configuration.elementWidth, ...
                configuration.focus, configuration.fNumberTx, configuration.fNumberRx, ...
                configuration.emitterAxial, configuration.emitterLateral, configuration.rotation])) && ...
                all([configuration.axialSize, configuration.lateralSize, configuration.ppw, ...
                configuration.pmlLayers, configuration.soundSpeed, configuration.frequency, ...
                configuration.elementPitch, configuration.elementWidth, configuration.focus, ...
                configuration.fNumberTx, configuration.fNumberRx] > 0);
        end

        function valid = isSignalValid(configuration)
            valid = all(isfinite([configuration.frequency, configuration.amplitude, ...
                configuration.cycles, configuration.soundSpeed, configuration.ppw, ...
                configuration.cfl, configuration.depth])) && ...
                all([configuration.frequency, configuration.amplitude, configuration.cycles, ...
                configuration.soundSpeed, configuration.ppw, configuration.cfl, configuration.depth] > 0);
        end
    end
end
