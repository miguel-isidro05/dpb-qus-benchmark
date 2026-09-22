function record = mi_m_verify_bmode(output_root)
%MI_M_VERIFY_BMODE Pruebas, cobertura de sentencias y análisis estático.
% Ejecutar desde cualquier carpeta con pipelines/bmode en path.
root=fileparts(fileparts(fileparts(mfilename('fullpath'))));
if nargin<1, output_root=fullfile(root,'results','bmode_verification'); end
if ~isfolder(output_root), mkdir(output_root); end
report_dir=tempname(output_root); mkdir(report_dir);
suite=testsuite(fullfile(root,'tests','bmode'));
runner=matlab.unittest.TestRunner.withTextOutput;
coverage_file=fullfile(report_dir,'coverage.xml');
coverage=matlab.unittest.plugins.codecoverage.CoberturaFormat(coverage_file);
plugin=matlab.unittest.plugins.CodeCoveragePlugin.forFolder(fileparts(mfilename('fullpath')), ...
    'Producing',coverage);
runner.addPlugin(plugin);
results=runner.run(suite);
files=dir(fullfile(root,'pipelines','bmode','*.m'));
analysis=struct('file',{},'issues',{});
for k=1:numel(files)
    analysis(k).file=files(k).name;
    analysis(k).issues=checkcode(fullfile(files(k).folder,files(k).name),'-id');
end
record=struct('report_dir',report_dir,'matlab_version',version, ...
    'tests_passed',sum([results.Passed]),'tests_failed',sum([results.Failed]), ...
    'tests_incomplete',sum([results.Incomplete]),'static_analysis',analysis);
save(fullfile(report_dir,'verification.mat'),'record','results');
fprintf('Verificación: %s\n',report_dir);
assertSuccess(results);
end
