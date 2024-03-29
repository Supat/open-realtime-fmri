function ft_realtime_dicomroxy(cfg)
% FT_REALTIME_DICOMPROXY simulates an fMRI acquisition system by reading a series
% of DICOM files from disk, and streaming them to a FieldTrip buffer.
%
% Use as
%   ft_realtime_dicomproxy(cfg)
%
% The target to write the data to is configured as
%   cfg.target.datafile      = string, target destination for the data (default = 'buffer://localhost:1972')
%   cfg.input                = string or cell array of strings (see below)
%   cfg.speedup              = optional speedup parameter
%
% The input files can be specified as a cell array of filenames,
% or as a single string with a wildcard, e.g., '/myhome/scan*.ima'
%
% This function requires functions from SPM, so make sure you have set up your path correctly.

% Copyright (C) 2010, Stefan Klanke

% set the defaults
if isempty(cfg) | ~isfield(cfg, 'target') | ~isfield(cfg.target, 'datafile')
  cfg.target.datafile = 'buffer://localhost:1972';  
end
cfg.target.dataformat = [];    

if ~isfield(cfg, 'speedup')
  cfg.speedup = 1;
end

if iscell(cfg.input)
  fullnames = cfg.input;
  N = numel(fullnames);
elseif size(cfg.input,1) == 1
  [basedir, name, ext] = fileparts(cfg.input);
  D = dir(cfg.input);
  N = numel(D);
  
  fullnames = cell(N,1);
  for k=1:N
    fullnames{k} = [basedir filesep D(k).name];
  end
else
  error('Don''t know what to do with cfg.input');  
end

DN = tempname; % Dicom Name

stopWatch = tic;
for n=1:N
  copyfile(fullnames{n}, DN);
  dh = spm_dicom_headers(DN);
  R = spm_dicom_convert(dh,'all','flat','nii');
  NN = R.files{1};  % NIFTI name
  
  V = spm_vol(NN);
  Y = int16(spm_read_vols(V));
  
  if n==1
    TR = dh{1}.RepetitionTime * 0.001;
    NH = spm_vol_nifti(NN); % NIFTI header
    
    f = fopen(R.files{1},'r');
    rawNifti = fread(f, 348, 'uint8=>uint8');
    fclose(f);
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % create a fieldtrip compatible header structure
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    hdr = [];
    hdr.nChans = prod(NH.dim);
    hdr.nSamples = 0;
    hdr.Fs = 1/TR;
    hdr.nSamplesPre        = 0;
    hdr.nTrials            = 1;                           
    hdr.nifti_1 = rawNifti;
    
    ft_write_data(cfg.target.datafile, Y(:), 'header', hdr, 'dataformat', cfg.target.dataformat, 'append', false);
  else
    ft_write_data(cfg.target.datafile, Y(:), 'header', hdr, 'dataformat', cfg.target.dataformat, 'append', true);
  end
  fprintf(1,'Wrote scan %i of %i at time t=%f\n', n, N, toc(stopWatch));

  delete(DN);
  delete(NN);
  
  pause(n*TR/cfg.speedup - toc(stopWatch));
end

