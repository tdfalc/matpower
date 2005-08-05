function [buso, gen, branch, f, success, info, et, g, jac] = opf(baseMVA, bus,...
          gen, branch, areas, gencost, Au, lbu, ubu, mpopt)
%OPF  Solves an optimal power flow.
%
%   For an AC OPF, if the OPF algorithm is not set explicitly in the options,
%   it will choose the best available solver, searching in the following order:
%   MINOPF, fmincon, constr.
%
%   [bus, gen, branch, f, success] = opf(casefile, mpopt)
%
%   [bus, gen, branch, f, success] = opf(casefile, A, l, u, mpopt)
%
%   [bus, gen, branch, f, success] = opf(baseMVA, bus, gen, branch, areas, ...
%                                    gencost, mpopt)
%
%   [bus, gen, branch, f, success] = opf(baseMVA, bus, gen, branch, areas, ...
%                                    gencost, A, l, u, mpopt)
%
%   [bus, gen, branch, f, success, info, et, g, jac] = opf(casefile)
%
%   The data for the problem can be specified in one of 3 ways: (1) the name of
%   a case file which defines the data matrices baseMVA, bus, gen, branch,
%   areas and gencost, (2) a struct containing the data matrices as fields, or
%   (3) the data matrices themselves.
%
%   When specified, A, l, u represent additional linear constraints on the
%   optimization variables, l <= A*x <= u. These are only available for solvers
%   which use the generalized formulation, namely fmincon and MINOPF. For an
%   explanation of the formulation used and instructions for forming the A
%   matrix, type 'help genform'.
%
%   The optional mpopt vector specifies MATPOWER options. Type 'help mpoption'
%   for details and default values.
%
%   The solved case is returned in the data matrices, bus, gen and branch. Also,
%   returned are the final objective function value (f) and a flag which is
%   true if the algorithm was successful in finding a solution (success).
%   Additional optional return values are an algorithm specific return status
%   (info), elapsed time in seconds (et), the constraint vector (g) and the
%   Jacobian matrix (jac).

%   MATPOWER
%   $Id$
%   by Ray Zimmerman, PSERC Cornell
%   and Carlos E. Murillo-Sanchez, PSERC Cornell & Universidad Autonoma de Manizales
%   Copyright (c) 1996-2005 by Power System Engineering Research Center (PSERC)
%   See http://www.pserc.cornell.edu/matpower/ for more info.


% Sort out args
if isstr(baseMVA) | isstruct(baseMVA)
  casefile = baseMVA;
  if nargin == 5
    Au = bus;
    lbu = gen;
    ubu = branch;
    mpopt = areas;
  elseif nargin == 4
    Au = bus;
    lbu = gen;
    ubu = branch;
    mpopt = mpoption;
  elseif nargin == 2
    Au = sparse(0,0);
    lbu = [];
    ubu = [];
    mpopt = bus;
  elseif nargin == 1
    Au = sparse(0,0);
    lbu = [];
    ubu = [];
    mpopt = mpoption;
  else
    error('opf.m: Incorrect input parameter order, number or type');
  end;
  [baseMVA, bus, gen, branch, areas, gencost] = loadcase(casefile);
else
  if nargin == 9
    mpopt = mpoption;
  elseif nargin == 7
    mpopt = Au;
    Au = sparse(0,0);
    lbu = [];
    ubu = [];
  elseif nargin == 6
    mpopt = mpoption;
    Au = sparse(0,0);
    lbu = [];
    ubu = [];
  elseif nargin ~= 10
    error('opf.m: Incorrect input parameter order, number or type');
  end
end

%%----- initialization -----
%% options
verbose = mpopt(31);
npts = mpopt(14);       %% number of points to evaluate when converting
                        %% polynomials to piece-wise linear

%% define constants
j = sqrt(-1);

%% define named indices into data matrices
[PQ, PV, REF, NONE, BUS_I, BUS_TYPE, PD, QD, GS, BS, BUS_AREA, VM, ...
    VA, BASE_KV, ZONE, VMAX, VMIN, LAM_P, LAM_Q, MU_VMAX, MU_VMIN] = idx_bus;
[GEN_BUS, PG, QG, QMAX, QMIN, VG, MBASE, GEN_STATUS, ...
    PMAX, PMIN, MU_PMAX, MU_PMIN, MU_QMAX, MU_QMIN, QMAX2, QMIN2, ...
    RAMP_AGC, RAMP_10, RAMP_30, RAMP_Q, APF] = idx_gen;
[PW_LINEAR, POLYNOMIAL, MODEL, STARTUP, SHUTDOWN, N, COST] = idx_cost;

%%-----  check/convert costs, set default algorithm  -----
%% get cost model, check consistency
model = gencost(:, MODEL);
comgen = find(gen(:, GEN_STATUS) > 0);
if size(gencost, 1) == 2*size(gen,1)
  comgen = [comgen; comgen];
end
i_pwln = find(model(comgen) == PW_LINEAR);
i_poly = find(model(comgen) == POLYNOMIAL);

% Start clock
t1 = clock;

%% set algorithm
dc = mpopt(10);
if dc % DC OPF
  [bus, gen, branch, f, success, info, et] = dcopf(baseMVA, bus, gen, ...
                                            branch, areas, gencost, mpopt);
  g = []; jac = [];     %% not currently available from DC OPF
else % AC optimal power flow requested
  if any(model ~= PW_LINEAR & model ~= POLYNOMIAL)
    error('opf.m: unknown generator cost model in gencost data');
  end
  if mpopt(11) == 0  % OPF_ALG not set, choose best option
    if have_fcn('minopf')
      mpopt(11) = 500; % MINOS generalized
    elseif have_fcn('fmincon')
      mpopt(11) = 520; % FMINCON generalized
    %% use default for this cost model
    elseif any(i_pwln)      %% some piece-wise linear, use appropriate alg
      mpopt(11) = mpopt(13);
      if any(i_poly) & verbose
        fprintf('opf.m: not all generators use same cost model, all will be converted\n       to piece-wise linear\n');
      end
    else                    %% must all be polynomial
        mpopt(11) = mpopt(12);
    end
  end
  alg = mpopt(11);
  formulation = opf_form(alg); % 1, 2 or 5

  %% check cost model/algorithm consistency
  if any( i_pwln ) & formulation == 1
    error(sprintf('opf.m: algorithm %d does not handle piece-wise linear cost functions', alg));
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %%  Eventually put code here to fit polynomials to piece-wise linear as needed.
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
  end

  if (formulation ~= 5) & ~isempty(Au)
    error('opf.m: Selected algorithm cannot handle general linear constraints');
  end
  
  %% convert polynomials to piece-wise linear
  if any(i_poly)  & formulation == 2
    if verbose
        fprintf('converting from polynomial to piece-wise linear cost model\n');
    end
    [pcost, qcost] = pqcost(gencost, size(gen, 1));
    i_poly = find(pcost(:, MODEL) == POLYNOMIAL);
    tmp = poly2pwl(pcost(i_poly, :), gen(i_poly, PMIN), gen(i_poly, PMAX), npts);
    pcost(i_poly, 1:size(tmp,2)) = tmp;
    if ~isempty(qcost)
        i_poly = find(qcost(:, MODEL) == POLYNOMIAL);
        tmp = poly2pwl(qcost(i_poly, :), gen(i_poly, QMIN), gen(i_poly, QMAX), npts);
        qcost(i_poly, 1:size(tmp,2)) = tmp;
    end
    gencost = [pcost; qcost];
  end

  %%-----  run opf  -----
  if formulation == 5 % Generalized
    if alg == 500       % MINOS
      if ~have_fcn('minopf')
        error(['opf.m: OPF_ALG ', num2str(alg), ' requires ', ...
            'MINOPF (see http://www.pserc.cornell.edu/minopf/)']);
      end
      [bus, gen, branch, f, success, info, et, g, jac] = mopf(baseMVA, ...
          bus, gen, branch, areas, gencost, Au, lbu, ubu, mpopt);
    elseif alg == 520   % FMINCON
      if ~have_fcn('fmincon')
        error(['opf.m: OPF_ALG ', num2str(alg), ' requires ', ...
            'fmincon (Optimization Toolbox 2.x or later)']);
      end
      [bus, gen, branch, f, success, info, et, g, jac] = fmincopf(baseMVA, ...
          bus, gen, branch, areas, gencost, Au, lbu, ubu, mpopt);
    end
  else
    if opf_slvr(alg) == 0           %% use CONSTR
      if ~have_fcn('constr')
        error(['opf.m: OPF_ALG ', num2str(alg), ' requires ', ...
            'constr (Optimization Toolbox 1.x/2.x)']);
      end
      %% set some options
      if mpopt(19) == 0
        mpopt(19) = 2 * size(bus,1) + 150;  %% set max number of iterations for constr
      end
   
      %% run optimization
      [bus, gen, branch, f, success, info, et, g, jac] = copf(baseMVA, ...
              bus, gen, branch, areas, gencost, mpopt);
  
    else                            %% use LPCONSTR
      [bus, gen, branch, f, success, info, et, g, jac] = lpopf(baseMVA, ...
              bus, gen ,branch, areas, gencost, mpopt);
    end
  end
end
    
%% compute elapsed time
et = etime(clock, t1);
if (nargout == 0) & ( success )
  printpf(baseMVA, bus, gen, branch, f, success, et, 1, mpopt);
end

if nargout
  buso = bus;
end

return;
