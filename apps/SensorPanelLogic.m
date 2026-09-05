classdef SensorPanelLogic
    % SensorPanelLogic
    % Ajusta los controles visibles del panel Sensor según su tipo.

    methods (Static)

        function initialize(app)
            SensorPanelLogic.updateForSensorType(app);
        end

        function updateForSensorType(app)
            sensorType = char(string(app.TipoDropDown_2.Value));

            switch sensorType
                case 'Plano de medida'
                    app.PlanoDropDownLabel.Text = 'Plano:';
                    SensorPanelLogic.setChoices(app.PlanoDropDown, ...
                        {'XY', 'XZ', 'YZ'}, 'XY');

                    app.PosicindelplanoDropDownLabel.Text = 'Posición del plano:';
                    SensorPanelLogic.setChoices(app.PosicindelplanoDropDown, ...
                        {'Central', 'Inicial', 'Final', 'Personalizada'}, 'Central');

                    app.VariablesDropDownLabel.Text = 'Variables:';
                    SensorPanelLogic.setChoices(app.VariablesDropDown, ...
                        {'p, p_rms, p_max', 'p', 'p_rms', 'p_max'}, 'p, p_rms, p_max');

                case 'Transductor emisor'
                    app.PlanoDropDownLabel.Text = 'Transductor:';
                    SensorPanelLogic.setChoices(app.PlanoDropDown, ...
                        {char(string(app.TipoDropDown.Value))}, char(string(app.TipoDropDown.Value)));

                    app.PosicindelplanoDropDownLabel.Text = 'Referencia:';
                    SensorPanelLogic.setChoices(app.PosicindelplanoDropDown, ...
                        {'Superficie del emisor', 'Centro del emisor'}, 'Superficie del emisor');

                    app.VariablesDropDownLabel.Text = 'Variables:';
                    SensorPanelLogic.setChoices(app.VariablesDropDown, ...
                        {'p, p_rms, p_max', 'p', 'p_rms', 'p_max'}, 'p, p_rms, p_max');

                otherwise
                    app.PlanoDropDownLabel.Text = 'Geometría:';
                    SensorPanelLogic.setChoices(app.PlanoDropDown, ...
                        {'Personalizada'}, 'Personalizada');

                    app.PosicindelplanoDropDownLabel.Text = 'Referencia:';
                    SensorPanelLogic.setChoices(app.PosicindelplanoDropDown, ...
                        {'Definida en configuración'}, 'Definida en configuración');

                    app.VariablesDropDownLabel.Text = 'Variables:';
                    SensorPanelLogic.setChoices(app.VariablesDropDown, ...
                        {'p, p_rms, p_max', 'Personalizadas'}, 'p, p_rms, p_max');
            end
        end

        function refreshEmitterReference(app)
            if strcmp(app.TipoDropDown_2.Value, 'Transductor emisor')
                SensorPanelLogic.updateForSensorType(app);
            end
        end
    end

    methods (Static, Access = private)

        function setChoices(dropDown, items, preferredValue)
            previousValue = char(string(dropDown.Value));
            dropDown.Items = items;

            if any(strcmp(items, previousValue))
                dropDown.Value = previousValue;
            else
                dropDown.Value = preferredValue;
            end
        end
    end
end
