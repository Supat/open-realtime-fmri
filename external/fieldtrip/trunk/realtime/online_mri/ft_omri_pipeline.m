function ft_omri_pipeline(cfg)
% function ft_omri_pipeline(cfg)
%
% fMRI pre-processing pipeline
% Make sure you have SPM8 on your path.
%
% Configuration options are
%  cfg.input      - FieldTrip buffer containing raw scans (default 'buffer://localhost:1972')
%  cfg.output     - where to write processed scans to     (default 'buffer://localhost:1973')
%  cfg.numDummy   - how many scans to ignore initially    (default 0)
%  cfg.smoothFWHM - kernel width in mm (Full Width Half Maximum) for smoothing (default = 0 => no smoothing)
%  cfg.correctMotion 	- flag indicating whether to correct motion artifacts (default = 1 = yes)
%  cfg.correctSliceTime - flag indicating whether to correct slice timing (default = 1 = yes)
%
% (C) 2010 Stefan Klanke


%ft_defaults
%addpath('/home/common/matlab/spm8');

if nargin < 1
	cfg = [];
end

if ~isfield(cfg, 'input')
	cfg.input = 'buffer://localhost:1972';
end

if ~isfield(cfg, 'output')
	cfg.output = 'buffer://localhost:1973';
end

if ~isfield(cfg, 'numDummy')
	cfg.numDummy = 0;			% number of dummy scans to drop
end

if ~isfield(cfg, 'smoothFWHM')
	cfg.smoothFWHM = 0;
end

if ~isfield(cfg, 'correctMotion')
	cfg.correctMotion = 1;
end

if ~isfield(cfg, 'correctSliceTime')
	cfg.correctSliceTime = 1;
end

if ~isfield(cfg, 'whichEcho')
	cfg.whichEcho = 1;
else
	if cfg.whichEcho < 1
		error '"whichEcho" configuration field must be >= 1';
	end
end

% prepare "ready" event data structure
evr = [];
evr.type = 'scan';
evr.value = 'ready';
evr.offset = 0;
evr.duration = 0;
evr.sample = 0;

history = struct('S',[], 'RRM', [], 'motion', []);

numTrial = 0;

% Loop this forever (until user cancels)
while 1
	clear ft_read_header
	% start by reading the header from the realtime buffer
	while 1
		try
			hdr = ft_read_header(cfg.input);
			break;
		catch 
			disp(lasterror);
			disp('Waiting for header');
			pause(0.5);
		end
	end
	
	% Ok, we got the header, try to make sense out of it
	S = ft_omri_info_from_header(hdr);
	if isempty(S)
		warning('No protocol information found!')
		% restart loop
		pause(0.5);
		continue;
	end
		
	if cfg.whichEcho > S.numEchos
		warning('Selected echo number exceeds the number of echos in the protocol.');
		grabEcho = S.numEchos;
		fprintf(1,'Will grab echo #%i of %i\n', grabEcho, S.numEchos);
	else
		grabEcho = 1;
	end
		
	% Prepare smoothing kernels based on configuration and voxel size
	if cfg.smoothFWHM > 0
		[smKernX, smKernY, smKernZ, smOff] = ft_omri_smoothing_kernel(cfg.smoothFWHM, S.voxdim);
		smKern = convn(smKernX'*smKernY, reshape(smKernZ, 1, 1, length(smKernZ)));
	else
		smKernX = [];
		smKernY = [];
		smKernZ = [];
		smKern  = [];
		smOff   = [0 0 0];
	end   
	
	niftiOut = [];
	niftiOut.dim = S.voxels;
	niftiOut.pixdim = S.voxdim;
	niftiOut.slice_duration = S.TR / S.vz;
	niftiOut.srow_x = S.mat0(1,:);
	niftiOut.srow_y = S.mat0(2,:);
	niftiOut.srow_z = S.mat0(3,:);
	
	hdrOut = [];
	hdrOut.nSamples = 0;
	hdrOut.Fs = hdr.Fs;
	if cfg.correctMotion
		hdrOut.nChans = prod(S.voxels) + 6;
	else
		hdrOut.nChans = prod(S.voxels);
	end
	hdrOut.nifti_1 = niftiOut; %encode_nifti1(niftiOut);
	
	ft_write_data(cfg.output, single([]), 'header', hdrOut);
	
	% reset motion estimates
	motEst = [];
	
	% store current info structure in history
	numTrial  = numTrial + 1;
	history(numTrial).S = S;
	disp(S)

	% Wait for numDummy scans (and drop them)
	fprintf(1,'Waiting for %i dummy samples to come in...\n', cfg.numDummy);
	while 1
		threshold = struct('nsamples', cfg.numDummy * S.numEchos);
		newNum = ft_poll_buffer(cfg.input, threshold, 500);
		if newNum.nsamples >= cfg.numDummy*S.numEchos
		   break
		end
		pause(0.01);
	end

	fprintf(1,'Starting to process\n');
	numTotal  = cfg.numDummy * S.numEchos;
	numProper = 0;
		
	% Loop this as long as the experiment runs with the same protocol (= data keeps coming in)
	while 1
		% determine number of samples available in buffer / wait for more than numTotal
		threshold.nsamples = numTotal + S.numEchos - 1;
		newNum = ft_poll_buffer(cfg.input, threshold, 500);
		
		if newNum.nsamples < numTotal
			% scanning seems to have stopped - re-read header to continue with next trial
			break;
		end
		if newNum.nsamples < numTotal + S.numEchos
			% timeout -- go back to start of (inner) loop
		    continue;
		end
		
		% this is necessary for ft_read_data
		hdr.nSamples = newNum.nsamples;
		
		index = (cfg.numDummy + numProper) * S.numEchos + grabEcho;
		fprintf('\nTrying to read %i. proper scan at sample index %d\n', numProper+1, index);
		GrabSampleT = tic;
		
		try
			% read data from buffer (only the last scan)
			dat = ft_read_data(cfg.input, 'header', hdr, 'begsample', index, 'endsample', index);
		catch
			warning('Problems reading data - going back to poll operation...');
			continue;
		end
		
		numProper = numProper + 1;
		numTotal  = numTotal + S.numEchos;
		
		rawScan = single(reshape(dat, S.voxels));
		
		%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
		% motion correction
		%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
		if cfg.correctMotion
			doneHere = 0;
			if numProper == 1
				RRM = [];
				for i=1:length(history)
					if isequal(history(i).S, S)
						fprintf(1,'Will realign scans to reference model from trial %i...\n', i);
						% protocol the same => re-use realignment reference
						RRM = history(i).RRM;
						break;
					end
				end
			
				% none found - setup new one 
				if isempty(RRM)
					flags = struct('mat', S.mat0);
					fprintf(1,'Setting up first num-dummy scan as reference volume...\n');
					RRM = ft_omri_align_init(rawScan, flags);
					history(numTrial).RRM = RRM;
					curSixDof = zeros(1,6);
					motEst = zeros(1,6);
					procScan = single(rawScan);
					doneHere = 1;
				end
			end
			
			if ~doneHere
				fprintf('%-30s','Registration...');
				tic; 
				[RRM, M, Mabs, procScan] = ft_omri_align_scan(RRM, rawScan); 
				toc
				curSixDof = hom2six(M);
				motEst = [motEst; curSixDof.*[1 1 1 180/pi 180/pi 180/pi]];
			end
		else
			procScan = single(rawScan);
			motEst = [motEst; zeros(1,6)];
		end
		
		%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
		% slice timing correction
		%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%		
		if cfg.correctSliceTime
			if numProper == 1
				fprintf(1,'Initialising slice-time correction model...\n');
				STM = ft_omri_slice_time_init(procScan, S.TR, S.deltaT);
			else
				fprintf('%-30s','Slice time correction...');
				tic; 
				[STM, procScan] = ft_omri_slice_time_apply(STM, procScan); 
				toc
			end
		end

		%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
		% smoothing 
		%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%		
		if cfg.smoothFWHM > 0
			fprintf('%-30s','Smoothing...');
			tic;
			% MATLAB convolution
			%Vsm = convn(procScan,smKern); 
			%procScan = Vsm((1+smOff(1)):(end-smOff(1)), (1+smOff(2)):(end-smOff(2)), (1+smOff(3)):(end-smOff(3)));
			
			% specialised MEX file
			procScan = ft_omri_smooth_volume(single(procScan), smKernX, smKernY, smKernZ);
			
			toc
		end
		%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
		% done with pre-processing, write output
		%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%		
		
		if cfg.correctMotion
			procSample = [single(procScan(:)) ; single(curSixDof')];
		else
			procSample = single(procScan(:));
		end
		
		ft_write_data(cfg.output, procSample, 'header', hdrOut, 'append', true);
		
		%evr.sample = numProper;
		%ft_write_event(cfg.output, evr);
		
		fprintf('Done -- total time = %f\n', toc(GrabSampleT));

		subplot(4,1,1);
		plot(motEst(:,1:3));  
		subplot(4,1,2);
		plot(motEst(:,4:6));  

		subplot(4,1,3);
		slcImg = reshape(dat, [S.vx	S.vy*S.vz]);
		imagesc(slcImg);
		colormap(gray);

		subplot(4,1,4);
		slcImg = reshape(procScan, [S.vx	S.vy*S.vz]);
		imagesc(slcImg);
		colormap(gray);

		% force Matlab to update the figure
		drawnow
	end % while true	
end	
