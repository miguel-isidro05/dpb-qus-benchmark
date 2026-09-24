function report = qus_bmode_review(rows, outputFolder, options)
%QUS_BMODE_REVIEW Genera B-mode y ACS para pares explícitos MAT + pipeline.
% Cada fila representa un caso independiente: Título, MatFile y PipelineFile.
% La RF se beamforma con el flujo estándar sin ejecutar k-Wave.

if nargin < 2 || isempty(outputFolder)
    repositoryRoot = fileparts(fileparts(fileparts(mfilename('fullpath'))));
    outputFolder = fullfile(repositoryRoot, 'docs', 'BMODE_REVIEW', ...
        char(datetime('now', 'Format', 'yyyyMMdd_HHmmss')));
end
if nargin < 3 || isempty(options)
    options = struct();
end

rows = normalizeRows(rows);
if ~isfolder(outputFolder)
    mkdir(outputFolder);
end

cfg = us_bmode_config(mergeOptions(options));
results = cell(height(rows), 1);
acsMaps = cell(height(rows), 1);
acsAxes = cell(height(rows), 1);
warningsByCase = strings(height(rows), 1);
maximumEnvelope = 0;

for rowIndex = 1:height(rows)
    result = us_bmode_process(rows.MatFile(rowIndex), cfg);
    results{rowIndex} = result;
    finiteEnvelope = result.envelope_no_tgc(isfinite(result.envelope_no_tgc));
    if ~isempty(finiteEnvelope)
        maximumEnvelope = max(maximumEnvelope, max(finiteEnvelope));
    end
    caseWarnings = string(result.warnings);
    warningsByCase(rowIndex) = strjoin(caseWarnings, " ");
    [acsMaps{rowIndex}, acsAxes{rowIndex}] = readAcsMap(rows(rowIndex, :), result);
end
if maximumEnvelope <= 0 || ~isfinite(maximumEnvelope)
    error('QUS:Bmode:InvalidEnvelope', 'No se encontró una envolvente válida en los MAT seleccionados.');
end

figureHandle = figure('Name', 'QUS: B-mode y ACS', 'Color', 'w', ...
    'Position', [80 80 max(900, 620 * height(rows)) 720]);
layout = tiledlayout(height(rows), 2, 'TileSpacing', 'compact', 'Padding', 'compact');
for rowIndex = 1:height(rows)
    result = results{rowIndex};
    bmodeDb = us_bmode_compress(result.envelope_no_tgc, maximumEnvelope, cfg.dynamic_range_db);
    visibleRows = result.valid_support;
    if ~isempty(cfg.depth_limits_cm)
        depthCm = result.z_m * 100;
        visibleRows = visibleRows & depthCm >= cfg.depth_limits_cm(1) & ...
            depthCm <= cfg.depth_limits_cm(2);
    end
    if nnz(visibleRows) < 2
        error('QUS:Bmode:VisibleRange', 'El caso "%s" no tiene muestras visibles.', rows.Title(rowIndex));
    end

    nexttile(layout);
    imagesc(result.x_m * 100, result.z_m(visibleRows) * 100, ...
        bmodeDb(visibleRows, :), [-cfg.dynamic_range_db 0]);
    axis image; set(gca, 'YDir', 'reverse'); colormap(gca, gray(256));
    xlabel('x lateral [cm]'); ylabel('z [cm]');
    if contains(warningsByCase(rowIndex), 'recorte Rx')
        title(sprintf('%s — B-mode (RF recortada lateralmente)', rows.Title(rowIndex)), ...
            'Interpreter', 'none');
    else
        title(sprintf('%s — B-mode', rows.Title(rowIndex)), 'Interpreter', 'none');
    end
    colorbarHandle = colorbar; ylabel(colorbarHandle, 'dB');

    nexttile(layout);
    axesInfo = acsAxes{rowIndex};
    imagesc(axesInfo.x_m * 100, axesInfo.z_m * 100, acsMaps{rowIndex}, [0.35 1.05]);
    axis image; set(gca, 'YDir', 'reverse'); colormap(gca, turbo(256));
    xlabel('x lateral [cm]'); ylabel('z [cm]');
    title(sprintf('%s — ACS', rows.Title(rowIndex)), 'Interpreter', 'none');
    colorbarHandle = colorbar;
    colorbarHandle.Ticks = 0.4:0.1:1.0;
    colorbarHandle.TickLabels = {'0.4', '', '0.6', '', '0.8', '', '1'};
    ylabel(colorbarHandle, 'ACS [dB/cm/MHz]');
end

pngPath = fullfile(outputFolder, 'bmode_acs_review.png');
figPath = fullfile(outputFolder, 'bmode_acs_review.fig');
exportgraphics(figureHandle, pngPath, 'Resolution', 180);
savefig(figureHandle, figPath);
report = struct('rows', rows, 'results', {results}, 'commonReferenceAmplitude', ...
    maximumEnvelope, 'figure', figureHandle, 'pngPath', pngPath, 'figPath', figPath, ...
    'beamforming', cfg.receive_focus_mode, 'warnings', warningsByCase, ...
    'outputFolder', outputFolder);
end

function cfg = mergeOptions(options)
cfg = struct('input_kind', 'rf_prebf', 'filter_enabled', true, ...
    'tgc_enabled', false, 'export_figures', false, 'dynamic_range_db', 50, ...
    'receive_focus_mode', 'dynamic', 'receive_f_number', []);
fields = fieldnames(options);
for fieldIndex = 1:numel(fields)
    cfg.(fields{fieldIndex}) = options.(fields{fieldIndex});
end
end

function rows = normalizeRows(rows)
if istable(rows)
    required = {'Title', 'MatFile', 'PipelineFile'};
    if ~all(ismember(required, rows.Properties.VariableNames))
        error('QUS:Bmode:Rows', 'La tabla requiere las columnas Title, MatFile y PipelineFile.');
    end
    rows = rows(:, required);
elseif isstruct(rows)
    rows = struct2table(rows);
    rows = normalizeRows(rows);
    return
else
    error('QUS:Bmode:Rows', 'rows debe ser una tabla o estructura con Title, MatFile y PipelineFile.');
end
rows.Title = string(rows.Title);
rows.MatFile = string(rows.MatFile);
rows.PipelineFile = string(rows.PipelineFile);
if height(rows) == 0 || any(strlength(strtrim(rows.Title)) == 0)
    error('QUS:Bmode:Rows', 'Cada fila necesita un título.');
end
for rowIndex = 1:height(rows)
    if ~isfile(rows.MatFile(rowIndex))
        error('QUS:Bmode:Rows', 'No existe el MAT de la fila %d: %s', rowIndex, rows.MatFile(rowIndex));
    end
    if ~isfile(rows.PipelineFile(rowIndex))
        error('QUS:Bmode:Rows', 'No existe el pipeline de la fila %d: %s', rowIndex, rows.PipelineFile(rowIndex));
    end
end
end

function [acs, axesInfo] = readAcsMap(row, result)
% alpha_coeff es el mapa que k-Wave recibió; no se reconstruye ni interpola.
content = load(row.MatFile, 'alpha_coeff', 'grid_size_x', 'grid_size_y', 'depth');
if ~isfield(content, 'alpha_coeff') || ~isnumeric(content.alpha_coeff) || isempty(content.alpha_coeff)
    error('QUS:Bmode:ACS', 'El MAT de "%s" no contiene alpha_coeff.', row.Title);
end
acs = double(content.alpha_coeff);
if ~ismatrix(acs) || any(~isfinite(acs(:)))
    error('QUS:Bmode:ACS', 'alpha_coeff de "%s" no es una matriz finita.', row.Title);
end

% Los MAT recientes son autosuficientes; así nunca se ejecuta un pipeline
% baseline sólo para obtener los límites del mapa.
parameters = struct();
gridSizeX = firstAvailable(content, 'grid_size_x', parameters, 'grid_size_x');
gridSizeY = firstAvailable(content, 'grid_size_y', parameters, 'grid_size_y');
depth = firstAvailable(content, 'depth', parameters, 'depth');
if isempty(gridSizeX) || isempty(gridSizeY) || isempty(depth)
    parameters = readPipelineParameters(row.PipelineFile, result);
    gridSizeX = firstAvailable(content, 'grid_size_x', parameters, 'grid_size_x');
    gridSizeY = firstAvailable(content, 'grid_size_y', parameters, 'grid_size_y');
    depth = firstAvailable(content, 'depth', parameters, 'depth');
end
if isempty(gridSizeX) || isempty(gridSizeY) || isempty(depth)
    error('QUS:Bmode:ACS', 'Faltan grid_size_x, grid_size_y o depth para "%s".', row.Title);
end
validateattributes(gridSizeX, {'numeric'}, {'real', 'scalar', 'finite', 'positive'});
validateattributes(gridSizeY, {'numeric'}, {'real', 'scalar', 'finite', 'positive'});
validateattributes(depth, {'numeric'}, {'real', 'scalar', 'finite', 'positive'});
axesInfo = struct('x_m', linspace(-double(gridSizeY) / 2, double(gridSizeY) / 2, size(acs, 2)), ...
    'z_m', linspace(0, double(depth), size(acs, 1))');
end

function parameters = readPipelineParameters(pipelineFile, result)
try
    repositoryRoot = fileparts(fileparts(fileparts(mfilename('fullpath'))));
    addpath(fullfile(repositoryRoot, 'apps'));
    cases = QUSConfigurationLogic.readPipelineConfiguration(char(pipelineFile));
    targetName = '';
    if isfield(result.metadata, 'simuName')
        targetName = char(string(result.metadata.simuName));
    end
    caseIndex = find(strcmp({cases.simuName}, targetName), 1, 'first');
    if isempty(caseIndex)
        caseIndex = find([cases.isReference], 1, 'first');
    end
    if isempty(caseIndex)
        caseIndex = 1;
    end
    parameters = cases(caseIndex);
catch exception
    error('QUS:Bmode:Pipeline', 'No se pudo leer %s: %s', pipelineFile, exception.message);
end
end

function value = firstAvailable(primary, primaryName, secondary, secondaryName)
value = [];
if isfield(primary, primaryName)
    value = primary.(primaryName);
end
if isempty(value) && isfield(secondary, secondaryName)
    value = secondary.(secondaryName);
end
end
