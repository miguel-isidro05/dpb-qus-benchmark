function [scanLines, validSupport, info] = us_bmode_beamform(rf, fs, c0, txFocus, pitch, varargin)
%US_BMODE_BEAMFORM DAS de recepción para RF prebeamformada [t, elemento, línea].
% En modo dynamic usa apertura creciente z/F-number con un mínimo de
% elementos, siguiendo el contrato de ADMIRE. El modo fixed se conserva
% para comparar resultados históricos que usaban un único foco de Rx.

parser = inputParser;
addParameter(parser, 'Mode', 'dynamic', @(value) any(strcmp(string(value), ["dynamic", "fixed"])));
addParameter(parser, 'FNumber', [], @(value) isempty(value) || ...
    (isnumeric(value) && isscalar(value) && isfinite(value) && value > 0));
addParameter(parser, 'TimeZero', 0, @(value) isnumeric(value) && isscalar(value) && isfinite(value));
addParameter(parser, 'MinElements', 16, @(value) isnumeric(value) && isscalar(value) && ...
    isfinite(value) && value > 0 && value == round(value));
parse(parser, varargin{:});
mode = char(parser.Results.Mode);
fNumber = parser.Results.FNumber;
timeZero = parser.Results.TimeZero;
minElements = parser.Results.MinElements;

validateattributes(rf, {'numeric'}, {'real', 'finite', 'nonempty'});
validateattributes(fs, {'numeric'}, {'real', 'scalar', 'finite', 'positive'});
validateattributes(c0, {'numeric'}, {'real', 'scalar', 'finite', 'positive'});
validateattributes(txFocus, {'numeric'}, {'real', 'scalar', 'finite', 'positive'});
validateattributes(pitch, {'numeric'}, {'real', 'scalar', 'finite', 'positive'});
if strcmp(mode, 'dynamic') && isempty(fNumber)
    error('us_bmode:Config', 'El modo dynamic requiere FNumber.');
end

[nt, ne, nl] = size(rf);
if nt < 2 || ndims(rf) > 3
    error('us_bmode:RF', 'RF debe tener forma [tiempo, elemento, línea].');
end
time = (0:nt-1)' / fs;
elementPositions = ((0:ne-1) - (ne-1)/2) * pitch;
scanLines = zeros(nt, nl);

if strcmp(mode, 'fixed')
    receiveDelay = (sqrt(txFocus.^2 + elementPositions.^2) - txFocus) / c0;
    validSupport = time + max(receiveDelay) <= time(end);
    for lineIndex = 1:nl
        scanLines(:, lineIndex) = focusedLine(rf(:, :, lineIndex), time, receiveDelay, true(nt, ne));
    end
    info = struct('method', 'fixed_focus_uniform_mean', 'focus_m', txFocus, ...
        'receive_delay_s', receiveDelay, 'element_positions_m', elementPositions, ...
        'f_number', []);
    return
end

% Profundidad de la muestra respecto al centro temporal del pulso emitido.
% ADMIRE define N(z)=ceil(z/(pitch*F#)), lo fuerza par y limita su mínimo
% y máximo. El mínimo evita formar las muestras superficiales con un solo canal.
z = max((time - timeZero) * c0 / 2, 0);
receiveDelay = (sqrt(z.^2 + elementPositions.^2) - z) / c0;
activeElements = ceil(z / (pitch * fNumber));
activeElements = 2 * ceil(activeElements / 2);
activeElements = min(max(activeElements, minElements), ne);
activeMask = centeredApertureMask(activeElements, ne);
validSupport = z > 0 & any(activeMask, 2) & ...
    all(~activeMask | time + receiveDelay <= time(end), 2);
for lineIndex = 1:nl
    scanLines(:, lineIndex) = focusedLine(rf(:, :, lineIndex), time, receiveDelay, activeMask);
end
info = struct('method', 'dynamic_focus_uniform_mean', 'f_number', fNumber, ...
    'element_positions_m', elementPositions, 'time_zero_s', timeZero, ...
    'aperture_m', activeElements * pitch, 'active_elements', activeElements, ...
    'minimum_active_elements', min(minElements, ne));
end

function activeMask = centeredApertureMask(activeElements, totalElements)
%CENTREDAPERTUREMASK Construye aperturas centradas como la máscara ADMIRE.
sampleCount = numel(activeElements);
activeMask = false(sampleCount, totalElements);
for elementCount = unique(activeElements(:))'
    offsets = (1 - elementCount / 2):(elementCount / 2);
    indices = ceil(totalElements / 2 + offsets);
    indices = indices(indices >= 1 & indices <= totalElements);
    activeMask(activeElements == elementCount, indices) = true;
end
end

function scanLine = focusedLine(rfLine, time, receiveDelay, activeMask)
% Suma sólo los canales de la apertura activa; normalizar evita que el
% nivel dependa del número de elementos disponibles a cada profundidad.
nt = numel(time);
ne = size(rfLine, 2);
accumulator = zeros(nt, 1);
weights = zeros(nt, 1);
for elementIndex = 1:ne
    active = activeMask(:, elementIndex);
    if ~any(active)
        continue
    end
    shifted = interp1(time, double(rfLine(:, elementIndex)), ...
        time + receiveDelay(:, elementIndex), 'linear', 0);
    accumulator = accumulator + shifted .* active;
    weights = weights + active;
end
scanLine = accumulator ./ max(weights, 1);
end
