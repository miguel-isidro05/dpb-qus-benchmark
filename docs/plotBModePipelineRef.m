function result = plotBModePipelineRef(matFile, varargin)
% plotBModePipelineRef
% Visualiza un archivo rf_prebf generado por pipeline_ref.
%
% Uso desde un Live Script (.mlx):
%   result = plotBModePipelineRef("ruta/rf_prebf_homRef_001.mat");
%
% El archivo debe incluir rf_prebf y la metadata que guarda pipeline_ref.

    result = renderBModePipeline(matFile, 'pipeline_ref', varargin{:});
end
