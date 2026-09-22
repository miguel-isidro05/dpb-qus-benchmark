function us_bmode_export(r, folder)
%US_BMODE_EXPORT Figuras MATLAB; sólo directorio nuevo del lote.
if ~isfolder(folder), error('us_bmode:Output','Directorio de salida inexistente.'); end
cfg=r.config;
lines=cfg.selected_lines;
if isempty(lines), lines=unique([1,round((size(r.scan_lines,2)+1)/2),size(r.scan_lines,2)]); end
if any(lines>size(r.scan_lines,2)), error('us_bmode:Config','selected_lines excede nLines.'); end
show=r.valid_support;
if ~isempty(cfg.depth_limits_cm)
    show=show & r.z_m*100>=cfg.depth_limits_cm(1) & r.z_m*100<=cfg.depth_limits_cm(2);
end
if nnz(show)<2, error('us_bmode:Output','Menos de dos muestras en rango axial visible.'); end

fig=newFigure; clean=onCleanup(@()close(fig));
drawBmode(r,r.bmode_db,show,'B-mode sin TGC');
writeFigure(fig,folder,'bmode_no_tgc'); clear clean

fig=newFigure; clean=onCleanup(@()close(fig));
imagesc(r.x_m*100,r.z_m(show)*100,r.scan_lines(show,:));
axis image; xlabel('Lateral [cm]'); ylabel('Axial [cm]');
title('RF beamformada (amplitud original)'); colorbar;
writeFigure(fig,folder,'rf_scanlines'); clear clean

fig=newFigure; clean=onCleanup(@()close(fig));
tiledlayout(numel(lines),1,'TileSpacing','compact');
for line=lines(:)'
    nexttile;
    plot(r.z_m(show)*100,r.rf_filtered(show,line),'Color',[0.3 0.3 0.3]); hold on;
    plot(r.z_m(show)*100,r.envelope_no_tgc(show,line),'k','LineWidth',1.2);
    xlabel('Axial [cm]'); ylabel('Amplitud');
    title(sprintf('Línea %d, lateral %.3f cm',line,r.x_m(line)*100));
    legend('RF filtrada','Envolvente sin TGC'); grid on;
end
writeFigure(fig,folder,'rf_and_envelope'); clear clean

fig=newFigure; clean=onCleanup(@()close(fig));
[f,before,after]=spectra(r);
reference=max([before;after]); if reference==0, reference=1; end
tiledlayout(2,1,'TileSpacing','compact'); nexttile;
plot(f/1e6,20*log10(max(before/reference,realmin)), 'Color',[0.4 0.4 0.4]); hold on;
plot(f/1e6,20*log10(max(after/reference,realmin)),'k');
xlabel('Frecuencia [MHz]'); ylabel('Amplitud espectral [dB relativos]');
legend('RF con máscara','RF filtrada'); title('Misma ventana y referencia espectral'); grid on; ylim([-100 5]);
nexttile;
plot(r.filter.frequency_hz/1e6,r.filter.response,'k');
xlabel('Frecuencia [MHz]'); ylabel('Respuesta de amplitud'); title('Filtro fundamental'); grid on;
writeFigure(fig,folder,'spectra_filter'); clear clean

fig=newFigure; clean=onCleanup(@()close(fig));
plot(r.z_m(show)*100,mean(r.envelope_no_tgc(show,:),2),'k'); grid on;
xlabel('Axial [cm]'); ylabel('Envolvente media (amplitud original)');
title('Perfil de profundidad: diagnóstico, no estimador de atenuación');
writeFigure(fig,folder,'depth_profile'); clear clean

if cfg.tgc_enabled
    fig=newFigure; clean=onCleanup(@()close(fig));
    tiledlayout(1,2); nexttile; drawBmode(r,r.bmode_db,show,'Sin TGC');
    nexttile; drawBmode(r,r.bmode_tgc_visual_db,show,'TGC visual (no QUS)');
    writeFigure(fig,folder,'bmode_tgc_comparison'); clear clean
    fig=newFigure; clean=onCleanup(@()close(fig));
    drawBmode(r,r.bmode_tgc_visual_db,show,'B-mode con TGC visual (no QUS)');
    writeFigure(fig,folder,'bmode_tgc_visual'); clear clean
end
end

function fig=newFigure
fig=figure('Visible','off','Color','w','Position',[100 100 1100 700]);
end

function drawBmode(r,image,show,label)
imagesc(r.x_m*100,r.z_m(show)*100,image(show,:),[-r.config.dynamic_range_db 0]);
axis image; colormap(gca,gray(256)); xlabel('Lateral [cm]'); ylabel('Axial [cm]');
title({label,sprintf('Aref = %.4g (ver procedencia en MAT)',r.reference_amplitude)},'Interpreter','none');
cb=colorbar; ylabel(cb,'dB relativos');
if range(r.x_m)/range(r.z_m(show))<0.1, xticks(mean(r.x_m)*100); end
end

function writeFigure(fig,folder,name)
png=fullfile(folder,[name '.png']); matfig=fullfile(folder,[name '.fig']);
if isfile(png) || isfile(matfig), error('us_bmode:Output','Se rechaza sobrescribir %s.',name); end
exportgraphics(fig,png,'Resolution',180); savefig(fig,matfig);
end

function [freq,before,after]=spectra(r)
rows=find(r.valid_support); n=numel(rows);
if n<2, error('us_bmode:Support','Espectro requiere dos muestras válidas.'); end
window=0.5-0.5*cos(2*pi*(0:n-1)'/(n-1));
nfft=2^nextpow2(n);
before=sqrt(mean(abs(fft(r.rf_masked(rows,:).*window,nfft,1)).^2,2));
after=sqrt(mean(abs(fft(r.rf_filtered(rows,:).*window,nfft,1)).^2,2));
half=1:floor(nfft/2)+1; freq=(half'-1)*r.metadata.fs/nfft;
before=before(half); after=after(half);
end
