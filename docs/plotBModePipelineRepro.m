function result = plotBModePipelineRepro(matFile, varargin)
% plotBModePipelineRepro
% Visualiza un archivo rf_prebf generado por pipeline_repro.
%
% Uso desde un Live Script (.mlx):
%   result = plotBModePipelineRepro("ruta/rf_prebf_homRef_001.mat");
%
% El archivo debe incluir rf_prebf y la metadata que guarda pipeline_repro.

    result = renderBModePipeline(matFile, 'pipeline_repro', varargin{:});
end
