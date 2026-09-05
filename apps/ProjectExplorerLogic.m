classdef ProjectExplorerLogic
    % ProjectExplorerLogic
    % Explorador de archivos del proyecto para MATLAB App Designer.
    %
    % Componentes esperados:
    %   app.UIFigure, app.Tree, app.RepositorioEditField,
    %   app.RutadesalidaEditField y app.NombreEditField.

    methods (Static)

        function initialize(app)
            rootFolder = ProjectExplorerLogic.findProjectRoot();
            app.RepositorioEditField.Value = rootFolder;
            app.RepositorioEditField.Editable = 'off';
            app.ExperimentoActualEditField.Editable = 'off';
            app.RutadesalidaEditField.Editable = 'off';

            ProjectExplorerLogic.configureFileActions(app);
            ProjectExplorerLogic.setCurrentFolder(app, rootFolder);
            setappdata(app.UIFigure, 'ProjectExplorerHistory', {});
            ProjectExplorerLogic.updateCurrentExperiment(app);
            ProjectExplorerLogic.refreshTree(app);
        end

        function updateCurrentExperiment(app)
            experimentName = strtrim(char(string(app.NombreEditField.Value)));

            if isempty(experimentName)
                experimentName = 'EX-001';
            end

            app.ExperimentoActualEditField.Value = experimentName;
            rootFolder = ProjectExplorerLogic.getRepositoryRoot(app);
            if isempty(rootFolder)
                return
            end

            app.RutadesalidaEditField.Value = fullfile('results', experimentName);
        end

        function refreshTree(app)
            if isempty(app.Tree) || ~isvalid(app.Tree)
                return
            end

            selectedPath = ProjectExplorerLogic.getSelectedPath(app);
            delete(app.Tree.Children);

            currentFolder = ProjectExplorerLogic.getCurrentFolder(app);
            if isempty(currentFolder) || ~isfolder(currentFolder)
                return
            end

            [~, rootName] = fileparts(currentFolder);
            if isempty(rootName)
                rootName = 'Proyecto';
            end

            rootNode = uitreenode(app.Tree, 'Text', rootName, 'NodeData', currentFolder);
            ProjectExplorerLogic.applyNodeIcon(rootNode, currentFolder, true);
            ProjectExplorerLogic.addFolderToTree(rootNode, currentFolder);
            expand(rootNode);

            if ~isempty(selectedPath)
                ProjectExplorerLogic.selectPath(app, rootNode, selectedPath);
            end
        end

        function copySelectedPath(app)
            selectedPath = ProjectExplorerLogic.getSelectedPath(app);
            if isempty(selectedPath) || ~isfile(selectedPath) && ~isfolder(selectedPath)
                % Sin archivo seleccionado, la acción corresponde a la carpeta
                % visible actualmente. Nunca se copia una ruta inexistente.
                selectedPath = ProjectExplorerLogic.getCurrentFolder(app);
            end

            if isfile(selectedPath) || isfolder(selectedPath)
                clipboard('copy', selectedPath);
            end
        end

        function openSelectedFolder(app)
            selectedPath = ProjectExplorerLogic.getSelectedPath(app);
            if isempty(selectedPath)
                selectedPath = fullfile(ProjectExplorerLogic.getRepositoryRoot(app), ...
                    char(string(app.RutadesalidaEditField.Value)));
            end

            if isfile(selectedPath)
                selectedPath = fileparts(selectedPath);
            end

            if isempty(selectedPath) || ~isfolder(selectedPath)
                ProjectExplorerLogic.showError(app, 'La carpeta seleccionada no existe.');
                return
            end

            if ismac
                system(sprintf('open %s', ProjectExplorerLogic.quoteForShell(selectedPath)));
            elseif ispc
                winopen(selectedPath);
            else
                system(sprintf('xdg-open %s', ProjectExplorerLogic.quoteForShell(selectedPath)));
            end
        end

        function showSelectedPathAsTooltip(app)
            selectedPath = ProjectExplorerLogic.getSelectedPath(app);
            app.RutadesalidaEditField.Tooltip = selectedPath;
        end

        function refreshAfterSave(app)
            ProjectExplorerLogic.updateCurrentExperiment(app);
            ProjectExplorerLogic.refreshTree(app);
        end

        function enterDoubleClickedFolder(app, event)
            try
                node = event.InteractionInformation.Node;
            catch
                node = app.Tree.SelectedNodes;
            end

            if isempty(node)
                return
            end

            selectedPath = char(string(node.NodeData));
            if isfolder(selectedPath)
                ProjectExplorerLogic.navigateToFolder(app, selectedPath);
                ProjectExplorerLogic.refreshTree(app);
            end
        end

        function goBack(app)
            history = ProjectExplorerLogic.getNavigationHistory(app);
            if isempty(history)
                return
            end

            previousFolder = history{end};
            history(end) = [];
            setappdata(app.UIFigure, 'ProjectExplorerHistory', history);
            ProjectExplorerLogic.setCurrentFolder(app, previousFolder);
            ProjectExplorerLogic.refreshTree(app);
        end

        function handleKeyPress(app, event)
            if ~ProjectExplorerLogic.isTreeFocused(app)
                return
            end

            key = lower(char(string(event.Key)));
            modifiers = lower(string(event.Modifier));
            hasShortcutModifier = any(modifiers == "control") || any(modifiers == "command");

            if hasShortcutModifier && strcmp(key, 'c')
                ProjectExplorerLogic.copySelection(app);
            elseif hasShortcutModifier && strcmp(key, 'x')
                ProjectExplorerLogic.cutSelection(app);
            elseif hasShortcutModifier && strcmp(key, 'v')
                ProjectExplorerLogic.pasteSelection(app);
            elseif strcmp(key, 'delete') || strcmp(key, 'backspace')
                ProjectExplorerLogic.deleteSelection(app);
            elseif strcmp(key, 'f2')
                ProjectExplorerLogic.renameSelection(app);
            elseif any(modifiers == "alt") && strcmp(key, 'leftarrow')
                ProjectExplorerLogic.goBack(app);
            end
        end

        function copySelection(app)
            sourcePath = ProjectExplorerLogic.getSelectedPath(app);
            if isempty(sourcePath)
                return
            end

            ProjectExplorerLogic.setFileClipboard(app, sourcePath, 'copy');
            clipboard('copy', sourcePath);
        end

        function cutSelection(app)
            sourcePath = ProjectExplorerLogic.getSelectedPath(app);
            if isempty(sourcePath) || ProjectExplorerLogic.isProtectedPath(app, sourcePath)
                return
            end

            ProjectExplorerLogic.setFileClipboard(app, sourcePath, 'cut');
            clipboard('copy', sourcePath);
        end

        function pasteSelection(app)
            fileClipboard = ProjectExplorerLogic.getFileClipboard(app);
            if isempty(fileClipboard) || ~isfile(fileClipboard.sourcePath) && ~isfolder(fileClipboard.sourcePath)
                ProjectExplorerLogic.showError(app, 'No hay un archivo o carpeta válido para pegar.');
                return
            end

            destinationFolder = ProjectExplorerLogic.getPasteDestination(app);
            if isempty(destinationFolder) || ~isfolder(destinationFolder)
                ProjectExplorerLogic.showError(app, 'Selecciona una carpeta de destino antes de pegar.');
                return
            end

            sourcePath = fileClipboard.sourcePath;
            [~, itemName, extension] = fileparts(sourcePath);
            destinationPath = fullfile(destinationFolder, [itemName, extension]);

            if strcmp(sourcePath, destinationPath)
                return
            end

            if isfolder(sourcePath) && ProjectExplorerLogic.isPathInside(destinationFolder, sourcePath)
                ProjectExplorerLogic.showError(app, 'No puedes pegar una carpeta dentro de sí misma.');
                return
            end

            if isfile(destinationPath) || isfolder(destinationPath)
                ProjectExplorerLogic.showError(app, ...
                    sprintf('Ya existe un elemento llamado "%s" en la carpeta de destino.', [itemName, extension]));
                return
            end

            try
                if strcmp(fileClipboard.operation, 'copy')
                    [success, message] = copyfile(sourcePath, destinationPath);
                else
                    [success, message] = movefile(sourcePath, destinationPath);
                end
            catch exception
                success = false;
                message = exception.message;
            end

            if ~success
                ProjectExplorerLogic.showError(app, message);
                return
            end

            if strcmp(fileClipboard.operation, 'cut')
                ProjectExplorerLogic.clearFileClipboard(app);
            end
            ProjectExplorerLogic.refreshTree(app);
        end

        function renameSelection(app)
            sourcePath = ProjectExplorerLogic.getSelectedPath(app);
            if isempty(sourcePath) || ProjectExplorerLogic.isProtectedPath(app, sourcePath)
                ProjectExplorerLogic.showError(app, 'No puedes renombrar la carpeta raíz visible del explorador.');
                return
            end

            [parentFolder, itemName, extension] = fileparts(sourcePath);
            answer = inputdlg('Nuevo nombre:', 'Renombrar', [1 60], {[itemName, extension]});
            if isempty(answer)
                return
            end

            newName = strtrim(answer{1});
            if ~ProjectExplorerLogic.isValidFileName(newName)
                ProjectExplorerLogic.showError(app, 'El nombre está vacío o contiene caracteres no permitidos.');
                return
            end

            destinationPath = fullfile(parentFolder, newName);
            if strcmp(sourcePath, destinationPath)
                return
            end
            if isfile(destinationPath) || isfolder(destinationPath)
                ProjectExplorerLogic.showError(app, 'Ya existe un elemento con ese nombre.');
                return
            end

            try
                [success, message] = movefile(sourcePath, destinationPath);
            catch exception
                success = false;
                message = exception.message;
            end

            if ~success
                ProjectExplorerLogic.showError(app, message);
                return
            end

            ProjectExplorerLogic.refreshTree(app);
        end

        function deleteSelection(app)
            sourcePath = ProjectExplorerLogic.getSelectedPath(app);
            if isempty(sourcePath) || ProjectExplorerLogic.isProtectedPath(app, sourcePath)
                ProjectExplorerLogic.showError(app, 'No puedes eliminar la carpeta raíz visible del explorador.');
                return
            end

            [~, itemName, extension] = fileparts(sourcePath);
            itemName = [itemName, extension];
            uiconfirm(app.UIFigure, ...
                sprintf('Se eliminará "%s" de forma permanente.\n\n¿Deseas continuar?', itemName), ...
                'Confirmar eliminación', ...
                'Options', {'Eliminar', 'Cancelar'}, ...
                'DefaultOption', 'Cancelar', ...
                'CancelOption', 'Cancelar', ...
                'CloseFcn', @(~, event) ProjectExplorerLogic.confirmDelete(app, sourcePath, event.SelectedOption));
        end

    end

    methods (Static, Access = private)

        function configureFileActions(app)
            existingMenu = getappdata(app.UIFigure, 'ProjectExplorerContextMenu');
            if ~isempty(existingMenu) && isvalid(existingMenu)
                delete(existingMenu);
            end

            contextMenu = uicontextmenu(app.UIFigure);
            uimenu(contextMenu, 'Text', 'Copiar', 'MenuSelectedFcn', ...
                @(~, ~) ProjectExplorerLogic.copySelection(app));
            uimenu(contextMenu, 'Text', 'Cortar', 'MenuSelectedFcn', ...
                @(~, ~) ProjectExplorerLogic.cutSelection(app));
            uimenu(contextMenu, 'Text', 'Pegar', 'Separator', 'on', 'MenuSelectedFcn', ...
                @(~, ~) ProjectExplorerLogic.pasteSelection(app));
            uimenu(contextMenu, 'Text', 'Atrás', 'MenuSelectedFcn', ...
                @(~, ~) ProjectExplorerLogic.goBack(app));
            uimenu(contextMenu, 'Text', 'Renombrar', 'Separator', 'on', 'MenuSelectedFcn', ...
                @(~, ~) ProjectExplorerLogic.renameSelection(app));
            uimenu(contextMenu, 'Text', 'Eliminar', 'MenuSelectedFcn', ...
                @(~, ~) ProjectExplorerLogic.deleteSelection(app));

            app.Tree.ContextMenu = contextMenu;
            app.UIFigure.WindowKeyPressFcn = @(~, event) ProjectExplorerLogic.handleKeyPress(app, event);
            contextMenu.ContextMenuOpeningFcn = @(~, event) ...
                ProjectExplorerLogic.selectContextNode(app, event);
            setappdata(app.UIFigure, 'ProjectExplorerContextMenu', contextMenu);
            ProjectExplorerLogic.clearFileClipboard(app);
        end

        function selectContextNode(app, event)
            % R2023b+ informa el nodo bajo el cursor antes de abrir el menú.
            % En versiones anteriores MATLAB conserva el nodo ya seleccionado.
            try
                clickedNode = event.InteractionInformation.Node;
                if ~isempty(clickedNode)
                    app.Tree.SelectedNodes = clickedNode;
                end
            catch
            end
        end

        function confirmDelete(app, sourcePath, selectedOption)
            if ~strcmp(selectedOption, 'Eliminar') || ~exist(sourcePath, 'file') && ~isfolder(sourcePath)
                return
            end

            try
                if isfolder(sourcePath)
                    rmdir(sourcePath, 's');
                else
                    delete(sourcePath);
                end
            catch exception
                ProjectExplorerLogic.showError(app, exception.message);
                return
            end

            fileClipboard = ProjectExplorerLogic.getFileClipboard(app);
            if ~isempty(fileClipboard) && strcmp(fileClipboard.sourcePath, sourcePath)
                ProjectExplorerLogic.clearFileClipboard(app);
            end
            ProjectExplorerLogic.refreshTree(app);
        end

        function addFolderToTree(parentNode, folderPath)
            items = dir(folderPath);
            if isempty(items)
                return
            end

            names = {items.name};
            isHidden = startsWith(names, '.');
            items = items(~isHidden);
            if isempty(items)
                return
            end

            folders = items([items.isdir]);
            files = items(~[items.isdir]);
            folders = ProjectExplorerLogic.sortDirectoryEntries(folders);
            files = ProjectExplorerLogic.sortDirectoryEntries(files);

            for index = 1:numel(folders)
                childPath = fullfile(folderPath, folders(index).name);
                childNode = uitreenode(parentNode, 'Text', folders(index).name, 'NodeData', childPath);
                ProjectExplorerLogic.applyNodeIcon(childNode, childPath, true);
                ProjectExplorerLogic.addFolderToTree(childNode, childPath);
            end

            for index = 1:numel(files)
                childPath = fullfile(folderPath, files(index).name);
                childNode = uitreenode(parentNode, 'Text', files(index).name, 'NodeData', childPath);
                ProjectExplorerLogic.applyNodeIcon(childNode, childPath, false);
            end
        end

        function entries = sortDirectoryEntries(entries)
            if isempty(entries)
                return
            end
            [~, order] = sort(lower(string({entries.name})));
            entries = entries(order);
        end

        function applyNodeIcon(node, itemPath, isFolder)
            iconPath = ProjectExplorerLogic.findNodeIcon(itemPath, isFolder);
            if ~isempty(iconPath)
                node.Icon = iconPath;
            end
        end

        function iconPath = findNodeIcon(itemPath, isFolder)
            iconFolder = fullfile(matlabroot, 'toolbox', 'matlab', 'icons');
            if isFolder
                iconPath = fullfile(iconFolder, 'foldericon.gif');
                return
            end

            appFolder = fileparts(mfilename('fullpath'));
            customIconFolder = fullfile(appFolder, 'icons');
            [~, ~, extension] = fileparts(itemPath);
            switch lower(extension)
                case '.mlx'
                    customIcon = 'file-mlx.svg';
                case '.md'
                    customIcon = 'file-md.svg';
                case '.csv'
                    customIcon = 'file-csv.svg';
                case '.docx'
                    customIcon = 'file-docx.svg';
                case '.m'
                    customIcon = 'file-m.svg';
                case '.mat'
                    customIcon = 'file-mat.svg';
                otherwise
                    customIcon = '';
            end

            if ~isempty(customIcon)
                candidatePath = fullfile(customIconFolder, customIcon);
                if isfile(candidatePath)
                    iconPath = candidatePath;
                    return
                end
            end

            if isfolder(iconFolder)
                iconPath = fullfile(iconFolder, 'pageicon.gif');
            else
                iconPath = '';
            end
        end

        function selectPath(app, rootNode, selectedPath)
            matchingNode = ProjectExplorerLogic.findNodeByPath(rootNode, selectedPath);
            if ~isempty(matchingNode)
                app.Tree.SelectedNodes = matchingNode;
            end
        end

        function node = findNodeByPath(parentNode, targetPath)
            node = [];
            if strcmp(char(string(parentNode.NodeData)), targetPath)
                node = parentNode;
                return
            end

            for index = 1:numel(parentNode.Children)
                node = ProjectExplorerLogic.findNodeByPath(parentNode.Children(index), targetPath);
                if ~isempty(node)
                    return
                end
            end
        end

        function rootFolder = findProjectRoot()
            helperFile = mfilename('fullpath');
            currentFolder = fileparts(helperFile);

            while true
                hasGit = isfolder(fullfile(currentFolder, '.git'));
                hasResults = isfolder(fullfile(currentFolder, 'results'));
                hasApps = isfolder(fullfile(currentFolder, 'apps'));
                hasSrc = isfolder(fullfile(currentFolder, 'src'));
                hasConfig = isfolder(fullfile(currentFolder, 'config'));
                looksLikeProject = hasGit || (hasResults && (hasApps || hasSrc || hasConfig));

                if looksLikeProject
                    rootFolder = currentFolder;
                    return
                end

                parentFolder = fileparts(currentFolder);
                if strcmp(parentFolder, currentFolder)
                    break
                end
                currentFolder = parentFolder;
            end

            rootFolder = fileparts(helperFile);
        end

        function rootFolder = getRepositoryRoot(app)
            rootFolder = char(string(app.RepositorioEditField.Value));
        end

        function currentFolder = getCurrentFolder(app)
            currentFolder = getappdata(app.UIFigure, 'ProjectExplorerCurrentFolder');
            if isempty(currentFolder) || ~isfolder(currentFolder)
                currentFolder = ProjectExplorerLogic.getRepositoryRoot(app);
            end
        end

        function setCurrentFolder(app, folderPath)
            folderPath = ProjectExplorerLogic.normalizeFolderPath(folderPath);
            setappdata(app.UIFigure, 'ProjectExplorerCurrentFolder', folderPath);
        end

        function navigateToFolder(app, folderPath)
            folderPath = ProjectExplorerLogic.normalizeFolderPath(folderPath);
            currentFolder = ProjectExplorerLogic.getCurrentFolder(app);
            if strcmp(currentFolder, folderPath)
                return
            end

            history = ProjectExplorerLogic.getNavigationHistory(app);
            if isempty(history) || ~strcmp(history{end}, currentFolder)
                history{end + 1} = currentFolder;
                setappdata(app.UIFigure, 'ProjectExplorerHistory', history);
            end
            ProjectExplorerLogic.setCurrentFolder(app, folderPath);
        end

        function history = getNavigationHistory(app)
            history = getappdata(app.UIFigure, 'ProjectExplorerHistory');
            if isempty(history)
                history = {};
            end
        end

        function selectedPath = getSelectedPath(app)
            selectedPath = '';
            if isempty(app.Tree) || ~isvalid(app.Tree) || isempty(app.Tree.SelectedNodes)
                return
            end

            nodeData = app.Tree.SelectedNodes(1).NodeData;
            if ~isempty(nodeData)
                selectedPath = char(string(nodeData));
            end
        end

        function destinationFolder = getPasteDestination(app)
            destinationFolder = ProjectExplorerLogic.getSelectedPath(app);
            if isempty(destinationFolder)
                destinationFolder = ProjectExplorerLogic.getCurrentFolder(app);
            elseif isfile(destinationFolder)
                destinationFolder = fileparts(destinationFolder);
            end
        end

        function setFileClipboard(app, sourcePath, operation)
            setappdata(app.UIFigure, 'ProjectExplorerFileClipboard', ...
                struct('sourcePath', sourcePath, 'operation', operation));
        end

        function fileClipboard = getFileClipboard(app)
            fileClipboard = getappdata(app.UIFigure, 'ProjectExplorerFileClipboard');
        end

        function clearFileClipboard(app)
            if isappdata(app.UIFigure, 'ProjectExplorerFileClipboard')
                rmappdata(app.UIFigure, 'ProjectExplorerFileClipboard');
            end
        end

        function protected = isProtectedPath(app, candidatePath)
            protected = strcmp(ProjectExplorerLogic.getRepositoryRoot(app), candidatePath) || ...
                strcmp(ProjectExplorerLogic.getCurrentFolder(app), candidatePath);
        end

        function inside = isPathInside(candidatePath, parentPath)
            candidatePath = [char(string(candidatePath)), filesep];
            parentPath = [char(string(parentPath)), filesep];
            inside = startsWith(candidatePath, parentPath);
        end

        function folderPath = normalizeFolderPath(folderPath)
            folderPath = char(string(folderPath));
            while numel(folderPath) > 1 && endsWith(folderPath, filesep)
                folderPath(end) = [];
            end
        end

        function valid = isValidFileName(fileName)
            valid = ~isempty(fileName) && ~strcmp(fileName, '.') && ~strcmp(fileName, '..') && ...
                isempty(regexp(fileName, '[\\/:*?"<>|]', 'once'));
        end

        function quotedPath = quoteForShell(path)
            quotedPath = ['"', strrep(path, '"', '\\"'), '"'];
        end

        function showError(app, message)
            uialert(app.UIFigure, char(string(message)), 'Explorador de experimento');
        end

        function focused = isTreeFocused(app)
            % Los atajos del explorador no deben interceptar la escritura
            % normal en los Edit Fields ni en otros controles de la app.
            focused = false;
            try
                focused = isequal(app.UIFigure.CurrentObject, app.Tree);
            catch
                % En versiones que no exponen CurrentObject, no se ejecuta
                % ninguna acción destructiva desde el teclado.
            end
        end

    end
end
