function [data, provenance] = us_bmode_read(input, cfg)
%US_BMODE_READ Lee únicamente RF y metadatos; no carga mapas grandes.
% No ejecuta código del MAT. Los overrides quedan en provenance.
if isstruct(input) && isscalar(input)
    data=input; provenance=struct('input_file','in_memory','metadata_overrides',cfg.metadata);
elseif (ischar(input) || (isstring(input) && isscalar(input))) && isfile(input)
    info=whos('-file',input);
    allowed={'rf_prebf','scan_lines','x','z','fs','c0','source_f0', ...
        'source_focus','element_pitch','element_width','source_cycles', ...
        'time_delays','nLines','simuName','refSeed','iRef','hom_alpha', ...
        'density_std','grid_size_y','focal_number_Tx','focal_number_Rx', ...
        'active_tx_elements', ...
        'alpha_power','alpha_mode','rotation','time_zero_s'};
    names=intersect({info.name},allowed);
    if isempty(names), error('us_bmode:Input','MAT sin variables del contrato US.'); end
    builtin={'double','single','logical','char','string','int8','int16','int32','int64', ...
        'uint8','uint16','uint32','uint64'};
    selected=info(ismember({info.name},names));
    if ~all(ismember({selected.class},builtin))
        error('us_bmode:Input','El contrato MAT sólo admite clases incorporadas; se rechazan objetos/estructuras.');
    end
    data=load(input,names{:});
    file=dir(input);
    [resolved,attr]=fileattrib(input);
    if ~resolved, error('us_bmode:Input','No se pudo resolver la ruta MAT.'); end
    provenance=struct('input_file',attr.Name,'bytes',file.bytes, ...
        'modified',file.date,'metadata_overrides',cfg.metadata);
else
    error('us_bmode:Input','Entrada: estructura escalar o ruta MAT existente.');
end
names=fieldnames(cfg.metadata);
for k=1:numel(names)
    if ismember(names{k},{'rf_prebf','scan_lines'})
        error('us_bmode:Config','metadata no puede reemplazar datos RF.');
    end
    data.(names{k})=cfg.metadata.(names{k});
end
end
