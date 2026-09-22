function summary = us_bmode_batch(input_files, output_root, options)
%US_BMODE_BATCH Lista explícita de MAT -> ejecución nueva, referencia común.
% Dos pasadas con resultados en disco: sólo un caso en memoria a la vez.
% No envía trabajos al clúster ni modifica MAT originales.
if nargin<3, options=struct(); end
cfg=us_bmode_config(options);
if ischar(input_files), input_files={input_files}; end
if isstring(input_files), input_files=cellstr(input_files); end
if ~iscell(input_files) || isempty(input_files) || ...
        ~all(cellfun(@(x)ischar(x)||(isstring(x)&&isscalar(x)),input_files))
    error('us_bmode:Input','input_files debe ser una lista explícita de rutas MAT.');
end
if ~isfolder(output_root)
    [ok,msg]=mkdir(output_root); if ~ok, error('us_bmode:Output','%s',msg); end
end
[ok,attr]=fileattrib(output_root);
if ~ok, error('us_bmode:Output','No se pudo resolver output_root.'); end
run_dir=tempname(attr.Name); [ok,msg]=mkdir(run_dir);
if ~ok, error('us_bmode:Output','%s',msg); end
fid=fopen(fullfile(run_dir,'log.txt'),'w');
if fid<0, error('us_bmode:Output','No se pudo crear log.'); end
cleanup=onCleanup(@()fclose(fid));
fprintf(fid,'B-mode pipeline v1 | MATLAB %s | %s\n',version,char(datetime('now')));
entry=struct('input_file','','output_dir','','status','pending','error','','warnings',{{}});
cases=repmat(entry,1,numel(input_files)); max_amplitude=0; signature=[];
for k=1:numel(input_files)
    cases(k).input_file=char(input_files{k});
    cases(k).output_dir=fullfile(run_dir,sprintf('case_%03d',k)); mkdir(cases(k).output_dir);
    fprintf(fid,'Caso %d/%d | lectura -> validación -> beamforming -> máscara -> filtro -> envolvente\n',k,numel(input_files));
    try
        result=us_bmode_process(input_files{k},cfg);
        current_signature=compatibilitySignature(result);
        if isempty(signature), signature=current_signature;
        elseif ~isequaln(signature,current_signature)
            error('us_bmode:Compatibility', ...
                'Caso incompatible con el primero: fs/c0/f0, geometría, DAS, filtro, máscara u origen difieren. Separe los lotes.');
        end
        max_amplitude=max(max_amplitude,max(result.envelope_no_tgc(:)));
        cases(k).warnings=result.warnings;
        for w=1:numel(result.warnings), fprintf(fid,'ADVERTENCIA: %s\n',result.warnings{w}); end
        fprintf(fid,'kind=%s fs=%.9g f0=%.9g t0=%.9g blank=%.9g\n',result.input_kind,result.metadata.fs,result.metadata.source_f0,result.time_zero_s,result.blank_time_s);
        save(fullfile(cases(k).output_dir,'bmode_results.mat'),'result','-v7.3');
        cases(k).status='processed';
    catch err
        cases(k).status='error'; cases(k).error=[err.identifier ': ' err.message];
        fprintf(fid,'ERROR: %s\n',cases(k).error);
    end
end
reference=cfg.reference_amplitude;
if isempty(reference), reference=max_amplitude; source='batch_max_no_tgc';
else, source='explicit_common'; end
if reference==0, reference=1; source='all_zero_batch_fallback_1'; end
fprintf(fid,'Segunda pasada | referencia común %.9g (%s) -> compresión -> exportación\n',reference,source);
for k=find(strcmp({cases.status},'processed'))
    try
        file=fullfile(cases(k).output_dir,'bmode_results.mat'); stored=load(file,'result'); result=stored.result;
        result.reference_amplitude=reference; result.reference_source=source;
        result.config.reference_amplitude=reference;
        result.bmode_db=us_bmode_compress(result.envelope_no_tgc,reference,cfg.dynamic_range_db);
        if cfg.tgc_enabled
            result.bmode_tgc_visual_db=us_bmode_compress(result.envelope_tgc_visual,reference,cfg.dynamic_range_db);
        end
        save(file,'result','-v7.3');
        if cfg.export_figures, us_bmode_export(result,cases(k).output_dir); end
        cases(k).status='ok'; fprintf(fid,'OK: %s\n',cases(k).input_file);
    catch err
        cases(k).status='error'; cases(k).error=[err.identifier ': ' err.message];
        fprintf(fid,'ERROR exportación: %s\n',cases(k).error);
    end
end
summary=struct('run_dir',run_dir,'reference_amplitude',reference,'reference_source',source, ...
    'config',cfg,'cases',cases,'success_count',sum(strcmp({cases.status},'ok')), ...
    'error_count',sum(strcmp({cases.status},'error')), ...
    'compatibility_signature',signature,'comparison_error','');
save(fullfile(run_dir,'batch_summary.mat'),'summary');
if cfg.export_figures
    try
        us_bmode_compare(summary,cfg);
    catch err
        summary.comparison_error=[err.identifier ': ' err.message];
        fprintf(fid,'ERROR comparación: %s\n',summary.comparison_error);
    end
end
save(fullfile(run_dir,'batch_summary.mat'),'summary');
fprintf(fid,'Finalizado: %d correctos, %d errores.\n',summary.success_count,summary.error_count);
fprintf('B-mode: %d correctos, %d errores. Salida: %s\n',summary.success_count,summary.error_count,run_dir);
end

function signature=compatibilitySignature(r)
% Sólo cambiar propiedades del medio bajo estudio, no reconstrucción.
% hom_alpha/density_std/seed/nombre NO forman parte de esta firma.
signature=struct('input_kind',r.input_kind,'beamforming',r.beamforming, ...
    'fs',double(r.metadata.fs),'c0',double(r.metadata.c0), ...
    'f0',double(r.metadata.source_f0),'x_m',r.x_m,'z_m',r.z_m, ...
    'support',r.valid_support,'blank_time_s',r.blank_time_s, ...
    'time_zero_s',r.time_zero_s,'filter_enabled',r.filter.enabled, ...
    'filter_fwhm_percent',r.filter.fwhm_percent);
end
