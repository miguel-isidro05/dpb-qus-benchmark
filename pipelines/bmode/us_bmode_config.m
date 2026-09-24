function cfg = us_bmode_config(overrides)
%US_BMODE_CONFIG Opciones centralizadas. Metros, segundos y Hz.
% TGC está apagado por Semana_2_retro/retro.md, sección 1.
cfg = struct('input_kind','auto','orientation','', 'metadata',struct(), ...
    'time_zero_s',[], 'blank_time_s',[], 'blank_guard_cycles',1, ...
    'filter_enabled',true,'filter_fwhm_percent',100, ...
    'dynamic_range_db',50,'reference_amplitude',[], ...
    'receive_focus_mode','dynamic','receive_f_number',[], ...
    'receive_min_elements',16, ...
    'tgc_enabled',false,'tgc_alpha',[],'tgc_power',[], ...
    'tgc_max_gain_db',40,'export_figures',true,'selected_lines',[], ...
    'depth_limits_cm',[],'comparison_columns',3);
if nargin==0, return; end
if ~isstruct(overrides) || ~isscalar(overrides)
    error('us_bmode:Config','Las opciones deben ser una estructura escalar.');
end
names=fieldnames(overrides);
for k=1:numel(names)
    name=names{k};
    if ~isfield(cfg,name), error('us_bmode:Config','Opción desconocida: %s',name); end
    cfg.(name)=overrides.(name);
end
positive={'filter_fwhm_percent','dynamic_range_db','comparison_columns','receive_min_elements'};
for k=1:numel(positive), validateattributes(cfg.(positive{k}),{'numeric'},{'real','scalar','finite','positive'}); end
nonnegative={'blank_guard_cycles','tgc_max_gain_db'};
for k=1:numel(nonnegative), validateattributes(cfg.(nonnegative{k}),{'numeric'},{'real','scalar','finite','nonnegative'}); end
if cfg.tgc_max_gain_db>300
    error('us_bmode:Config','TGC visual limitado a un máximo de 300 dB para evitar desbordamiento.');
end
optional={'time_zero_s','blank_time_s','tgc_alpha','tgc_power','reference_amplitude'};
for k=1:numel(optional)
    if ~isempty(cfg.(optional{k}))
        validateattributes(cfg.(optional{k}),{'numeric'},{'real','scalar','finite','nonnegative'});
    end
end
if ~isempty(cfg.reference_amplitude) && cfg.reference_amplitude==0
    error('us_bmode:Config','La referencia debe ser positiva.');
end
if ~isempty(cfg.receive_f_number)
    validateattributes(cfg.receive_f_number,{'numeric'},{'real','scalar','finite','positive'});
end
if ~ismember(string(cfg.receive_focus_mode), ["dynamic", "fixed"])
    error('us_bmode:Config', 'receive_focus_mode debe ser dynamic o fixed.');
end
flags={'filter_enabled','tgc_enabled','export_figures'};
for k=1:numel(flags), validateattributes(cfg.(flags{k}),{'logical'},{'scalar'}); end
if ~isstruct(cfg.metadata) || ~isscalar(cfg.metadata)
    error('us_bmode:Config','metadata debe ser una estructura escalar.');
end
if ~ismember(string(cfg.input_kind),["auto","rf_prebf","scan_lines"])
    error('us_bmode:Config','input_kind: auto, rf_prebf o scan_lines.');
end
if ~ismember(string(cfg.orientation),["","time_line","line_time"])
    error('us_bmode:Orientation','orientation: time_line o line_time.');
end
validateattributes(cfg.comparison_columns,{'numeric'},{'integer'});
validateattributes(cfg.receive_min_elements,{'numeric'},{'integer'});
if ~isempty(cfg.depth_limits_cm)
    validateattributes(cfg.depth_limits_cm,{'numeric'},{'real','finite','numel',2,'nonnegative'});
    if diff(cfg.depth_limits_cm)<=0, error('us_bmode:Config','Límites axiales no crecientes.'); end
end
if ~isempty(cfg.selected_lines)
    validateattributes(cfg.selected_lines,{'numeric'},{'real','vector','finite','integer','positive'});
end
end
