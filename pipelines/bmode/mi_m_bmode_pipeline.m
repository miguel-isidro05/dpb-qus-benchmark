function summary = mi_m_bmode_pipeline(input_files,output_root,options)
%MI_M_BMODE_PIPELINE Entrada principal para los MAT recibidos del clúster.
% Uso desde raíz del repositorio:
% addpath(fullfile(pwd,'pipelines','bmode'));
% s=mi_m_bmode_pipeline({'ruta/rf_prebf_homRef_001.mat'},'results/bmode');
% Para scan_lines: options.orientation, time_zero_s y metadatos obligatorios.
% Ver docs/bmode-pipeline.md. MATLAB base; no requiere k-Wave para procesar.
if nargin<2, error('us_bmode:Input','Indique archivos MAT y directorio de salida.'); end
if nargin<3, options=struct(); end
summary=us_bmode_batch(input_files,output_root,options);
end
