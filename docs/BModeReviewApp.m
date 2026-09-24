function app = BModeReviewApp(initialRows)
%BMODEREVIEWAPP Selecciona pares MAT + pipeline y genera B-mode con ACS.
% Cada fila conserva un título editable y se procesa en el orden mostrado.

if nargin < 1 || isempty(initialRows)
    initialRows = table("Caso 1", "", "", 'VariableNames', {'Title', 'MatFile', 'PipelineFile'});
end
app = uifigure('Name', 'Revisión B-mode y ACS', 'Position', [240 220 1020 460]);
app.UserData = struct('selectedRow', 1);
layout = uigridlayout(app, [3 1]);
layout.RowHeight = {34, '1x', 42};
layout.Padding = [14 14 14 14];

header = uilabel(layout, 'Text', 'Agrega un MAT prebeamformado y su pipeline .m por fila. El orden de la tabla define el orden de las figuras.');
header.WordWrap = 'on';

tableControl = uitable(layout, 'Data', initialRows, ...
    'ColumnName', {'Título', 'RF prebeamformado (.mat)', 'Pipeline (.m)'}, ...
    'ColumnEditable', [true true true], ...
    'ColumnWidth', {180, '1x', '1x'}, ...
    'CellSelectionCallback', @selectRow);

controls = uigridlayout(layout, [1 6]);
controls.ColumnWidth = {92, 112, 108, 108, '1x', 164};
uibutton(controls, 'Text', '+ Fila', 'ButtonPushedFcn', @addRow);
uibutton(controls, 'Text', '− Fila', 'ButtonPushedFcn', @removeRow);
uibutton(controls, 'Text', 'Elegir MAT', 'ButtonPushedFcn', @chooseMat);
uibutton(controls, 'Text', 'Elegir .m', 'ButtonPushedFcn', @choosePipeline);
status = uilabel(controls, 'Text', '');
uibutton(controls, 'Text', 'Generar B-mode + ACS', 'ButtonPushedFcn', @generateReview, ...
    'BackgroundColor', [0.79 0.99 0.92]);

    function selectRow(~, event)
        if ~isempty(event.Indices)
            app.UserData.selectedRow = event.Indices(1);
        end
    end

    function addRow(~, ~)
        data = tableControl.Data;
        rowCount = height(data) + 1;
        tableControl.Data = [data; table("Caso " + rowCount, "", "", ...
            'VariableNames', data.Properties.VariableNames)];
        app.UserData.selectedRow = rowCount;
    end

    function removeRow(~, ~)
        data = tableControl.Data;
        if height(data) <= 1
            uialert(app, 'Debe permanecer al menos una fila.', 'Revisión B-mode');
            return
        end
        row = min(app.UserData.selectedRow, height(data));
        data(row, :) = [];
        tableControl.Data = data;
        app.UserData.selectedRow = min(row, height(data));
    end

    function chooseMat(~, ~)
        [file, folder] = uigetfile('*.mat', 'Selecciona RF prebeamformado');
        if isequal(file, 0), return, end
        row = min(app.UserData.selectedRow, height(tableControl.Data));
        data = tableControl.Data;
        data.MatFile(row) = string(fullfile(folder, file));
        tableControl.Data = data;
    end

    function choosePipeline(~, ~)
        [file, folder] = uigetfile('*.m', 'Selecciona pipeline MATLAB');
        if isequal(file, 0), return, end
        row = min(app.UserData.selectedRow, height(tableControl.Data));
        data = tableControl.Data;
        data.PipelineFile(row) = string(fullfile(folder, file));
        tableControl.Data = data;
    end

    function generateReview(~, ~)
        try
            status.Text = 'Procesando RF sin ejecutar k-Wave...'; drawnow;
            repositoryRoot = fileparts(fileparts(mfilename('fullpath')));
            addpath(fullfile(repositoryRoot, 'pipelines', 'bmode'));
            report = qus_bmode_review(tableControl.Data);
            if any(contains(report.warnings, 'recorte Rx'))
                status.Text = 'Listo con advertencia: RF recortada lateralmente.';
            else
                status.Text = 'Listo: ' + string(report.outputFolder);
            end
        catch exception
            status.Text = 'Error';
            uialert(app, exception.message, 'No se pudo generar la revisión');
        end
    end
end
