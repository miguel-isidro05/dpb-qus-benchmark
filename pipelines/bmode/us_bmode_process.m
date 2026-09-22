function result = us_bmode_process(input, options)
%US_BMODE_PROCESS RF/scan lines -> B-mode lineal, sin TGC por defecto.
% Ver docs/bmode-design.md para fuentes por etapa y límites físicos.
if nargin<2, options=struct(); end
cfg=us_bmode_config(options);
requested_config=cfg;
[d,provenance]=us_bmode_read(input,cfg);
kind=chooseKind(d,cfg.input_kind);
required={'fs','c0','x','source_f0'};
if strcmp(kind,'rf_prebf')
    required=[required,{'source_focus','element_pitch','source_cycles','time_delays'}];
end
for k=1:numel(required)
    if ~isfield(d,required{k}), error('us_bmode:Metadata','Falta %s.',required{k}); end
end
for name={'fs','c0','source_f0'}
    validateattributes(d.(name{1}),{'numeric'},{'real','scalar','finite','positive'});
end
if d.source_f0>=d.fs/2, error('us_bmode:Nyquist','f0 debe ser menor que fs/2.'); end
raw=d.(kind);
if ~isnumeric(raw) || ~isreal(raw) || isempty(raw) || any(~isfinite(raw(:)))
    error('us_bmode:RF','RF debe ser numérica, real, finita y no vacía.');
end
warnings={};
if strcmp(kind,'rf_prebf')
    validateFocusedMetadata(d,size(raw,2));
    [rf,valid,bf]=us_bmode_beamform(raw,d.fs,d.c0,d.source_focus,d.element_pitch);
    [estimated_zero,blank_auto]=focusedTiming(d,size(raw,2));
    warnings{end+1}='Foco Rx fijo: precisión fuera del foco no validada.';
    warnings{end+1}='Origen temporal estimado desde Tx/pulso; requiere reflector conocido para validar eje axial.';
    if isfield(d,'grid_size_y')
        validateattributes(d.grid_size_y,{'numeric'},{'real','scalar','finite','positive'});
        half_width=(size(raw,2)-1)*d.element_pitch/2;
        if isfield(d,'element_width')
            validateattributes(d.element_width,{'numeric'},{'real','scalar','finite','positive'});
            half_width=half_width+d.element_width/2;
        end
        if max(abs(d.x))+half_width>d.grid_size_y/2
            warnings{end+1}='Posible recorte Rx en líneas extremas por ancho lateral insuficiente; revisar adquisición.';
        end
    end
else
    if ~ismatrix(raw), error('us_bmode:RF','scan_lines debe tener dos dimensiones.'); end
    if strcmp(cfg.orientation,'time_line')
        rf=double(raw);
    elseif strcmp(cfg.orientation,'line_time')
        rf=double(raw');
    else
        error('us_bmode:Orientation','Declare orientation: time_line o line_time.');
    end
    valid=true(size(rf,1),1); bf=struct('method','already_beamformed');
    if isfield(d,'time_zero_s'), estimated_zero=d.time_zero_s;
    else, estimated_zero=[]; end
    blank_auto=0;
    if isempty(cfg.blank_time_s)
        warnings{end+1}='Scan lines externas: sin máscara automática de transmisión; declare blank_time_s si corresponde.';
    end
end
nt=size(rf,1); nl=size(rf,2);
if nt<2, error('us_bmode:RF','Se requieren al menos dos muestras temporales.'); end
validateAxes(d,nt,nl);
zero=cfg.time_zero_s;
if isempty(zero), zero=estimated_zero; end
if isempty(zero), error('us_bmode:Metadata','Declare time_zero_s para scan lines externas.'); end
validateattributes(zero,{'numeric'},{'real','scalar','finite','nonnegative'});
blank=cfg.blank_time_s;
if isempty(blank)
    blank=blank_auto;
    if strcmp(kind,'rf_prebf'), blank=blank+cfg.blank_guard_cycles/d.source_f0; end
end
time=(0:nt-1)'/d.fs; z=(time-zero)*d.c0/2;
support=valid & time>=blank & z>=0;
if ~any(support), error('us_bmode:Support','Sin muestras válidas tras máscara/origen temporal.'); end
masked=rf; masked(~support,:)=0;
[filtered,filter_info]=fundamentalFilter(masked,d.fs,d.source_f0,cfg);
% Hilbert en el eje temporal, con padding nulo a ambos extremos.
if cfg.filter_enabled
    analytic=analyticSignal([zeros(nt,nl);filtered;zeros(nt,nl)]);
    envelope=abs(analytic(nt+1:2*nt,:));
else
    envelope=abs(analyticSignal(filtered));
end
envelope(~support,:)=0;
reference=cfg.reference_amplitude;
reference_source='explicit';
if isempty(reference)
    reference=max(envelope(:)); reference_source='per_image_auto_not_for_case_comparison';
    if reference==0, reference=1; reference_source='all_zero_fallback_1'; end
end
cfg.time_zero_s=zero; cfg.blank_time_s=blank; cfg.reference_amplitude=reference;
result=struct('scan_lines',rf,'rf_masked',masked,'rf_filtered',filtered, ...
    'envelope_no_tgc',envelope,'bmode_db',us_bmode_compress(envelope,reference,cfg.dynamic_range_db), ...
    'x_m',double(d.x(:)'),'z_nominal_m',time*d.c0/2,'z_m',z,'time_s',time, ...
    'valid_support',support,'receive_support',valid,'beamforming',bf,'filter',filter_info, ...
    'time_zero_s',zero,'blank_time_s',blank,'reference_amplitude',reference, ...
    'reference_source',reference_source,'config',cfg,'requested_config',requested_config,'provenance',provenance, ...
    'input_kind',kind,'warnings',{warnings});
meta=rmfield(d,intersect(fieldnames(d),{'rf_prebf','scan_lines'}));
result.metadata=meta;
result.tgc_gain=[]; result.envelope_tgc_visual=[]; result.bmode_tgc_visual_db=[];
if cfg.tgc_enabled
    if isempty(cfg.tgc_alpha) || isempty(cfg.tgc_power)
        error('us_bmode:Metadata','TGC visual requiere tgc_alpha y tgc_power explícitos.');
    end
    gain_db=min(cfg.tgc_max_gain_db,2*cfg.tgc_alpha*(d.source_f0/1e6)^cfg.tgc_power*max(z,0)*100);
    if any(~isfinite(gain_db))
        error('us_bmode:Config','TGC no finito; revise coeficiente/exponente.');
    end
    result.tgc_gain=10.^(gain_db/20);
    result.envelope_tgc_visual=envelope.*result.tgc_gain;
    result.bmode_tgc_visual_db=us_bmode_compress(result.envelope_tgc_visual,reference,cfg.dynamic_range_db);
end
end

function kind=chooseKind(d,requested)
present=[isfield(d,'rf_prebf'),isfield(d,'scan_lines')];
if strcmp(requested,'auto')
    if sum(present)~=1, error('us_bmode:InputKind','Declare input_kind cuando hay ambas RF o ninguna.'); end
    if present(1), kind='rf_prebf'; else, kind='scan_lines'; end
else
    kind=char(requested);
    if ~isfield(d,kind), error('us_bmode:InputKind','Entrada sin %s.',kind); end
end
end

function validateFocusedMetadata(d,ne)
for name={'source_focus','element_pitch','source_cycles'}
    validateattributes(d.(name{1}),{'numeric'},{'real','scalar','finite','positive'});
end
validateattributes(d.time_delays,{'numeric'},{'real','vector','finite','nonnegative','numel',ne});
if isfield(d,'rotation')
    validateattributes(d.rotation,{'numeric'},{'real','scalar','finite'});
    if d.rotation~=0, error('us_bmode:Geometry','Sólo geometría sin rotación.'); end
end
if isfield(d,'focal_number_Tx')
    validateattributes(d.focal_number_Tx,{'numeric'},{'real','scalar','finite','positive'});
end
end

function [zero,blank]=focusedTiming(d,ne)
position=((0:ne-1)-(ne-1)/2)*d.element_pitch;
discrete_delay=round(d.time_delays(:)'*d.fs)/d.fs;
extra=(sqrt(d.source_focus^2+position.^2)-d.source_focus)/d.c0;
active=true(1,ne);
if isfield(d,'focal_number_Tx')
    ntx=floor(d.source_focus/d.focal_number_Tx/d.element_pitch);
    inactive=floor((ne-ntx)/2);
    if ntx<1 || ntx>ne, error('us_bmode:Geometry','Apertura Tx incompatible con canales Rx.'); end
    active(1:inactive)=false; active(end-inactive+1:end)=false;
end
% Centro de la duración discretizada de toneBurst (0:dt:cycles/f0).
pulse_duration=floor(d.source_cycles/d.source_f0*d.fs)/d.fs;
zero=median(discrete_delay(active)+extra(active))+pulse_duration/2;
blank=max(discrete_delay(active))+pulse_duration;
end

function validateAxes(d,nt,nl)
if ~isnumeric(d.x) || ~isreal(d.x) || numel(d.x)~=nl || any(~isfinite(d.x(:)))
    error('us_bmode:Axes','x debe contener una coordenada finita en metros por línea.');
end
step=diff(double(d.x(:)));
if any(step<=0) || (~isempty(step) && max(abs(step-step(1)))>max(1e-12,abs(step(1))*1e-6))
    error('us_bmode:Axes','Se requiere x uniforme y creciente para imagesc lineal.');
end
if isfield(d,'nLines') && (~isscalar(d.nLines) || d.nLines~=nl)
    error('us_bmode:Axes','nLines no coincide con RF.');
end
if isfield(d,'z')
    expected=(0:nt-1)'/d.fs*d.c0/2;
    if ~isnumeric(d.z) || ~isreal(d.z) || numel(d.z)~=nt || any(~isfinite(d.z(:))) || ...
            max(abs(double(d.z(:))-expected))>max(1e-10,d.c0/d.fs*1e-4)
        error('us_bmode:Axes','z debe coincidir con eje nominal c0*t/2.');
    end
end
end

function [filtered,info]=fundamentalFilter(rf,fs,f0,cfg)
nt=size(rf,1); nfft=2^nextpow2(3*nt);
freq=(0:nfft-1)'*fs/nfft; signed=freq; signed(freq>fs/2)=freq(freq>fs/2)-fs;
sigma=(f0*cfg.filter_fwhm_percent/100)/(2*sqrt(2*log(2)));
if cfg.filter_enabled && f0+2*sigma>=fs/2
    error('us_bmode:Nyquist','Banda del filtro (f0 + 2 sigma) alcanza Nyquist.');
end
response=exp(-0.5*((abs(signed)-f0)/sigma).^2);
if cfg.filter_enabled
    padded=[zeros(nt,size(rf,2));rf;zeros(nt,size(rf,2))];
    output=real(ifft(fft(padded,nfft,1).*response,[],1));
    filtered=output(nt+1:2*nt,:);
else
    filtered=rf; response=ones(nfft,1);
end
half=1:floor(nfft/2)+1;
info=struct('enabled',cfg.filter_enabled,'kind','symmetric_gaussian_amplitude', ...
    'f0_hz',f0,'fwhm_percent',cfg.filter_fwhm_percent, ...
    'frequency_hz',freq(half),'response',response(half));
end

function analytic=analyticSignal(rf)
% Hilbert vía FFT: sólo MATLAB base, sin Signal Processing Toolbox.
n=size(rf,1); multiplier=zeros(n,1); multiplier(1)=1;
if mod(n,2)==0, multiplier(2:n/2)=2; multiplier(n/2+1)=1;
else, multiplier(2:(n+1)/2)=2; end
analytic=ifft(fft(rf,[],1).*multiplier,[],1);
end
