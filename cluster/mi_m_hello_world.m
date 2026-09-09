disp('Hello World desde MATLAB mike');
fprintf('Usuario: %s\n', getenv('USER'));
fprintf('Job SLURM: %s\n', getenv('SLURM_JOB_ID'));
fprintf('Nodo asignado: %s\n', getenv('SLURMD_NODENAME'));
fprintf('Version de MATLAB: %s\n', version);
fprintf('Carpeta de trabajo: %s\n', pwd);
fprintf('Fecha de ejecucion: %s\n', char(datetime('now')));

