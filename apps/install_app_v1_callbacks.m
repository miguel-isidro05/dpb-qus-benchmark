function install_app_v1_callbacks(appPath)
% INSTALL_APP_V1_CALLBACKS Connects App_v1 controls to QUSConfigurationLogic.
% Uses App Designer's in-memory model so its callbacks survive future saves.

arguments
    appPath (1, :) char
end

if ~isfile(appPath)
    error('No existe el archivo: %s', appPath);
end

specifications = [ ...
    callbackSpec('SetButton', 'ButtonPushedFcn', 'SetButtonPushed', 'QUSConfigurationLogic.onSet(app);')
    callbackSpec('PruebaButton', 'ButtonPushedFcn', 'PruebaButtonPushed', 'QUSConfigurationLogic.onTest(app);')
    callbackSpec('ResetButton', 'ButtonPushedFcn', 'ResetButtonPushed', 'QUSConfigurationLogic.onReset(app);')
    callbackSpec('SaveButton', 'ButtonPushedFcn', 'SaveButtonPushed', 'QUSConfigurationLogic.onSave(app);')
    callbackSpec('OpenConfigButton', 'ButtonPushedFcn', 'OpenConfigButtonPushed', 'QUSConfigurationLogic.onOpen(app);')
    callbackSpec('ConfigurarMedioAcusticoButton', 'ButtonPushedFcn', 'ConfigurarMedioAcusticoButtonPushed', 'QUSConfigurationLogic.openMediumSettings(app);')
    callbackSpec('ConfigurarTransductorButton', 'ButtonPushedFcn', 'ConfigurarTransductorButtonPushed', 'QUSConfigurationLogic.openTransducerSettings(app);')
    callbackSpec('ConfigurarPosicindelsensorButton', 'ButtonPushedFcn', 'ConfigurarPosicindelsensorButtonPushed', 'QUSConfigurationLogic.openSensorSettings(app);')
    callbackSpec('ConfiguracinMenu', 'MenuSelectedFcn', 'ConfiguracinMenuSelected', 'QUSConfigurationLogic.openPipelineSettings(app);')
    ];

reader = appdesigner.internal.serialization.FileReader(appPath);
source = reader.readMATLABCodeText();

document = appdesigner.internal.document.AppDocument.open(appPath, Visible=false);
cleanup = onCleanup(@() document.closeNoPrompt());
internals = struct(document); %#ok<STRNU>
model = internals.AppModel;

components = findall(model.UIFigure, '-property', 'DesignTimeProperties');
componentNames = arrayfun(@(component) string(component.DesignTimeProperties.CodeName), components);
callbackData = struct('Name', {}, 'Code', {});

for index = 1:numel(specifications)
    specification = specifications(index);
    component = components(componentNames == specification.ComponentName);
    if numel(component) ~= 1
        error('No se encontró de forma única el componente %s.', specification.ComponentName);
    end

    component.(specification.PropertyName) = specification.CallbackName;
    callbackData(end + 1) = struct( ...
        'Name', specification.CallbackName, ...
        'Code', {{['            ' specification.CallbackBody]}});
    source = insertCallbackAssignment(source, specification);
end

source = insertCallbackMethods(source, specifications);
source = hideExecutionOverlay(source);

model.CodeModel.Callbacks = callbackData;
model.CodeModel.EditableSectionCode = {};
model.CodeModel.GeneratedCode = source;
model.save(appPath);
end

function specification = callbackSpec(componentName, propertyName, callbackName, callbackBody)
specification = struct( ...
    'ComponentName', componentName, ...
    'PropertyName', propertyName, ...
    'CallbackName', callbackName, ...
    'CallbackBody', callbackBody);
end

function source = insertCallbackAssignment(source, specification)
assignment = sprintf('app.%s.%s = createCallbackFcn(app, @%s, true);', ...
    specification.ComponentName, specification.PropertyName, specification.CallbackName);

if contains(source, assignment)
    return
end

needle = ['            app.' specification.ComponentName ' ='];
startIndex = strfind(source, needle);
if numel(startIndex) ~= 1
    error('No se encontró de forma única la creación de %s.', specification.ComponentName);
end

lineEnd = find(source(startIndex:end) == newline, 1, 'first') + startIndex - 1;
if isempty(lineEnd)
    error('No se pudo insertar el callback para %s.', specification.ComponentName);
end

source = [source(1:lineEnd) newline '            ' assignment source(lineEnd + 1:end)];
end

function source = insertCallbackMethods(source, specifications)
marker = '    % Component initialization';
markerIndex = strfind(source, marker);
if numel(markerIndex) ~= 1
    error('No se encontró el bloque de inicialización de componentes.');
end

methodsBlock = sprintf('    %% Callbacks de configuración reproducible\n    methods (Access = private)\n');
for index = 1:numel(specifications)
    specification = specifications(index);
    methodsBlock = [methodsBlock sprintf([ ...
        '        function %s(app, event)\n' ...
        '            %s\n' ...
        '        end\n\n'], specification.CallbackName, specification.CallbackBody)]; %#ok<AGROW>
end
methodsBlock = [methodsBlock sprintf('    end\n\n')];

source = [source(1:markerIndex - 1) methodsBlock source(markerIndex:end)];
end

function source = hideExecutionOverlay(source)
assignment = '            app.GridLayout15.Visible = ''off'';';
if contains(source, assignment)
    return
end

needle = '            app.GridLayout15 = uigridlayout(app.GridLayout11);';
startIndex = strfind(source, needle);
if numel(startIndex) ~= 1
    error('No se encontró GridLayout15 para liberar el panel Ejecución.');
end

lineEnd = find(source(startIndex:end) == newline, 1, 'first') + startIndex - 1;
source = [source(1:lineEnd) newline assignment source(lineEnd + 1:end)];
end
