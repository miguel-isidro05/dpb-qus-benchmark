function us_bmode_compare(summary,cfg)
%US_BMODE_COMPARE Paneles con una única referencia de amplitud por lote.
successful=find(strcmp({summary.cases.status},'ok'));
if isempty(successful), return; end
% Paginación: no mantener imágenes de cientos de casos en una figura.
per_page=cfg.comparison_columns*2;
for start=1:per_page:numel(successful)
    page=successful(start:min(start+per_page-1,end));
    fig=figure('Visible','off','Color','w','Position',[100 100 1400 800]);
    cleanup=onCleanup(@()close(fig));
    columns=min(cfg.comparison_columns,numel(page));
    tiledlayout(ceil(numel(page)/columns),columns,'TileSpacing','compact');
    for k=page
        stored=load(fullfile(summary.cases(k).output_dir,'bmode_results.mat'),'result');
        r=stored.result; show=r.valid_support;
        if ~isempty(cfg.depth_limits_cm)
            show=show & r.z_m*100>=cfg.depth_limits_cm(1) & r.z_m*100<=cfg.depth_limits_cm(2);
        end
        nexttile;
        imagesc(r.x_m*100,r.z_m(show)*100,r.bmode_db(show,:),[-cfg.dynamic_range_db 0]);
        axis image; colormap(gca,gray(256)); xlabel('Lateral [cm]'); ylabel('Axial [cm]');
        label=sprintf('Caso %d | %d líneas',k,numel(r.x_m));
        if isfield(r.metadata,'hom_alpha')
            subtitle_label=sprintf('alfa = %.3g | ancho = %.3g cm',r.metadata.hom_alpha,range(r.x_m)*100);
        else
            subtitle_label=sprintf('ancho = %.3g cm',range(r.x_m)*100);
        end
        title({label,subtitle_label},'Interpreter','none'); cb=colorbar; ylabel(cb,'dB');
        if range(r.x_m)/range(r.z_m(show))<0.1, xticks(mean(r.x_m)*100); end
    end
    sgtitle(sprintf('B-mode sin TGC; referencia común %.4g; página %d',summary.reference_amplitude,ceil(start/per_page)), 'Interpreter','none');
    filename=sprintf('bmode_comparison_%03d',ceil(start/per_page));
    exportgraphics(fig,fullfile(summary.run_dir,[filename '.png']),'Resolution',180);
    savefig(fig,fullfile(summary.run_dir,[filename '.fig'])); clear cleanup
end
end
