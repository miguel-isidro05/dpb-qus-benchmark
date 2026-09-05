classdef PreviewLogic
    % PreviewLogic
    % Preview 2D de la configuración. No ejecuta k-Wave ni modifica la cola.

    methods (Static)

        function initialize(app)
            PreviewLogic.createPreviewAxes(app);
            PreviewLogic.installRefreshCallbacks(app);
            PreviewLogic.refresh(app);
        end

        function refresh(app)
            handles = getappdata(app.UIFigure, 'PreviewLogicHandles');
            if isempty(handles) || ~isvalid(handles.geometryAxes)
                PreviewLogic.createPreviewAxes(app);
                handles = getappdata(app.UIFigure, 'PreviewLogicHandles');
            end

            configuration = PreviewLogic.readConfiguration(app);
            PreviewLogic.drawGeometry(handles.geometryAxes, configuration);
            PreviewLogic.drawMedium(handles.mediumAxes, configuration);
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
            setappdata(app.UIFigure, 'PreviewLogicHandles', handles);
        end

        function installRefreshCallbacks(app)
            controls = { ...
                app.DimensionesEditField, app.ResolucinEditField, ...
                app.PMLCantcapasEditField, app.CFLEditField, ...
                app.VelsonidoEditField, app.DensidadEditField, ...
                app.FrecuenciaEditField, app.AmplitudEditField_2, ...
                app.NciclosEditField, app.ModeloDropDown, ...
                app.TipoDropDown, app.SealDropDown, app.MododehazDropDown};

            for index = 1:numel(controls)
                controls{index}.ValueChangedFcn = @(~, ~) PreviewLogic.refresh(app);
            end
        end

        function configuration = readConfiguration(app)
            configuration.axialSize = app.DimensionesEditField.Value;
            configuration.ppw = app.ResolucinEditField.Value;
            configuration.pmlLayers = app.PMLCantcapasEditField.Value;
            configuration.soundSpeed = app.VelsonidoEditField.Value;
            configuration.density = app.DensidadEditField.Value;
            configuration.frequency = app.FrecuenciaEditField.Value;
            configuration.amplitude = app.AmplitudEditField_2.Value;
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
        end

        function drawGeometry(axesHandle, configuration)
            cla(axesHandle);
            if ~PreviewLogic.isGeometryValid(configuration)
                PreviewLogic.showIncomplete(axesHandle, 'Completa la geometría y el emisor para previsualizarlos.');
                return
            end

            PreviewLogic.drawDomain(axesHandle, configuration, false);
            title(axesHandle, 'Dominio 2D, PML y emisor');
        end

        function drawMedium(axesHandle, configuration)
            cla(axesHandle);
            if ~PreviewLogic.isGeometryValid(configuration)
                PreviewLogic.showIncomplete(axesHandle, 'El mapa del medio aparecerá con una geometría válida.');
                return
            end

            lateral = linspace(-configuration.lateralSize / 2, configuration.lateralSize / 2, 160) * 1e3;
            axial = linspace(0, configuration.axialSize, 200) * 1e3;
            mediumMap = configuration.soundSpeed * ones(numel(axial), numel(lateral));
            imagesc(axesHandle, lateral, axial, mediumMap);
            set(axesHandle, 'YDir', 'normal');
            axis(axesHandle, 'image');
            colormap(axesHandle, parula);
            colorbar(axesHandle);
            hold(axesHandle, 'on');
            PreviewLogic.drawDomain(axesHandle, configuration, true);
            hold(axesHandle, 'off');
            title(axesHandle, sprintf('Medio: velocidad de sonido (%.0f m/s)', configuration.soundSpeed));
            xlabel(axesHandle, 'Lateral [mm]');
            ylabel(axesHandle, 'Axial [mm]');
        end

        function drawDomain(axesHandle, configuration, overlayOnly)
            if ~overlayOnly
                hold(axesHandle, 'on');
            end

            axialMm = configuration.axialSize * 1e3;
            lateralMm = configuration.lateralSize * 1e3;
            pmlAxialMm = configuration.pmlLayers * configuration.dx * 1e3;
            pmlLateralMm = configuration.pmlLayers * configuration.dx * 1e3;

            rectangle(axesHandle, 'Position', [-lateralMm / 2, 0, lateralMm, axialMm], ...
                'EdgeColor', [0.15 0.15 0.15], 'LineWidth', 1.2, 'LineStyle', '-');
            rectangle(axesHandle, 'Position', ...
                [-lateralMm / 2 + pmlLateralMm, pmlAxialMm, ...
                 lateralMm - 2 * pmlLateralMm, axialMm - 2 * pmlAxialMm], ...
                'EdgeColor', [0.35 0.35 0.35], 'LineWidth', 1, 'LineStyle', '--');

            PreviewLogic.drawEmitter(axesHandle, configuration);
            PreviewLogic.drawFocus(axesHandle, configuration);

            axis(axesHandle, 'equal');
            PreviewLogic.setGeometryLimits(axesHandle, configuration);
            xlabel(axesHandle, 'Lateral [mm]');
            ylabel(axesHandle, 'Axial [mm]');
            grid(axesHandle, 'on');

            if ~overlayOnly
                hold(axesHandle, 'off');
            end

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
                line(axesHandle, [firstPoint(2), lastPoint(2)] * 1e3, ...
                    [firstPoint(1), lastPoint(1)] * 1e3, ...
                    'Color', color, 'LineWidth', lineWidth);
            end
        end

        function drawFocus(axesHandle, configuration)
            normal = [cos(configuration.rotation), -sin(configuration.rotation)];
            focusPoint = [configuration.emitterAxial, configuration.emitterLateral] + ...
                configuration.focus * normal;
            plot(axesHandle, focusPoint(2) * 1e3, focusPoint(1) * 1e3, ...
                'o', 'MarkerSize', 6, 'MarkerFaceColor', [0.85 0.35 0], ...
                'MarkerEdgeColor', [0.25 0.12 0]);
        end

        function setGeometryLimits(axesHandle, configuration)
            axial = configuration.axialSize * 1e3;
            lateral = configuration.lateralSize * 1e3;
            focusAxial = (configuration.emitterAxial + ...
                configuration.focus * cos(configuration.rotation)) * 1e3;
            emitterAxial = configuration.emitterAxial * 1e3;
            emitterLateral = configuration.emitterLateral * 1e3;

            xMargin = max(2, 0.08 * lateral);
            yMargin = max(2, 0.08 * axial);
            xlim(axesHandle, [min(-lateral / 2, emitterLateral) - xMargin, ...
                max(lateral / 2, emitterLateral) + xMargin]);
            ylim(axesHandle, [min([0, emitterAxial, focusAxial]) - yMargin, ...
                max([axial, emitterAxial, focusAxial]) + yMargin]);
        end

        function drawSignal(timeAxes, frequencyAxes, configuration)
            cla(timeAxes);
            cla(frequencyAxes);
            if ~PreviewLogic.isSignalValid(configuration)
                PreviewLogic.showIncomplete(timeAxes, 'Completa frecuencia, amplitud y ciclos.');
                PreviewLogic.showIncomplete(frequencyAxes, 'El espectro aparecerá al definir la señal.');
                return
            end

            samplingFrequency = max(40 * configuration.frequency, 20e6);
            duration = configuration.cycles / configuration.frequency;
            sampleCount = max(256, ceil(1.2 * duration * samplingFrequency));
            time = (0:sampleCount - 1) / samplingFrequency;
            active = time <= duration;
            activeCount = nnz(active);
            window = 0.5 - 0.5 * cos(2 * pi * (0:activeCount - 1) / max(activeCount - 1, 1));
            signal = zeros(size(time));
            signal(active) = configuration.amplitude * ...
                sin(2 * pi * configuration.frequency * time(active)) .* window;

            plot(timeAxes, time * 1e6, signal / 1e6, 'Color', [0 0.35 0.75], 'LineWidth', 1.3);
            grid(timeAxes, 'on');
            title(timeAxes, sprintf('%s en tiempo', configuration.signalType));
            xlabel(timeAxes, 'Tiempo [µs]');
            ylabel(timeAxes, 'Presión [MPa]');

            frequencyAxis = (0:floor(numel(signal) / 2)) * samplingFrequency / numel(signal);
            spectrum = abs(fft(signal)) / numel(signal);
            spectrum = spectrum(1:numel(frequencyAxis));
            plot(frequencyAxes, frequencyAxis / 1e6, spectrum / max(max(spectrum), eps), ...
                'Color', [0.85 0.35 0], 'LineWidth', 1.3);
            grid(frequencyAxes, 'on');
            title(frequencyAxes, 'Espectro de magnitud');
            xlabel(frequencyAxes, 'Frecuencia [MHz]');
            ylabel(frequencyAxes, 'Magnitud normalizada');
            xlim(frequencyAxes, [0, max(2 * configuration.frequency / 1e6, 1)]);
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
            valid = all(isfinite([configuration.frequency, configuration.amplitude, configuration.cycles])) && ...
                all([configuration.frequency, configuration.amplitude, configuration.cycles] > 0);
        end
    end
end
