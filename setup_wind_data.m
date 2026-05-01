fname  = '/Users/efimlunev/Desktop/final_project/onshore_5min_24to25of12_test.csv';
dt_sim = 10;   % s
dt = dt_sim;
% Read with original headers preserved; read DATETIME as text first
opts = detectImportOptions(fname, 'VariableNamingRule','preserve');
opts = setvaropts(opts, 'Report Date / Time', 'Type','char');
T    = readtable(fname, opts);

%Parse datetime (try ISO 'T' then space)
t_raw = datetime(T.('Report Date / Time'), 'InputFormat','dd/MM/yyyy HH:mm', 'TimeZone','UTC');
if any(isnat(t_raw))
    t_raw = datetime(T.DATETIME, 'InputFormat','yyyy-MM-dd HH:mm:ss', 'TimeZone','UTC');
end

%Pick columns (exact names from your CSV)
vars = T.Properties.VariableNames;

ixV  = find(strcmp(vars,'V_hub(t)') | contains(vars,'V_hub','IgnoreCase',true), 1);
ixP  = find(strcmp(vars,'P_turbine(t) MW') | contains(vars,'P_turbine','IgnoreCase',true), 1);

if isempty(ixV) || isempty(ixP)
    error('Could not find V_hub or P_turbine columns. Available columns:\n%s', strjoin(vars,', '));
end

Vhub_raw = T.(vars{ixV});
Pturb_raw = T.(vars{ixP});

% Coerce text to numeric if needed 
if iscellstr(Vhub_raw) || isstring(Vhub_raw) || iscategorical(Vhub_raw)
    s = replace(string(Vhub_raw), ",", ".");
    Vhub_raw = str2double(s);
end
if iscellstr(Pturb_raw) || isstring(Pturb_raw) || iscategorical(Pturb_raw)
    s = replace(string(Pturb_raw), ",", ".");
    Pturb_raw = str2double(s);
end

% Clean: sort, de-dup, remove bad rows
[t_raw, order] = sort(t_raw);
Vhub_raw  = Vhub_raw(order);
Pturb_raw = Pturb_raw(order);

ok = isfinite(Vhub_raw) & isfinite(Pturb_raw) & ~isnat(t_raw);
t_raw     = t_raw(ok);
Vhub_raw  = Vhub_raw(ok);
Pturb_raw = Pturb_raw(ok);

[tu, iu]  = unique(t_raw);
t_raw     = tu;
Vhub_raw  = Vhub_raw(iu);
Pturb_raw = Pturb_raw(iu);

% --- Resample to 10 s grid ---
t0   = t_raw(1);  tend = t_raw(end);
t10  = (t0:seconds(dt_sim):tend)';

Vhub = interp1(t_raw, Vhub_raw,  t10, 'pchip');
Pturb = interp1(t_raw, Pturb_raw, t10, 'pchip');   % units stay (MW)

%% Choose scenario by Date & Time (UTC) 
dur_min = 30;  % scenario length in minutes

startDT = datetime(2025,12,24,18,0,0,'TimeZone','UTC');   % pick date/time here (18 bad scenario)
endDT   = startDT + minutes(dur_min);
idx = (t10 >= startDT) & (t10 <= endDT);

if ~any(idx)
    error("No data in the requested window. Check startDT/endDT are within " + ...
      string(t10(1)) + " to " + string(t10(end)));
end

t0_scn = t10(find(idx,1,'first'));
Vhub_scn = [seconds(t10(idx) - t0_scn), Vhub(idx)];

% ensure Simulink-friendly doubles
Vhub_scn = double(Vhub_scn);

%string(t10(1))
%string(t10(end))

%% Basic parameters 

n60   = round(60/dt);      % samples in 1 minute
tolP   = 1e-3;
tolSOC = 1e-4;
tolCurt = 1;               % MW threshold to count curtailment as active

rho    = 1.23;
D      = 220;
Cp     = 0.48;
v_cin = 3;
v_coff = 25; 
Csite  = 1200;                % MW Dogger_A capacity
Tw     = 600;                % s (window 10 mins)
N      = Tw/dt;               %must be integer 
bMA    = ones(1,N)/N;         % FIR (boxcar) coefficients
ramp_constant = 0.10;       % 10%/min
Rup_p  = ramp_constant*Csite/60;        % MW/s
Rdn_p  = -ramp_constant*Csite/60;       % MW/s
Ps_max = 0.4*Csite;           % MW
Enom   = 480;                 % MWh 
eta_c  = 0.97; eta_d = 0.97;
SOCmin = 0.2;  SOCmax = 0.8;
SOC0   = 0.5;  E0 = SOC0*Enom;% initial energy
h      = 0.05;                %for SOC hysteresys

%Intial conditions
limit = 0.1*Csite;         % 10%/min rule in MW/min
v0 = Vhub_scn(1,2);  % first wind speed in scenario (m/s)
A = pi*(D/2)^2;
K_MW = 0.5*rho*A*Cp/1e6;     % MW per (m/s)^3 (cubic region)
P1_0 = K_MW * v0^3;          % MW, aerodynamic (uncapped)
P1_0 = min(max(P1_0,0), 13); % apply rated cap (13 MW turbine)
Pw0  = 92 * P1_0;            % site MW for Dogger A (92 turbines)

%% Sensitivity scenarios
% battery_sizes = [120 240 360 480 600];            % MW / MWh
% ramp_limits   = [0.05 0.075 0.10 0.125 0.15];     % fraction of capacity per minute
%ramp_limits   = 0.10; %fixed
battery_sizes = [240 480];
ramp_limits   = 0.10;

nB = length(battery_sizes);
nR = length(ramp_limits);

results = struct();

viol_map_BESS   = zeros(nR, nB);
viol_map_hybrid = zeros(nR, nB);

rms_map_BESS    = zeros(nR, nB);
rms_map_hybrid  = zeros(nR, nB);

res_map_BESS    = zeros(nR, nB);
res_map_hybrid  = zeros(nR, nB);

for i = 1:nR
    for j = 1:nB

        % parameters calculations
        Ps_max = battery_sizes(j);
        Enom   = battery_sizes(j);
        E0     = SOC0 * Enom;

        ramp_constant = ramp_limits(i);
        Rup_p =  ramp_constant * Csite / 60;   % MW/s
        Rdn_p = -ramp_constant * Csite / 60;   % MW/s

        assignin('base','Ps_max',Ps_max);
        assignin('base','Enom',Enom);
        assignin('base','E0',E0);
        assignin('base','Rup_p',Rup_p);
        assignin('base','Rdn_p',Rdn_p);

        %% Model run
        out = sim('wind_control');

        % Load signals
        t             = out.tout;
        Praw          = out.Praw_plot;
        Pstar         = out.Pstar_plot;
        Ps            = out.Ps_plot;
        SOC           = out.SOC_plot;
        Pout_BESS     = out.Pout_BESS_plot;
        Pout_pitch    = out.Pout_pitched_plot;
        Pout_hybrid   = out.Pout_hybrid_plot;
        Pcurt_pitch   = out.Pcurt_pitch_plot;
        Pcurt_hybrid  = out.Pcurt_hybrid_plot;

        % Ramp calculations 
        dt_case = mean(diff(t));
        n60 = round(60/dt_case);

        RR1_raw    = Praw(1+n60:end)        - Praw(1:end-n60);
        RR1_BESS   = Pout_BESS(1+n60:end)   - Pout_BESS(1:end-n60);
        RR1_pitch  = Pout_pitch(1+n60:end)  - Pout_pitch(1:end-n60);
        RR1_hybrid = Pout_hybrid(1+n60:end) - Pout_hybrid(1:end-n60);

        t_ramp = t(1+n60:end);

        RR1_raw_pct    = RR1_raw/Csite*100;
        RR1_BESS_pct   = RR1_BESS/Csite*100;
        RR1_pitch_pct  = RR1_pitch/Csite*100;
        RR1_hybrid_pct = RR1_hybrid/Csite*100;

        % 1-minute ramp window limit in MW/min
        limit = ramp_constant * Csite;

        % Metrics structure
        calc_metrics = @(RR) struct( ...
            'max_up',        max(RR), ...
            'max_down',      min(RR), ...
            'max_up_pct',    max(RR)/Csite*100, ...
            'max_down_pct',  abs(min(RR))/Csite*100, ...
            'mean_ramp',     mean(abs(RR)), ...
            'mean_ramp_pct', mean(abs(RR))/Csite*100, ...
            'rms_ramp',      sqrt(mean(RR.^2)), ...
            'rms_ramp_pct',  sqrt(mean(RR.^2))/Csite*100, ...
            'viol_pct',      mean(abs(RR) > limit)*100 ...
        );

        M_raw    = calc_metrics(RR1_raw);
        M_BESS   = calc_metrics(RR1_BESS);
        M_pitch  = calc_metrics(RR1_pitch);
        M_hybrid = calc_metrics(RR1_hybrid);

        % Residuals
        Pres_raw    = Pstar - Praw;
        Pres_BESS   = Pstar - Pout_BESS;
        Pres_pitch  = Pstar - Pout_pitch;
        Pres_hybrid = Pstar - Pout_hybrid;

        MAE_res_BESS_pct   = mean(abs(Pres_BESS))   / Csite * 100;
        MAE_res_hybrid_pct = mean(abs(Pres_hybrid)) / Csite * 100;

        % Battery logic
        time_at_power_limit_pct = mean(abs(abs(Ps) - Ps_max) < tolP) * 100;
        time_at_SOCmax_pct      = mean(abs(SOC - SOCmax) < tolSOC) * 100;
        time_at_SOCmin_pct      = mean(abs(SOC - SOCmin) < tolSOC) * 100;
        time_battery_active_pct = mean(abs(Ps) > tolP) * 100;

        % Curtailment
        if any(Pcurt_pitch > tolCurt)
            curt_pitch_active_pct = mean(Pcurt_pitch > tolCurt) * 100;
        else
            curt_pitch_active_pct = 0;
        end

        if any(Pcurt_hybrid > tolCurt)
            curt_hybrid_active_pct = mean(Pcurt_hybrid > tolCurt) * 100;
        else
            curt_hybrid_active_pct = 0;
        end

        
        %avoided curtaiment
        Ecurt_pitch_MWh   = sum(Pcurt_pitch)  * dt_case / 3600;
        Ecurt_hybrid_MWh  = sum(Pcurt_hybrid) * dt_case / 3600;
        Ecurt_avoided_MWh = Ecurt_pitch_MWh - Ecurt_hybrid_MWh;
        %economical interpritation
        price = 75;   % £/MWh
        value_avoided_curtailment = Ecurt_avoided_MWh * price;
        %% Results
        results(i,j).ramp_constant = ramp_constant;
        results(i,j).ramp_limit_pct = ramp_constant * 100;
        results(i,j).Ps_max = Ps_max;
        results(i,j).Enom = Enom;
        results(i,j).label = sprintf('%d MW / %d MWh, %.1f%%/min', ...
            Ps_max, Enom, ramp_constant*100);

        % key signals
        results(i,j).t = t;
        results(i,j).t_ramp = t_ramp;
        results(i,j).Praw = Praw;
        results(i,j).Pstar = Pstar;
        results(i,j).Ps = Ps;
        results(i,j).SOC = SOC;
        results(i,j).Pout_BESS = Pout_BESS;
        results(i,j).Pout_pitch = Pout_pitch;
        results(i,j).Pout_hybrid = Pout_hybrid;
        results(i,j).Pcurt_pitch = Pcurt_pitch;
        results(i,j).Pcurt_hybrid = Pcurt_hybrid;

        % ramps
        results(i,j).RR1_raw_pct = RR1_raw_pct;
        results(i,j).RR1_BESS_pct = RR1_BESS_pct;
        results(i,j).RR1_pitch_pct = RR1_pitch_pct;
        results(i,j).RR1_hybrid_pct = RR1_hybrid_pct;

        % metrics
        results(i,j).M_raw = M_raw;
        results(i,j).M_BESS = M_BESS;
        results(i,j).M_pitch = M_pitch;
        results(i,j).M_hybrid = M_hybrid;
        results(i,j).viol_hybrid_pct      = M_hybrid.viol_pct;
        results(i,j).rms_hybrid_pct       = M_hybrid.rms_ramp_pct;
        results(i,j).mean_ramp_hybrid_pct = M_hybrid.mean_ramp_pct;
        results(i,j).max_up_hybrid_pct    = M_hybrid.max_up_pct;
        results(i,j).max_down_hybrid_pct  = M_hybrid.max_down_pct;

        % residuals
        results(i,j).MAE_res_BESS_pct = MAE_res_BESS_pct;
        results(i,j).MAE_res_hybrid_pct = MAE_res_hybrid_pct;

        % utilisation
        results(i,j).time_at_power_limit_pct = time_at_power_limit_pct;
        results(i,j).time_at_SOCmax_pct = time_at_SOCmax_pct;
        results(i,j).time_at_SOCmin_pct = time_at_SOCmin_pct;
        results(i,j).time_battery_active_pct = time_battery_active_pct;

        % curtailment
        results(i,j).curt_pitch_active_pct = curt_pitch_active_pct;
        results(i,j).curt_hybrid_active_pct = curt_hybrid_active_pct;
        results(i,j).Ecurt_pitch_MWh            = Ecurt_pitch_MWh;
        results(i,j).Ecurt_hybrid_MWh           = Ecurt_hybrid_MWh;
        results(i,j).Ecurt_avoided_MWh          = Ecurt_avoided_MWh;
        results(i,j).value_avoided_curtailment  = value_avoided_curtailment;

        % matrics for heatmap
        viol_map_BESS(i,j)   = M_BESS.viol_pct;
        viol_map_hybrid(i,j) = M_hybrid.viol_pct;

        rms_map_BESS(i,j)    = M_BESS.rms_ramp_pct;
        rms_map_hybrid(i,j)  = M_hybrid.rms_ramp_pct;

        res_map_BESS(i,j)    = MAE_res_BESS_pct;
        res_map_hybrid(i,j)  = MAE_res_hybrid_pct;

        fprintf('Done: ramp = %.1f %%/min, battery = %d MW/MWh\n', ...
            ramp_constant*100, battery_sizes(j));
    end
end
%% HEATMAP
figure('Color','w','Position',[100 100 700 500])
imagesc(battery_sizes, ramp_limits*100, viol_map_hybrid) %change scenarios (BESS/HYBRID)
set(gca,'YDir','normal')
set(gca,'FontSize',14)

xlabel('Battery size (MW / MWh)','FontSize',14)
ylabel('Ramp-rate limit (%/min)','FontSize',14)

cb = colorbar;
cb.Label.String = 'Ramp violation time (%)';
cb.Label.FontSize = 12;

axis tight
pbaspect([1.2 1 1])   %plot area less stretched

for i = 1:length(ramp_limits)
    for j = 1:length(battery_sizes)
        text(battery_sizes(j), ramp_limits(i)*100, sprintf('%.1f', viol_map_hybrid(i,j)), ...
            'HorizontalAlignment','center', 'FontSize',10, 'Color','w');
    end
end

%Curtailment avoided calculations
for k = 1:length(results)
    t  = results(k).t;
    dt = mean(diff(t));

    Ecurt_pitch_MWh  = sum(results(k).Pcurt_pitch)  * dt / 3600;
    Ecurt_hybrid_MWh = sum(results(k).Pcurt_hybrid) * dt / 3600;

    Ecurt_avoided_MWh = Ecurt_pitch_MWh - Ecurt_hybrid_MWh;
    value_avoided_curtailment = Ecurt_avoided_MWh * price;

    fprintf('\nCase: %s\n', results(k).label);
    fprintf('Pitch curtailment energy: %.2f MWh\n', Ecurt_pitch_MWh);
    fprintf('Hybrid curtailment energy: %.2f MWh\n', Ecurt_hybrid_MWh);
    fprintf('Avoided curtailment: %.2f MWh\n', Ecurt_avoided_MWh);
    fprintf('Avoided curtailment value: £%.2f\n', value_avoided_curtailment);
end
% GRAPH PARAMETERS 
green = [0 0.5 0];   %dark green
red   = [0.85 0 0];  %not bright red
%SOC COMPRASION BESS-ONLY 
figure
plot(results(1).t, results(1).SOC, 'LineWidth', 1.5); hold on
plot(results(2).t, results(2).SOC, 'LineWidth', 1.5)

grid on
xlabel('Time (s)', 'FontSize', 14)
ylabel('State of charge', 'FontSize', 14)
legend(results(1).label, results(2).label, 'Location', 'best', 'FontSize', 12)

set(gca,'FontSize',14)
set(gcf,'Color','w')
ylim([0.15 0.85])

% Residual comprasion BESS-only
figure
plot(results(1).t, results(1).Pres_raw, 'k--', 'LineWidth', 1.2); hold on
plot(results(1).t, results(1).Pres_BESS, 'LineWidth', 1.5)
plot(results(2).t, results(2).Pres_BESS, 'LineWidth', 1.5)

grid on
xlabel('Time (s)', 'FontSize', 14)
ylabel('Residual error (MW)', 'FontSize', 14)
legend('Raw residual', results(1).label, results(2).label, ...
    'Location', 'best', 'FontSize', 12)

set(gca,'FontSize',14)
set(gcf,'Color','w')
ylim([-600 400])

% Timeseries BESS-only
figure
plot(results(1).t, results(1).Praw, 'Color', [0.7 0.7 0.7], 'LineWidth', 1.1); hold on
plot(results(1).t, results(1).Pstar, 'k--', 'LineWidth', 1.4)
plot(results(1).t, results(1).Pout_BESS, 'LineWidth', 1.5)
plot(results(2).t, results(2).Pout_BESS, 'LineWidth', 1.5)

grid on
xlabel('Time (s)', 'FontSize', 14)
ylabel('Power (MW)', 'FontSize', 14)
legend('Raw power', 'Target power', results(1).label, results(2).label, ...
    'Location', 'best', 'FontSize', 12)

set(gca,'FontSize',14)
set(gcf,'Color','w')

% Ramp-rate BESS-only
figure
plot(results(1).t_ramp, results(1).RR1_raw_pct, 'k', 'LineWidth', 1.2); hold on
plot(results(1).t_ramp, results(1).RR1_BESS_pct, 'LineWidth', 1.5)
plot(results(2).t_ramp, results(2).RR1_BESS_pct, 'LineWidth', 1.5)

yline(10, '--k', 'LineWidth', 1.2)
yline(-10, '--k', 'LineWidth', 1.2)

grid on
xlabel('Time (s)', 'FontSize', 14)
ylabel('Ramp rate (%/min)', 'FontSize', 14)
legend('Raw output', results(1).label, results(2).label, ...
    '\pm10%/min limit', 'Location', 'best', 'FontSize', 12)

set(gca,'FontSize',14)
set(gcf,'Color','w')

for k = 1:length(results)
    fprintf('\nCase: %s\n', results(k).label);
    fprintf('BESS violation time: %.2f %%\n', results(k).M_BESS.viol_pct);
    fprintf('BESS RMS ramp: %.2f %%/min\n', results(k).M_BESS.rms_ramp_pct);
    fprintf('BESS mean residual: %.2f %% of capacity\n', results(k).MAE_res_BESS_pct);
    fprintf('Time at SOCmax: %.2f %%\n', results(k).time_at_SOCmax_pct);
    fprintf('Time at SOCmin: %.2f %%\n', results(k).time_at_SOCmin_pct);
end

% Praw and P* plots

figure; hold on; grid on;
plot(t, Praw,  'k',  'LineWidth', 1.5);
plot(t, Pstar, 'r--','LineWidth', 1.5);

set(gca,'FontSize',14)
set(gcf,'Color','w')
xlabel('Time (s)','FontSize',14)
ylabel('Power (MW)','FontSize',14)
title('')   % no title
legend('Raw output','Target power','Location','best','FontSize',12)

% Praw vs 10% limit

figure; hold on; grid on;

plot(t_ramp, RR1_raw_pct, 'k', 'LineWidth', 1.5);
yline(10,  'r--', 'LineWidth', 1.5);
yline(-10, 'r--', 'LineWidth', 1.5);

set(gca,'FontSize',14)    
set(gcf,'Color','w')
xlabel('Time (s)','FontSize',14)
ylabel('Power (MW)','FontSize',14)
title('')   % no title
legend('Raw ramp','±10% limit','Location','best','FontSize',12)
ylim([-35 35])

% Time-series pitch-only
fig1 = figure;
set(fig1, 'Color', 'w');

ax1 = subplot(2,1,1);
plot(t, Praw, 'Color', [0.7 0.7 0.7], 'LineWidth', 1.1); hold on
plot(t, Pstar, 'k--', 'LineWidth', 1.5)
plot(t, Pout_pitch, 'Color', green, 'LineWidth', 1.6)
grid on
ylabel('Power (MW)', 'FontSize', 14)
legend('Raw power','Target power','Pitch-only output', ...
    'Location','best', 'FontSize', 12)
set(ax1, 'FontSize', 14)

ax2 = subplot(2,1,2);
plot(t, Pcurt_pitch, 'Color', green, 'LineWidth', 1.6)
grid on
xlabel('Time (s)', 'FontSize', 14)
ylabel('Curtailment (MW)', 'FontSize', 14)
set(ax2, 'FontSize', 14)
% Ramp-rate pitch only
figure

plot(t_ramp, RR1_raw_pct, 'k', 'LineWidth', 1.5); hold on
plot(t_ramp, RR1_pitch_pct, 'Color', [0 0.5 0], 'LineWidth', 1.6)  % darker green

yline(limit_pct, '--k', 'LineWidth', 1.2)
yline(-limit_pct, '--k', 'LineWidth', 1.2)

grid on
xlabel('Time (s)','FontSize',14)
ylabel('Ramp rate (%/min)','FontSize',14)
title('','FontSize',16)   % remove title for report
legend('Raw output','Pitch-only output','\pm10%/min limit','Location','northwest','FontSize',12)

set(gca,'FontSize',14)
set(gcf,'Color','w')

% Residual pitch-only 
fig2 = figure;
set(fig2, 'Color', 'w');

ax3 = axes;

plot(t, Pstar - Praw, 'k--', 'LineWidth', 1.2); hold on   % raw residual
plot(t, Pres_pitch, 'Color', green, 'LineWidth', 1.6)     % pitch residual

grid on
xlabel('Time (s)', 'FontSize', 14)
ylabel('Residual error (MW)', 'FontSize', 14)

legend('Raw residual','Pitch-only residual','Location','best','FontSize',12)

set(ax3, 'FontSize', 14)
xline(700, '--', 'Oversupply peak', 'HandleVisibility', 'off')

% Pitch-only violation 
viol_raw   = abs(RR1_raw_pct) > 10;
viol_pitch = abs(RR1_pitch_pct) > 10;

figure
plot(t_ramp, viol_raw, 'k'); hold on
plot(t_ramp, viol_pitch, 'g')
ylim([-0.2 1.2])
legend('Raw violations','Pitch violations')

% Time-series Hybrid 
fig1 = figure;
set(fig1, 'Color', 'w');

ax1 = subplot(2,1,1);
plot(results(2).t, results(2).Praw,  'Color', [0.7 0.7 0.7], 'LineWidth', 1.1); hold on
plot(results(2).t, results(2).Pstar, 'k--', 'LineWidth', 1.5)
plot(results(2).t, results(2).Pout_hybrid, 'Color', red, 'LineWidth', 1.6)

grid on
ylabel('Power (MW)', 'FontSize', 14)
legend('Raw power', 'Target power', 'Hybrid output', ...
    'Location', 'best', 'FontSize', 12)
set(ax1, 'FontSize', 14)

ax2 = subplot(2,1,2);
plot(results(2).t, results(2).Pcurt_hybrid, 'Color', red, 'LineWidth', 1.6)

grid on
xlabel('Time (s)', 'FontSize', 14)
ylabel('Curtailment (MW)', 'FontSize', 14)
set(ax2, 'FontSize', 14)


% Energy Hybrid
fig2 = figure;
set(fig2, 'Color', 'w');

ax1 = subplot(2,1,1);
plot(results(2).t, results(2).SOC, 'b', 'LineWidth', 1.6); hold on
yline(0.8, '--k', 'LineWidth', 1.0)
yline(0.2, '--k', 'LineWidth', 1.0)

grid on
ylabel('SOC', 'FontSize', 14)
legend('Battery SOC', 'SOC_{max}', 'SOC_{min}', ...
    'Location', 'best', 'FontSize', 12)
set(ax1, 'FontSize', 14)

ax2 = subplot(2,1,2);
plot(results(2).t, results(2).Pcurt_hybrid, 'Color', red, 'LineWidth', 1.6)

grid on
xlabel('Time (s)', 'FontSize', 14)
ylabel('Curtailment (MW)', 'FontSize', 14)
set(ax2, 'FontSize', 14)

% Ramp-rate ALL
fig3 = figure;
set(fig3, 'Color', 'w');

plot(results(2).t_ramp, results(2).RR1_raw_pct,    'k', 'LineWidth', 1.2); hold on
plot(results(2).t_ramp, results(2).RR1_BESS_pct,   'b', 'LineWidth', 1.4)
plot(results(2).t_ramp, results(2).RR1_pitch_pct,  'Color', green, 'LineWidth', 1.4)
plot(results(2).t_ramp, results(2).RR1_hybrid_pct, 'Color', red, 'LineWidth', 1.5)

yline(10,  '--k', 'LineWidth', 1.0)
yline(-10, '--k', 'LineWidth', 1.0)

grid on
xlabel('Time (s)', 'FontSize', 14)
ylabel('Ramp rate (%/min)', 'FontSize', 14)
legend('Raw output', 'BESS output', 'Pitch-only output', 'Hybrid output', ...
    '\pm10%/min limit', 'Location', 'best', 'FontSize', 12)

set(gca, 'FontSize', 14)

% Ramp-rate distribution (BOX plot)
fig4 = figure;
set(fig4, 'Color', 'w');

mask = abs(results(2).RR1_raw_pct) > 5;  % only meaningful ramps

boxplot([results(2).RR1_raw_pct(mask), ...
         results(2).RR1_pitch_pct(mask), ...
         results(2).RR1_BESS_pct(mask), ...
         results(2).RR1_hybrid_pct(mask)], ...
         'Labels', {'Raw','Pitch','BESS','Hybrid'})

grid on
ylabel('Ramp rate (%/min)', 'FontSize', 14)
set(gca, 'FontSize', 14)

% optional axis zoom
ylim([-40 40])

% Residual ALL

green = [0 0.5 0];
red   = [0.85 0 0];

fig5 = figure;
set(fig5, 'Color', 'w');

plot(results(2).t, results(2).Pres_raw,    'k--', 'LineWidth', 1.2); hold on
plot(results(2).t, results(2).Pres_BESS,   'b',   'LineWidth', 1.4)
plot(results(2).t, results(2).Pres_pitch,  'Color', green, 'LineWidth', 1.4)
plot(results(2).t, results(2).Pres_hybrid, 'Color', red,   'LineWidth', 1.6)

grid on
xlabel('Time (s)', 'FontSize', 14)
ylabel('Residual error (MW)', 'FontSize', 14)
legend('Raw residual', 'BESS residual', 'Pitch-only residual', 'Hybrid residual', ...
    'Location', 'best', 'FontSize', 12)

set(gca, 'FontSize', 14)


figure
plot(results(2).t, results(2).Ps, 'b', 'LineWidth', 1.5); hold on
yline(results(2).Ps_max, '--k', 'LineWidth', 1.2)
yline(-results(2).Ps_max, '--k', 'LineWidth', 1.2)
grid on
xlabel('Time (s)')
ylabel('Battery power (MW)')
legend('Battery power','\pm Power limit','Location','best')
set(gca,'FontSize',14)
set(gcf,'Color','w')
xlim([600 800])





