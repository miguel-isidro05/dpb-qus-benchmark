%% EX-003: hígado homogéneo con transductor lineal en 3D
% Este ejemplo usa kWaveTransducer, que solo está disponible en 3D. Es la
% referencia física para comparar con EX-001: conserva el mismo medio de
% hígado, pero añade dirección de elevación y enfoque automático.

clearvars;
close all;

%% 1. Preparar la ejecución reproducible
% Los Live Scripts pueden ejecutarse desde una copia temporal de MATLAB;
% por eso se usa una ruta fija y no mfilename('fullpath').
% Cambia solo dpb_root si guardas la carpeta DPB en otro lugar.
dpb_root = '/Users/miguelisidrobaez/Desktop/Academico/Organización/LIM/DPB';
% fullfile une partes de una ruta sin escribir las barras manualmente.
repository_root = fullfile(dpb_root, 'dpb-qus-benchmark');
kwave_root = fullfile(dpb_root, 'Guia_adicional', 'k-wave-ii-develop');
% isfolder comprueba que k-Wave esté instalado antes de usarlo.
assert(isfolder(kwave_root), 'No se encontró k-Wave: %s', kwave_root);
% addpath permite llamar a las funciones de k-Wave en este script.
addpath(kwave_root);
import kwave.legacy.*
experiment_directory = fullfile(repository_root, 'results', 'EX-003_3D_linear_liver');
% Si la carpeta de resultados no existe, mkdir la crea junto con results.
% Si ya existe, no se borra ni se modifica.
if ~isfolder(experiment_directory)
    mkdir(experiment_directory);
end
log_id = fopen(fullfile(experiment_directory, 'log.txt'), 'w');
cleanup_log = onCleanup(@() fclose(log_id));
writeLog(log_id, 'Configuración EX-003 creada.');

%% 2. Definir malla y medio hepático homogéneo
% Se usan c=1595 m/s y rho=1060 kg/m^3 para hígado. Como en los ejemplos
% introductorios de k-Wave, este caso base no activa atenuación ni B/A.
% La malla es menor que un estudio clínico para que el ejemplo sea realizable
% localmente. DataCast single reduce memoria.
% La secuencia conserva la de tus ejemplos: malla -> medio -> señal ->
% transductor -> máscara de sensor -> solver -> patrón de haz. Aquí el
% transductor sustituye a source en kspaceFirstOrder3D, como en el ejemplo
% Defining An Ultrasound Transducer de k-Wave.
c0 = 1595; rho0 = 1060;
f0 = 1e6; ppw = 3; dx = c0 / (f0 * ppw);
Nx = 160; Ny = 96; Nz = 40; pml_size = 10;
kgrid = kWaveGrid(Nx, dx, Ny, dx, Nz, dx);
medium.sound_speed = c0;
medium.density = rho0;
kgrid.makeTime(c0, 0.2, 55e-6);
setup = struct('c0', c0, 'rho0', rho0, 'f0', f0, 'Nx', Nx, 'Ny', Ny, 'Nz', Nz, 'dx', dx, 'pml_size', pml_size);
save(fullfile(experiment_directory, 'setup.mat'), 'setup');

%% 3. Crear el transductor lineal y su pulso
% kWaveTransducer emite velocidad de partícula, no presión. Por eso el pulso
% se convierte mediante p = rho*c*u. El objeto calcula automáticamente los
% retardos para el foco lateral y el foco en elevación.
source_pressure_pa = 1e5;
input_signal = source_pressure_pa / (rho0 * c0) * toneBurst(1 / kgrid.dt, f0, 3);
transducer.number_elements = 32;
transducer.element_width = 1;
transducer.element_length = 4;
transducer.element_spacing = 0;
transducer.radius = inf;
transducer_width = transducer.number_elements * transducer.element_width;
transducer.position = round([pml_size + 2, Ny / 2 - transducer_width / 2, ...
    Nz / 2 - transducer.element_length / 2]);
transducer.sound_speed = c0;
transducer.focus_distance = 30e-3;
transducer.elevation_focus_distance = 30e-3;
transducer.steering_angle = 0;
transducer.transmit_apodization = 'Hanning';
transducer.receive_apodization = 'Hanning';
transducer.active_elements = ones(transducer.number_elements, 1);
transducer.input_signal = input_signal;
transducer = kWaveTransducer(kgrid, transducer);
writeLog(log_id, 'Transductor lineal 3-D configurado.');
% La PML queda dentro de la malla, pero el transductor empieza en x=pml+2.
% Esta separación evita el problema observado en los ejemplos previos: una
% fuente dentro de PML puede generar un patrón de presión incoherente.
figure('Visible', 'off', 'Color', 'w');
transducer.plot;
title('Previsualización 3-D del transductor lineal');
exportgraphics(gcf, fullfile(experiment_directory, 'setup_3D_transducer.png'), 'Resolution', 180);
close(gcf);

%% 4. Definir plano de medida y ejecutar
% Guardar solo p_rms y p_max en el plano x-y central limita el uso de memoria.
% El resultado es el patrón de haz, no RF de retorno: no hay dispersores en
% este medio homogéneo.
sensor.mask = zeros(Nx, Ny, Nz);
sensor.mask(:, :, round(Nz / 2)) = 1;
sensor.record = {'p_rms', 'p_max'};
sensor_data = kspaceFirstOrder3D(kgrid, medium, transducer, sensor, ...
    'PMLSize', pml_size, 'PMLInside', true, 'PlotSim', false, 'DataCast', 'single');
beam_p_max = reshape(gatherIfNeeded(sensor_data.p_max), [Nx, Ny]);
beam_p_rms = reshape(gatherIfNeeded(sensor_data.p_rms), [Nx, Ny]);
writeLog(log_id, 'Simulación 3-D completada.');

%% 5. Visualizar y explicar el patrón de haz
% La figura muestra el plano central x-y. Cerca de la distancia focal debe
% observarse la concentración lateral del haz. En 3D también existe enfoque
% en elevación, aunque no se ve en este corte. Para inspeccionarlo, cambiar
% la máscara al plano x-z y repetir la simulación.
figure('Color', 'w');
tiledlayout(1, 2, 'TileSpacing', 'compact');
nexttile;
imagesc(kgrid.y_vec * 1e3, kgrid.x_vec * 1e3, beam_p_max); axis image; set(gca, 'YDir', 'normal');
xlabel('y [mm]'); ylabel('x [mm]'); title('3-D: p_{max} en plano x-y'); colorbar;
nexttile;
imagesc(kgrid.y_vec * 1e3, kgrid.x_vec * 1e3, beam_p_rms); axis image; set(gca, 'YDir', 'normal');
xlabel('y [mm]'); ylabel('x [mm]'); title('3-D: p_{rms} en plano x-y'); colorbar;
exportgraphics(gcf, fullfile(experiment_directory, 'beam_pattern_3D.png'), 'Resolution', 180);
save(fullfile(experiment_directory, 'results.mat'), 'setup', 'beam_p_max', 'beam_p_rms', '-v7.3');
writeLog(log_id, 'Resultados y beam_pattern_3D.png guardados.');

%% 6. Diferencias que debes observar frente a 2D
% EX-001 usa una representación 2-D: el campo se interpreta por unidad de
% espesor fuera del plano y el arreglo se define con kWaveArray. EX-003 usa
% un volumen y kWaveTransducer: añade difracción y enfoque en elevación, y
% calcula los retardos del foco. Por eso EX-003 es más costoso y el patrón
% tiene una física más completa. Ninguno forma B-mode hasta añadir dispersores
% y una adquisición pulse-echo.

function writeLog(log_id, message)
fprintf(log_id, '%s %s\n', datestr(now, 'yyyy-mm-dd HH:MM:SS'), message);
fprintf('%s\n', message);
end

function value = gatherIfNeeded(value)
if isa(value, 'gpuArray'), value = gather(value); end
end
