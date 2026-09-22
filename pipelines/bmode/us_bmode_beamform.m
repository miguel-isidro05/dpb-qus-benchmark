function [scan_lines, valid, info] = us_bmode_beamform(rf,fs,c0,focus,pitch)
%US_BMODE_BEAMFORM DAS de recepción con foco fijo, pesos uniformes.
% Un reflector al foco llega más tarde a elementos externos. Por eso
% se consulta cada canal en t + (sqrt(F^2+p^2)-F)/c, NO en t-delay.
% Método propuesto para F lineal 2D, no DAS general ni enfoque dinámico.
validateattributes(rf,{'numeric'},{'real','finite','nonempty'});
validateattributes(fs,{'numeric'},{'real','scalar','finite','positive'});
validateattributes(c0,{'numeric'},{'real','scalar','finite','positive'});
validateattributes(focus,{'numeric'},{'real','scalar','finite','positive'});
validateattributes(pitch,{'numeric'},{'real','scalar','finite','positive'});
nt=size(rf,1); ne=size(rf,2); nl=size(rf,3);
if nt<2 || ndims(rf)>3, error('us_bmode:RF','RF debe ser [tiempo,elemento,línea].'); end
positions=((0:ne-1)-(ne-1)/2)*pitch;
delay=(sqrt(focus^2+positions.^2)-focus)/c0;
time=(0:nt-1)'/fs;
valid=time+max(delay)<=time(end);
scan_lines=zeros(nt,nl);
for line=1:nl
    total=zeros(nt,1);
    for element=1:ne
        total=total+interp1(time,double(rf(:,element,line)),time+delay(element),'linear',0);
    end
    scan_lines(:,line)=total/ne;
end
info=struct('method','fixed_focus_uniform_mean','receive_delay_s',delay, ...
    'element_positions_m',positions,'focus_m',focus,'weights',ones(1,ne)/ne);
end
