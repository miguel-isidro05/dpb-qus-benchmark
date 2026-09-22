function result = renderBModePipeline(matFile, pipelineKind, varargin)
% renderBModePipeline
% Reconstruye un B-mode de foco fijo leyendo rf_prebf por beam desde matfile.
% No carga el cubo RF completo. Corrige el origen temporal estimado desde
% los retardos Tx y enmascara el intervalo ocupado por el pulso transmitido.

    parser = inputParser;
    parser.FunctionName = mfilename;
    addRequired(parser, 'matFile', @(value) ischar(value) || isstring(value));
    addRequired(parser, 'pipelineKind', @(value) ischar(value) || isstring(value));
    addParameter(parser, 'DynamicRange', 50, ...
        @(value) isnumeric(value) && isscalar(value) && isfinite(value) && value > 0);
    addParameter(parser, 'Visible', true, ...
        @(value) islogical(value) && isscalar(value));
    parse(parser, matFile, pipelineKind, varargin{:});

    B = loadBModeExperiment(parser.Results.matFile);
    validateMetadata(B);
    [timeZero, blankTime, receiveDelay] = focusedTiming(B);

    time = (0:B.Nt - 1)' ./ B.fs;
    axialAxis = (time - timeZero) .* B.c0 ./ 2;
    validSupport = time + max(receiveDelay) <= time(end) & ...
        time >= blankTime & axialAxis >= 0;
    if ~any(validSupport)
        error('No quedan muestras válidas tras corregir el tiempo de llegada y el pulso Tx.');
    end

    rfBeamformed = zeros(B.Nt, B.nLines);
    for lineIndex = 1:B.nLines
        rfLine = B.rfMat.rf_prebf(:, :, lineIndex);
        rfBeamformed(:, lineIndex) = receiveBeamformFixedFocus( ...
            rfLine, B.fs, B.c0, B.element_pitch, B.source_focus);
    end

    rfMasked = rfBeamformed;
    rfMasked(~validSupport, :) = 0;
    rfFiltered = filterFundamental(rfMasked, B.fs, B.source_f0);
    envelope = analyticEnvelope([zeros(B.Nt, B.nLines); rfFiltered; ...
        zeros(B.Nt, B.nLines)]);
    envelope = envelope(B.Nt + 1:2 * B.Nt, :);
    envelope(~validSupport, :) = 0;

    reference = max(envelope(:));
    if reference <= 0 || ~isfinite(reference)
        error('La RF beamformed no contiene una envolvente válida para B-mode.');
    end
    bmodeDb = 20 * log10(max(envelope ./ reference, eps));
    bmodeDb = max(bmodeDb, -parser.Results.DynamicRange);

    lateralAxis = resolveLateralAxis(B);
    visible = selectVisibility(parser.Results.Visible);
    figureHandle = figure('Name', sprintf('B-mode | %s', pipelineKind), ...
        'Color', 'w', 'Visible', visible);
    imagesc(lateralAxis * 1e3, axialAxis(validSupport) * 1e3, ...
        bmodeDb(validSupport, :));
    axis image
    colormap(gray(256));
    clim([-parser.Results.DynamicRange, 0]);
    colorbarHandle = colorbar;
    ylabel(colorbarHandle, 'Amplitud [dB relativos]');
    xlabel('Lateral [mm]');
    ylabel('Profundidad [mm]');
    [~, fileName, fileExtension] = fileparts(char(parser.Results.matFile));
    title(sprintf('B-mode de foco fijo %s: %s%s', char(pipelineKind), ...
        fileName, fileExtension), 'Interpreter', 'none');

    result = struct('bmodeDb', bmodeDb, 'envelope', envelope, ...
        'rfBeamformed', rfBeamformed, 'rfFiltered', rfFiltered, ...
        'lateralAxis', lateralAxis, 'axialAxis', axialAxis, ...
        'validSupport', validSupport, 'timeZero', timeZero, ...
        'blankTime', blankTime, 'experiment', B, 'figure', figureHandle, ...
        'dynamicRange', parser.Results.DynamicRange, ...
        'beamforming', 'fixed_focus_uniform_mean');
end


function validateMetadata(B)
    required = {'fs', 'c0', 'source_f0', 'source_focus', ...
        'element_pitch', 'source_cycles', 'time_delays'};
    for index = 1:numel(required)
        field = required{index};
        if ~isfield(B, field) || isempty(B.(field))
            error('El MAT no incluye metadata requerida para B-mode: %s.', field);
        end
    end
    if B.source_f0 >= B.fs / 2
        error('source_f0 debe ser menor que Nyquist para generar el B-mode.');
    end
    if numel(B.time_delays) ~= B.nElements
        error('time_delays debe tener un valor por Receive element.');
    end
end


function [timeZero, blankTime, receiveDelay] = focusedTiming(B)
    elementPos = ((0:B.nElements - 1) - (B.nElements - 1) / 2) ...
        .* B.element_pitch;
    receiveDelay = (sqrt(B.source_focus.^2 + elementPos.^2) - ...
        B.source_focus) ./ B.c0;
    txDelay = round(double(B.time_delays(:)') .* B.fs) ./ B.fs;
    pulseDuration = floor(B.source_cycles ./ B.source_f0 .* B.fs) ./ B.fs;
    activeTx = activeTransmitMask(B);
    timeZero = median(txDelay(activeTx) + receiveDelay(activeTx)) + ...
        pulseDuration / 2;
    blankTime = max(txDelay(activeTx)) + pulseDuration + 1 / B.source_f0;
end


function mask = activeTransmitMask(B)
    mask = true(1, B.nElements);
    txCount = B.active_tx_elements;
    if isempty(txCount)
        if ~isfield(B, 'focal_number_Tx') || isempty(B.focal_number_Tx)
            return
        end
        % Los MAT históricos usaban el mismo redondeo a ambos lados.
        % Se conserva para estimar correctamente su origen temporal.
        txCount = floor(B.source_focus / B.focal_number_Tx / B.element_pitch);
        inactivePerSide = floor((B.nElements - txCount) / 2);
        mask(1:inactivePerSide) = false;
        mask(end-inactivePerSide+1:end) = false;
        return
    end
    if ~isnumeric(txCount) || ~isscalar(txCount) || ~isfinite(txCount) || ...
            txCount ~= round(txCount)
        error('active_tx_elements debe ser un entero finito.');
    end
    txCount = double(txCount);
    if txCount < 1 || txCount > B.nElements
        error('La apertura Tx es incompatible con los Receive elements guardados.');
    end
    inactiveCount = B.nElements - txCount;
    leftInactive = floor(inactiveCount / 2);
    rightInactive = ceil(inactiveCount / 2);
    if leftInactive > 0
        mask(1:leftInactive) = false;
    end
    if rightInactive > 0
        mask(end-rightInactive+1:end) = false;
    end
end


function filtered = filterFundamental(signal, fs, f0)
    sampleCount = size(signal, 1);
    padded = [zeros(sampleCount, size(signal, 2)); signal; ...
        zeros(sampleCount, size(signal, 2))];
    transformLength = 2 ^ nextpow2(size(padded, 1));
    frequency = (0:transformLength - 1)' .* fs ./ transformLength;
    signedFrequency = frequency;
    signedFrequency(frequency > fs / 2) = ...
        frequency(frequency > fs / 2) - fs;
    sigma = f0 / (2 * sqrt(2 * log(2)));
    response = exp(-0.5 .* ((abs(signedFrequency) - f0) ./ sigma) .^ 2);
    filteredPadded = real(ifft(fft(padded, transformLength, 1) .* response, [], 1));
    filtered = filteredPadded(sampleCount + 1:2 * sampleCount, :);
end


function envelope = analyticEnvelope(signal)
    sampleCount = size(signal, 1);
    multiplier = zeros(sampleCount, 1);
    multiplier(1) = 1;
    if mod(sampleCount, 2) == 0
        multiplier(2:sampleCount / 2) = 2;
        multiplier(sampleCount / 2 + 1) = 1;
    else
        multiplier(2:(sampleCount + 1) / 2) = 2;
    end
    envelope = abs(ifft(fft(signal, [], 1) .* multiplier, [], 1));
end


function lateralAxis = resolveLateralAxis(B)
    if ~isempty(B.yCords) && numel(B.yCords) == B.nLines
        lateralAxis = reshape(double(B.yCords), 1, []);
    else
        error('El MAT no contiene x/yCords con una posición lateral por beam.');
    end
end


function visibility = selectVisibility(showFigure)
    if showFigure
        visibility = 'on';
    else
        visibility = 'off';
    end
end
