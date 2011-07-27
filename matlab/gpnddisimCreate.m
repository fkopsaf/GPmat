function model = gpnddisimCreate(numGenes, numProteins, times, geneVals, ...
			       geneVars, options, annotation, paramtransformsettings)

% GPNDDISIMCREATE Create a GPNDDISIM model.
% The GPNDDISIM model is a model for estimating the protein
% concentration in a small gene network where one gene is
% governed by one protein (currently the code supports only one
% output gene, but the mathematics supports more than one). The
% model is based on Gaussian processes and simple linear
% differential equations of the form
%
% dx(t)/dt = B + S*f(t) - D*x(t)
%
% where x(t) is a given genes concentration and f(t) is the protein
% concentration. The protein concentration is modeled as the
% integral of a zero-mean RBF Gaussian process, which means that
% between observations, the protein concentration on average tends
% to stay close to the previous observed value (instead of falling
% towards some mean value).
%
% FORMAT
%
% DESC creates a model for input-output Gaussian processes where the
% input-output function is a differential equation, and the input
% is modeled as an integral of a zero-mean RBF Gaussian process.
%
% ARG numGenes : number of genes to be modelled in the system.
% Currently only 1 gene is supported by the code.
%
% ARG numProteins : number of proteins to be modelled in the
% system. Currently only 1 protein is supported by the code.
%
% ARG times : the time points where the data is to be modelled.
% Currently the code requires the observation time points to be
% the same for the input protein and the output gene.
%
% ARG geneVals : the values of each gene at the different time
% points. A matrix of size (numtimepoints x numGenes).
%
% ARG geneVars : the observation-noise variances of each gene at
% the different time points. A matrix of size (numtimepoints x
% numGenes). If this is set to a nonzero value, then the
% observation-noise variances are not modeled as a parameter within
% the model, instead the observation-noise variances for any
% observation point will be interpolated between the provided
% values.
%
% ARG options : options structure. The default options can be
% generated using gpnddisimOptions.
%
% ARG annotation : annotation for the data (gene names, etc.) that
% is stored with the model. (Optional)
%
% RETURN model : model structure containing default
% parameterisation.
%
% SEEALSO : modelCreate, gpnddisimOptions
%
% COPYRIGHT : Neil D. Lawrence, 2006
%
% COPYRIGHT : Antti Honkela, 2007
%
% COPYRIGHT : Jaakko Peltonen, 2011

% GPNDDISIM


fprintf(1,'nddisimCreate step1\n');

if any(size(geneVars)~=size(geneVals))
  error('The gene variances have a different size matrix to the gene values.');
end

if(numGenes ~= (size(geneVals, 2) - 1))
  error('The number of genes given does not match the dimension of the gene values given.')
end

if(size(times, 1) ~= size(geneVals, 1))
  error('The number of time points given does not match the number of gene values given')
end

model.type = 'gpnddisim';


% The kernel in the model is composed as K = K{1} + K{2}, 
% where K{1} is an "effect" kernel and K{2} is an
% "observation-noise" kernel. Furthermore, K{1} and K{2} are both
% 2x2 block-structured kernels: the top left block of K{1} is the
% effect-kernel of the input protein, and the bottom right block of
% K{1} is the effect-kernel of the output gene. Similarly, the top
% left block of K{2} is the observation-noise kernel of the input
% protein and the bottom right block of K{2} is the
% observation-noise kernel of the output gene. The off-diagonal
% blocks are the corresponding cross-kernel blocks which are
% automatically computed by the kernel functions.

kernType1{1} = 'multi';  % The effect-kernel K{1} is defined as a block kernel
kernType2{1} = 'multi';  % The noise-kernel K{2} is defined as a block kernel
kernType1{2} = 'ndsim';  % The top-left block of K{1} is a NDSIM kernel
for i = 1:numGenes
  kernType1{i+2} = 'nddisim'; % All other blocks of K{1} are NDDISIM kernels
end


% Tying together of parameters between the GP model of the input
% protein and the GP model of the output gene. The inverse width
% and SIM-level variance (responsiveness of the input protein to its
% RBF-GP derivative) must match between the NDSIM kernel (input
% protein) and NDSISIM kernel (output gene), so those parameters
% must be "tied together".
if numGenes > 0,
  tieParam = {'((\W|^)ndsim \d+ |nddisim \d+ di_)variance', 'inverse width'};
else
  tieParam = {};
end;


% Store the observed output values of the input protein and the
% output genes inside the model, as a single vector. The first
% entries of model.y will contain the values of the input protein,
% then the values of the first output gene, second output gene, and
% so on.
model.y = geneVals(:);


% Due to historical reasons a 'model.yvar' field for
% observation-noise variances is kept here. However, we do not use
% it for anything, and set it to zero to make sure it does not
% affect computation. Instead, any provided fixed observation-noise
% variances will be inserted directly into the RNA white-noise kernel!
model.yvar = 0*geneVals(:);



% Check if we should create an observation-noise term.
model.includeNoise = options.includeNoise;
if model.includeNoise
  % Create a new multi kernel to contain the observation-noise terms.
  kernType2{1} = 'multi';

  % Set the new multi kernel to just contain 'white' kernels.
  for i = 1:numGenes+1
    % Provide the 'use_sigmoidab' option to the white-noise kernels so the
    % allowed range of the white noise parameter can be customized.
    % kernType2{i+1} = 'white';
    kernType2{i+1} = {'parametric', struct('use_sigmoidab', {1}), 'white'};
  end
  
  % If desired, tie the observation-noise variance parameters
  % together so that the input protein and all output genes have
  % the same observation-noise variance. May not be realistic: it
  % would be better to tie together only the observation-noise
  % variances for output genes, and model observation-noise
  % variance of the input protein separately, but the current code
  % does not support that.  
  if isfield(options, 'singleNoise') && options.singleNoise
    tieParam{5} = 'white . variance';
  end
  
  % Now create model with a 'cmpnd' (compound) kernel build from two
  % multi-kernels. The first multi-kernel is the sim-sim one the next
  % multi-kernel is the white-white one. 
  model.kern = kernCreate(times, {'cmpnd', kernType1, kernType2});
  simMultiKernName = 'model.kern.comp{1}';
else
  model.kern = kernCreate(times, kernType1);
  simMultiKernName = 'model.kern';
end
simMultiKern = eval(simMultiKernName);



% This is if we need to place priors on parameters ...
% Currently the model has not been tested with priors so this part
% of the code is just copied from earlier gpdisim code, and it may
% not work properly.
if isfield(options, 'addPriors') && options.addPriors,
  for i = 1:length(simMultiKern.numBlocks)
    % Priors on the sim kernels.
    eval([simMultiKernName '.comp{i}.priors = priorCreate(''gamma'');']);
    eval([simMultiKernName '.comp{i}.priors.a = 1;']);
    eval([simMultiKernName '.comp{i}.priors.b = 1;']);
    %model.kern.comp{i}.priors = priorCreate('gamma');
    %model.kern.comp{i}.priors.a = 1;
    %model.kern.comp{i}.priors.b = 1;
    if i == 1
      % For the SIM kernel place prior on inverse width.
      % model.kern.comp{i}.priors.index = [1 2];
      eval([simMultiKernName '.comp{i}.priors.index = [1 2];']);
    elseif i == 2
      % for the first DISIM kernel, place prior on ...
      %model.kern.comp{i}.priors.index = [1 3 4 5];
      eval([simMultiKernName '.comp{i}.priors.index = [1 3 4 5];']);
    else
      % For other DISIM kernels don't place prior on inverse width --- as
      % they are all tied together and it will be counted multiple
      % times.
      %model.kern.comp{i}.priors.index = [4 5];
      eval([simMultiKernName '.comp{i}.priors.index = [4 5];']);
    end
  end

  % Prior on the b values.
  model.bprior = priorCreate('gamma');
  model.bprior.a = 1;
  model.bprior.b = 1;
end



% Get the parameters from the kernel... this may be unnecessary at
% this point???
[pars,nams]=kernExtractParam(model.kern);
%pars
%nams
%pause



% Tie together the parameters according to the regular expression
% "tieParam" created earlier in the current function.
model.kern = modelTieParam(model.kern, tieParam);



% I think this part may be unnecessary - it is mainly to make sure
% that the initial variances of the noise kernels are in the
% allowed range of parameter values.
if model.includeNoise,
  % variances of the noise kernels
  for i = 1:numGenes+1,
    model.kern.comp{2}.comp{i}.variance = 1e-2;
  end
end



% The differential equation parameters between the input protein
% and output genes (decays and sensitivities and time delays) are
% actually stored in the kernel. We'll put them here as well for
% convenience.
% model.delta = 10;
model.sigma = 1;
tempdelay = 20;
if numGenes > 0,
  for i = 2:simMultiKern.numBlocks
    eval([simMultiKernName '.comp{i}.di_variance = model.sigma^2;']);
    eval([simMultiKernName '.comp{i}.delay = tempdelay;']);
    eval(['model.D(i-1) = ' simMultiKernName '.comp{i}.decay;']);
    eval(['model.S(i-1) = sqrt(' simMultiKernName '.comp{i}.variance);']);
    eval(['model.delay(i-1) = ' simMultiKernName '.comp{i}.delay;']);
  end
end;



% Whether to use, for each gene, an initial RNA concentration that
% decays away. The need for an initial concentration comes from
% assuming a free parameter as the initial condition of the
% differential equation. If this is not used, it is assumed that
% the initial concentration is the basal rate of the gene divided
% by the decay of the gene (B/D) - this is the only initial
% condition where an independent parameter is not needed. Please
% note that if a separate initial concentration is not used, this
% also affects the gradients of B and D since they then affect the
% initial concentration too.
%
% Warning: the version of the code where an initial RNA
% concentration is not used is older than the rest, and has not
% been tested recently - it may not be up to date.

if isfield(options, 'use_disimstartmean')
  use_disimstartmean=options.use_disimstartmean;
else 
  use_disimstartmean=0; 
end;
  
if (use_disimstartmean==1),
  num_disimstartmeans=numGenes;
  for k=1:numGenes,
    model.disimStartMean(k)=geneVals(1, k+1);
  end;
  % Use a scaled sigmoid transformation for the "initial RNA
  % concentration" parameters (disimStartMean), so that
  % their allowed range can be customized.
  model.disimStartMeanTransform = 'sigmoidab';
else
  num_disimstartmeans=0;
end;
model.use_disimstartmean=use_disimstartmean;



% Basal rates of mRNA production for the output genes. Here they
% are initialized simply so that B/D corresponds to the final value
% of the output-gene time series.
num_basalrates=numGenes;
% model.B = model.D.*model.mu;
if numGenes > 0,
  model.B = model.D.*geneVals(1, 2:end);
end;
% The basal transcriptions rates must be postitive. Use a scaled
% sigmoid transformation for them so that the allowed range of the
% basal transcription rates can be customized.
model.bTransform = 'sigmoidab';



% Mean value parameter for the input protein. The protein is
% assumed to be an integral of an RBF Gaussian process, plus a
% constant mean value. Note that since the integral at t=0 is just
% zero, the value of the input protein at t=0 is modeled simply as
% the mean parameter plus any observation noise.
num_simmeans=1;
model.simMean = 0;
% The mean of the input protein should be positive. Use a scaled
% sigmoid transformation for them so that the allowed range of the
% input protein mean can be customized.
model.simMeanTransform = 'sigmoidab';



% Compute the total number of parameters: parameters from the
% kernel, basal rates, initial RNA concentrations, and input
% protein means.
model.numParams = model.kern.nParams + num_basalrates + num_disimstartmeans + num_simmeans;



% Store the number of output genes
model.numGenes = numGenes;



% Store the locations (observation times) of inputs/outputs.
model.t = times;



% Initialize the mean vector of the model, according to the results
% of the differential equation. Note that the mean is
% time-dependent. The mean is affected by two time-based effects:
% as time passes the initial concentration of RNA decays away and
% the basal rate kicks in to establish the final expected amount of
% RNA, which depends on the basal rate and decay rate.
mu = zeros(size(model.y));
nt=size(model.t,1);
mu(1:nt)=model.simMean;
tempind1=nt+1;
for k=1:numGenes,
  if (use_disimstartmean==1),
    mu(tempind1:tempind1+nt-1)=(model.B(k)+model.simMean*model.S(k))/model.D(k)+ ...
	(model.disimStartMean(k)-(model.B(k)+model.simMean*model.S(k))/model.D(k))*exp(model.D(k)*(-model.t));
  else
    mu(tempnd1:tempind1+nt-1)=(model.B(k)+model.simMean*model.S(k))/model.D(k);
  end;  
  tempind1=tempind1+nt;
end;
model.mu = mu;



% Difference between the observations and the expectation (mean),
% used to compute the likelihood of the model.
model.m = model.y-model.mu;



% If it is desired to use fixed observation-noise variances for the
% output genes instead of modeling them as a free parameter, then
% for predicting variances of the observations at new points, we
% must be able to compute the observation-noise variance at any
% time. To do so, we insert the known variances into the
% observation-noise kernel (white-noise kernel), and ask it to
% interpolate the variances for us.
if isfield(options,'use_fixedrnavariance'),  
  % As a final check we require that at least one of the fixed
  % variances is nonzero.
  if (options.use_fixedrnavariance==1) && (sum(sum(geneVars(:,2:end)))>0),
    model.use_fixedrnavar=1;
    % force the RNA observation variance kernels to use fixed
    % variance values, and provide the variance values to the kernels.
    for k=1:numGenes,
      model.kern.comp{2}.comp{k+1}.use_fixedvariance=1;
      % model.kern.comp{2}.comp{k+1}.fixedvariance=model.yvar(k*nt+1:(k+1)*nt);
      model.kern.comp{2}.comp{k+1}.fixedvariance=geneVars(:,k+1);
      model.kern.comp{2}.comp{k+1}.fixedvariance_times=model.t;
    end;
  else
    model.use_fixedrnavar=0;
  end;
else
  model.use_fixedrnavar=0;  
end;



% Store the desired optimization algorithm, such as 'conjgrad',
% 'scg', or 'quasinew'.
model.optimiser = options.optimiser;



% If any parameters should be kept at fixed values, store those constraints.
if isfield(options, 'fix')
  model.fix = options.fix;
end



% Store any provided annotation within the model
if nargin > 6,
  model.annotation = annotation;
end



% Store any provided options within the model
model.options = options;



% fprintf(1,'Force kernel compute 1\n');
% paramtransformsettings

% Store the desired parameter transformation settings (such as
% desired parameter ranges) within the model and the kernel structures.
model=gpnddisimExpandParamTransformSettings(model, paramtransformsettings);

fprintf(1,'Force kernel compute 1a\n');


% Extract the parameters and their names. We need the names to find
% out which of the tied-together parameters are parameters that
% affect both the kernel and the mean function. 
[params,paramnames] = gpnddisimExtractParam(model);
%params
%paramnames

fprintf(1,'Force kernel compute 1 done\n');



% Find and store indices and transformation settings related to
% DISIM decay. This is necessary because the decay affects both the
% kernel and the mean function.
disimdecayindices=nan*ones(numGenes,1);
for disimindex=1:numGenes,
  for l=1:length(paramnames),
    tempindex=strfind(paramnames{l},sprintf('disim %d decay', disimindex));
    if length(tempindex)>0,
      disimdecayindices(disimindex)=l;
    end;    
  end;
end;
model.disimdecayindices=disimdecayindices;

if ~isempty(model.disimdecayindices),
  % find and store transformation settings related to DISIM
  % decay. Assumes model.disimdecayindices has already been created.
  disimdecaytransformationsettings=cell(model.numGenes,1);
  for disimindex=1:model.numGenes,
    disimdecaytransformationsettings{disimindex}=...
        paramtransformsettings{model.disimdecayindices(disimindex)};
  end;
  model.disimdecaytransformationsettings=disimdecaytransformationsettings;
end;



% Find and store indices and transformation settings related to
% DISIM variance. This is necessary because the variance affects
% both the kernel and the mean function (it affects the mean
% function of the RNA because it determines how much the mean of
% the input-protein affects the RNA).
disimvarianceindices=nan*ones(numGenes,1);
for disimindex=1:numGenes,
  for l=1:length(paramnames),
    tempindex=strfind(paramnames{l},sprintf('disim %d variance', disimindex));
    if length(tempindex)>0,
      disimvarianceindices(disimindex)=l;
    end;    
  end;
end;
model.disimvarianceindices=disimvarianceindices;

if ~isempty(model.disimvarianceindices),
  % find and store transformation settings related to DISIM
  % variance. Assumes model.disimvarianceindices has already been created.
  disimvariancetransformationsettings=cell(model.numGenes,1);
  for disimindex=1:model.numGenes,
    disimvariancetransformationsettings{disimindex}=...
        paramtransformsettings{model.disimvarianceindices(disimindex)};
  end;
  model.disimvariancetransformationsettings=disimvariancetransformationsettings;
end;



% Find and store indices and transformation settings related to
% DISIM delay. This is necessary because the delay affects
% both the kernel and the mean function.
disimdelayindices=nan*ones(numGenes,1);
for disimindex=1:numGenes,
  for l=1:length(paramnames),
    tempindex=strfind(paramnames{l},sprintf('disim %d delay', disimindex));
    if length(tempindex)>0,
      disimdelayindices(disimindex)=l;
    end;    
  end;
end;
model.disimdelayindices=disimdelayindices;

if ~isempty(model.disimdelayindices),
  % find and store transformation settings related to DISIM
  % delay. Assumes model.disimdelayindices has already been created.
  disimdelaytransformationsettings=cell(model.numGenes,1);
  for disimindex=1:model.numGenes,
    disimdelaytransformationsettings{disimindex}=...
        paramtransformsettings{model.disimdelayindices(disimindex)};
  end;
  model.disimdelaytransformationsettings=disimdelaytransformationsettings;
end;




% Now that the transformation settings have been updated into the
% model and the kernel structure, and the necessary parameter
% indices have been found, we can finally update the parameters
% back into the model - this will cause the kernel to be computed
% and the mean to be computed.
fprintf(1,'gpasimTemp3Create step2\n');
fprintf(1,'Force kernel compute 2\n');
model = gpnddisimExpandParam(model, params);
fprintf(1,'gpasimTemp3Create step3\n');


fprintf(1,'gpnddisimCreate done\n');
