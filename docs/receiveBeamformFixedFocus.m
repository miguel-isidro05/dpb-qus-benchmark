function [scanLine, rfAligned, rxDelay, elementPos] = ...
    receiveBeamformFixedFocus(rfRaw, fs, c0, elementPitch, focusDepth)
% receiveBeamformFixedFocus
% Receive beamforming DAS con foco fijo.
%
% INPUTS
%   rfRaw        : matriz RF [Nt x nElements]
%   fs           : frecuencia de muestreo [Hz]
%   c0           : velocidad del sonido [m/s]
%   elementPitch : pitch del array [m]
%   focusDepth   : profundidad del foco [m]
%
% OUTPUTS
%   scanLine   : señal RF beamformed [Nt x 1]
%   rfAligned  : canales alineados [Nt x nElements]
%   rxDelay    : delays relativos de recepción [1 x nElements] [s]
%   elementPos : posición lateral de cada elemento [1 x nElements] [m]
%
% NOTA
%   Implementa un DAS de recepción con foco fijo centrado lateralmente
%   en x = 0. No aplica TGC ni filtrado.

    %% Validaciones básicas
    if ndims(rfRaw) ~= 2
        error('rfRaw debe tener dimensiones [Nt x nElements].');
    end

    if fs <= 0 || c0 <= 0 || elementPitch <= 0 || focusDepth <= 0
        error('fs, c0, elementPitch y focusDepth deben ser positivos.');
    end

    [Nt, nElements] = size(rfRaw);

    %% Eje temporal
    t = (0:Nt-1)' / fs;

    %% Posiciones laterales de los elementos, centradas en 0
    elementPos = ((0:nElements-1) - (nElements-1)/2) * elementPitch;

    %% Distancia desde el foco hasta cada elemento
    receiveDistance = sqrt(focusDepth.^2 + elementPos.^2);

    %% Delay relativo respecto al centro del array
    rxDelay = (receiveDistance - focusDepth) / c0;

    %% Alineación temporal
    rfAligned = zeros(Nt, nElements, 'like', double(rfRaw));

    rfRawDouble = double(rfRaw);

    for iElement = 1:nElements

        % El eco de los elementos alejados del centro llega más tarde.
        % Para alinearlo al canal central, se evalúa el canal en t + delay.
        sampleTime = t + rxDelay(iElement);

        rfAligned(:, iElement) = interp1( ...
            t, ...
            rfRawDouble(:, iElement), ...
            sampleTime, ...
            'linear', ...
            0);
    end

    %% Delay-and-sum
    % mean() evita que la amplitud dependa directamente del número de canales.
    scanLine = mean(rfAligned, 2);

end
