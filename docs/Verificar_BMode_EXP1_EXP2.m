%% Revisión B-mode y ACS desde RF prebeamformado
% Este Live Script no busca ni ejecuta simulaciones k-Wave. Cada resultado
% se construye exclusivamente a partir de una fila con:
%   1) un MAT que contiene rf_prebf y alpha_coeff;
%   2) el pipeline .m que generó ese MAT;
%   3) un título editable para la figura.
%
% El B-mode usa DAS Rx dinámico con F-number guardado en el MAT, apertura
% mínima de 16 elementos, filtrado fundamental y envolvente Hilbert sin TGC.
% El panel ACS muestra exactamente
% alpha_coeff guardado por k-Wave con la escala fija de la GUI: 0.4, 0.6,
% 0.8 y 1 dB/cm/MHz.
% Si una figura indica “RF recortada lateralmente”, el arreglo de las líneas
% externas salió de la malla durante la simulación. Esa información no se
% recupera con el beamformer: corrige la malla o el número de líneas y vuelve
% a generar los MAT antes de usar el B-mode como resultado experimental.

repositoryRoot = resolveRepositoryRoot();
addpath(fullfile(repositoryRoot, 'apps'));
addpath(fullfile(repositoryRoot, 'docs'));
addpath(fullfile(repositoryRoot, 'pipelines', 'bmode'));

%% Seleccionar pares MAT + pipeline
% Añade filas, selecciona cada .mat y su .m, edita los títulos y pulsa
% “Generar B-mode + ACS”. El orden de las filas será el orden de la salida.
BModeReviewApp();

%% Ejecución programática opcional
% Si prefieres no usar la ventana, sustituye las rutas vacías y ejecuta:
% rows = table( ...
%     ["Referencia"; "Caso 1"], ...
%     ["/ruta/rf_prebf_homRef_001.mat"; "/ruta/rf_prebf_homRef_001.mat"], ...
%     ["/ruta/experimento_pipeline.m"; "/ruta/experimento_pipeline.m"], ...
%     'VariableNames', {'Title', 'MatFile', 'PipelineFile'});
% report = qus_bmode_review(rows);
% open(report.pngPath)

%% Funciones
function repositoryRoot = resolveRepositoryRoot()
% Recupera la raíz incluso cuando Live Editor ejecuta una copia temporal.
candidates = strings(0, 1);
try
    activeDocument = string(matlab.desktop.editor.getActiveFilename);
    if strlength(activeDocument) > 0
        candidates(end + 1, 1) = activeDocument;
    end
catch
end
candidates(end + 1, 1) = string(pwd);
for index = 1:numel(candidates)
    folder = char(candidates(index));
    if isfile(folder), folder = fileparts(folder); end
    while ~isempty(folder)
        if isfolder(fullfile(folder, 'apps')) && isfolder(fullfile(folder, 'pipelines'))
            repositoryRoot = folder;
            return
        end
        parent = fileparts(folder);
        if strcmp(parent, folder), break, end
        folder = parent;
    end
end
error('QUS:Bmode:RepositoryNotFound', ...
    'Abre este archivo desde docs o sitúa Current Folder dentro de dpb-qus-benchmark.');
end
