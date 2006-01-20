function model = fgplvmExpandParam(model, params)

% FGPLVMEXPANDPARAM Expand a parameter vector into a GP-LVM model.

% FGPLVM

startVal = 1;
if isfield(model, 'back')
  endVal = model.back.numParams;
  model.back = modelExpandParam(model.back, params(startVal:endVal));
  model.X = modelOut(model.back, model.y);
else
  endVal = model.N*model.q;
  model.X = reshape(params(startVal:endVal), model.N, model.q);
end
startVal = endVal+1;
endVal = endVal + model.k*model.q + model.kern.nParams;

switch model.approx
 case 'ftc'
  endVal = endVal;
 case {'dtc', 'fitc', 'pitc'}
  endVal = endVal + 1; % account for beta attached to the end.
 otherwise
  error('Unknown approximation type.')
end
if model.learnScales
  endVal = endVal + model.d;
end
model = gpExpandParam(model, params(startVal:endVal));


% Give parameters to dynamics if they are there.
if isfield(model, 'dynamics') & ~isempty(model.dynamics)
  startVal = endVal + 1;
  endVal = length(params);

  % Fill the dynamics model with current latent values.
  model.dynamics = modelSetLatentValues(model.dynamics, model.X);

  % Update the dynamics model with parameters (thereby forcing recompute).
  model.dynamics = modelExpandParam(model.dynamics, params(startVal:endVal));
end

