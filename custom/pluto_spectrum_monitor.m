function pluto_spectrum_monitor
% Generic PlutoSDR spectrum monitor. Change cfg.CenterFrequency to retune.
% PSD is relative to normalized complex full scale (dBFS/Hz), not calibrated dBm.

cfg.CenterFrequency = 844e6; % Change this value to monitor another center frequency.
cfg.PlotSpan_Hz = 2e6;      % Display +/- 1 MHz around the center frequency.
cfg.SampleRate = 4e6;
cfg.Gain = 30;
cfg.FFTSize = 8192;
cfg.FrameSamples = 65536;
cfg.ThresholdAboveFloor_dB = 10;
cfg.LoRaBW = 125e3;
cfg.WaterfallRows = 300;
cfg.PlotUpdatePeriod_s = 0.10; % Target 10 GUI refreshes per second.
cfg.LogPeriod_s = 0.25;       % Keep CSV logging at 4 rows per second.
cfg.OutputDir = fullfile(fileparts(fileparts(mfilename('fullpath'))),'pluto_monitor_results');
cfg.MaxIQFrames = 0; % 0 disables raw IQ; positive value caps captured frames.

if ~exist(cfg.OutputDir,'dir'), mkdir(cfg.OutputDir); end
stamp = char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'));
freqTag = sprintf('%gMHz_',cfg.CenterFrequency/1e6);
measurementFile = fullfile(cfg.OutputDir,[freqTag 'measurements_' stamp '.csv']);
eventFile = fullfile(cfg.OutputDir,[freqTag 'events_' stamp '.csv']);
iqFile = fullfile(cfg.OutputDir,[freqTag 'raw_iq_' stamp '.mat']);

rx = sdrrx('Pluto','CenterFrequency',cfg.CenterFrequency, ...
    'BasebandSampleRate',cfg.SampleRate,'GainSource','Manual','Gain',cfg.Gain, ...
    'SamplesPerFrame',cfg.FrameSamples,'OutputDataType','double');
cleanup = onCleanup(@()release(rx)); %#ok<NASGU>
try
    actual = info(rx);
catch ME
    error('PlutoMonitor:Connection','Could not query Pluto radio: %s',ME.message);
end
disp(actual);
fprintf('Requested %.6f MHz; actual %.6f MHz. Requested Fs %.3f MSps; actual %.3f MSps.\n', ...
    cfg.CenterFrequency/1e6,actual.CenterFrequency/1e6, ...
    cfg.SampleRate/1e6,actual.BasebandSampleRate/1e6);
if cfg.CenterFrequency < 325e6 || cfg.CenterFrequency > 3.8e9
    warning('PlutoMonitor:OutsideQualifiedRange', ...
        'The selected center frequency is outside the Pluto 325 MHz-3.8 GHz qualified range.');
end
if abs(actual.BasebandSampleRate-cfg.SampleRate)/cfg.SampleRate > 1e-3
    fprintf(2,'WARNING: actual sample rate differs materially from request.\n');
end

fs = actual.BasebandSampleRate;
if cfg.PlotSpan_Hz <= 0 || cfg.PlotSpan_Hz > fs
    error('PlotSpan_Hz must be positive and no greater than the actual sample rate.');
end
centerMHz = actual.CenterFrequency/1e6;
halfSpanMHz = cfg.PlotSpan_Hz/(2e6);
halfChannelMHz = cfg.LoRaBW/(2e6);
nfft = cfg.FFTSize;
if nfft > cfg.FrameSamples || mod(cfg.FrameSamples,nfft) ~= 0
    error('FFTSize must divide FrameSamples and be no larger than it.');
end
win = hann(nfft,'periodic');
windowPower = sum(win.^2);
noverlap = nfft/2;
hop = nfft-noverlap;
freq = actual.CenterFrequency + (-nfft/2:nfft/2-1)'*(fs/nfft);
keep = freq >= actual.CenterFrequency-cfg.PlotSpan_Hz/2 & ...
    freq <= actual.CenterFrequency+cfg.PlotSpan_Hz/2;
freqMHz = freq(keep)/1e6;
channel = abs(freq-actual.CenterFrequency) <= cfg.LoRaBW/2;
channel = channel(keep);

% GUI controls are intentionally lightweight; acquisition and detection run
% continuously while drawing/logging at a throttled rate.
fig = figure('Name',sprintf('Pluto %.6f MHz Passive Spectrum Monitor',centerMHz), ...
    'NumberTitle','off','Color','w','CloseRequestFcn',@stopMonitor);
stopRequested = false;
uicontrol(fig,'Style','pushbutton','String','Stop','Units','normalized', ...
    'Position',[.90 .94 .08 .045],'Callback',@stopMonitor);
uicontrol(fig,'Style','text','String','Threshold above local floor (dB)', ...
    'Units','normalized','Position',[.55 .94 .22 .04],'BackgroundColor','w');
thresholdBox = uicontrol(fig,'Style','edit','String',num2str(cfg.ThresholdAboveFloor_dB), ...
    'Units','normalized','Position',[.77 .945 .09 .035]);
ax1 = subplot(2,1,1,'Parent',fig);
hold(ax1,'on'); grid(ax1,'on');
hNow = plot(ax1,freqMHz,nan(size(freqMHz)),'b');
hAvg = plot(ax1,freqMHz,nan(size(freqMHz)),'r','LineWidth',1.1);
hMax = plot(ax1,freqMHz,nan(size(freqMHz)),'Color',[.4 .4 .4]);
avgBox = uicontrol(fig,'Style','checkbox','String','Time average','Value',1, ...
    'Units','normalized','Position',[.02 .94 .17 .04], ...
    'BackgroundColor','w','Callback',@toggleAverage);
maxBox = uicontrol(fig,'Style','checkbox','String','Max hold','Value',1, ...
    'Units','normalized','Position',[.20 .94 .13 .04], ...
    'BackgroundColor','w','Callback',@toggleMaxHold);
yl = ylim(ax1); %#ok<NASGU>
patch(ax1,[centerMHz-halfChannelMHz centerMHz+halfChannelMHz ...
    centerMHz+halfChannelMHz centerMHz-halfChannelMHz],[-200 -200 20 20], ...
    [1 .85 .75],'FaceAlpha',.25,'EdgeColor','none','HandleVisibility','off');
uistack(hNow,'top'); uistack(hAvg,'top'); uistack(hMax,'top');
xlim(ax1,[centerMHz-halfSpanMHz centerMHz+halfSpanMHz]);
xlabel(ax1,'Frequency (MHz)'); ylabel(ax1,'PSD (dBFS/Hz)');
title(ax1,sprintf('Live PSD, time average and max hold | center %.6f MHz',actual.CenterFrequency/1e6));
legend(ax1,{'Current PSD','Time average PSD','Max hold'},'Location','best');
ax2 = subplot(2,1,2,'Parent',fig);
wf = nan(cfg.WaterfallRows,sum(keep),'single');
hImg = imagesc(ax2,freqMHz,1:cfg.WaterfallRows,wf);
axis(ax2,'xy'); xlim(ax2,[centerMHz-halfSpanMHz centerMHz+halfSpanMHz]);
xlabel(ax2,'Frequency (MHz)'); ylabel(ax2,'Recent frames');
title(ax2,'Waterfall (color: dBFS/Hz)'); colorbar(ax2);

meas = fopen(measurementFile,'w'); evlog = fopen(eventFile,'w');
assert(meas~=-1 && evlog~=-1,'Cannot create CSV output files.');
closeFiles = onCleanup(@()closeLogs(meas,evlog)); %#ok<NASGU>
fprintf(meas,'timestamp,requested_center_Hz,actual_center_Hz,actual_fs_Hz,rx_gain_dB,peak_freq_Hz,peak_psd_dBFS_Hz,channel_peak_dBFS_Hz,channel_mean_dBFS_Hz,threshold_dB,detected_count,condition,location,antenna\n');
fprintf(evlog,'start_time,end_time,center_freq_Hz,bandwidth_Hz,max_psd_dBFS_Hz,max_excess_dB,duration_s,overlaps_LoRa125kHz,classification\n');

condition = inputdlg('Measurement condition (TX off / TX on):','Run metadata',1,{'TX off'});
if isempty(condition), condition={'unspecified'}; end
location = inputdlg('Location (lab / outdoors / other building):','Run metadata',1,{'lab'});
if isempty(location), location={'unspecified'}; end
antenna = inputdlg('Antenna / termination:','Run metadata',1,{'unspecified'});
if isempty(antenna), antenna={'unspecified'}; end

avgPower = zeros(sum(keep),1);
maxPower = -inf(sum(keep),1);
avgCount = 0; wfRow = 0; lastDraw = tic; lastLog = tic;
iq = {}; iqCount = 0;
% Active event holds one row per detected frequency cluster; expires after
% a missed-frame grace interval. This bounded state avoids history growth.
active = struct('fc',{},'bw',{},'maxP',{},'maxExcess',{},'start',{},'last',{},'hits',{});
fprintf('Monitoring continuously. Stop with the button or close the figure.\n');
while ~stopRequested && isvalid(fig)
    try
        x = rx();
    catch ME
        warning('PlutoMonitor:Receive','Receive error: %s',ME.message); break
    end
    if isempty(x), continue; end
    if cfg.MaxIQFrames > 0 && iqCount < cfg.MaxIQFrames
        iqCount=iqCount+1; iq{iqCount}=x; %#ok<AGROW>
    end
    % Welch estimate: average overlapped Hann-windowed periodograms.
    nseg = floor((numel(x)-nfft)/hop)+1;
    p = zeros(nfft,1);
    for s=1:nseg
        ix=(s-1)*hop+(1:nfft);
        X=fftshift(fft(x(ix).*win,nfft));
        p=p+(abs(X).^2)/(fs*windowPower);
    end
    p=p/max(nseg,1);
    psd=10*log10(max(p,realmin));
    psdBand=psd(keep);
    % Local noise-floor estimate is the median in a 101-bin moving window.
    floorDb=movmedian(psdBand,101,'Endpoints','shrink');
    threshold=str2double(get(thresholdBox,'String'));
    if ~isfinite(threshold) || threshold<0, threshold=cfg.ThresholdAboveFloor_dB; end
    mask=(psdBand-floorDb)>=threshold;
    mask=fillShortGaps(mask,2);
    clusters=maskToClusters(mask,freqMHz,psdBand-floorDb,psdBand);
    nowT=datetime('now','Format','yyyy-MM-dd HH:mm:ss.SSS');
    tsec=posixtime(nowT);
    active=updateEvents(active,clusters,tsec,evlog,cfg.LoRaBW,actual.CenterFrequency);
    avgCount=avgCount+1; avgPower=avgPower+(10.^(psdBand/10)-avgPower)/avgCount;
    maxPower=max(maxPower,10.^(psdBand/10));
    wfRow=mod(wfRow,cfg.WaterfallRows)+1; wf(wfRow,:)=single(psdBand);
    if toc(lastLog)>=cfg.LogPeriod_s
        [~,ip]=max(psdBand);
        ch=psd(channel); chMean=10*log10(mean(10.^(ch/10)));
        fprintf(meas,'%s,%.0f,%.0f,%.3f,%.1f,%.3f,%.3f,%.3f,%.3f,%.1f,%d,"%s","%s","%s"\n', ...
            char(nowT),cfg.CenterFrequency,actual.CenterFrequency,fs,cfg.Gain, ...
            freqMHz(ip)*1e6,psdBand(ip),max(ch),chMean,threshold,numel(clusters), ...
            csvSafe(condition{1}),csvSafe(location{1}),csvSafe(antenna{1}));
        lastLog=tic;
    end
    if toc(lastDraw)>=cfg.PlotUpdatePeriod_s && isvalid(fig)
        set(hNow,'YData',psdBand);
        set(hAvg,'YData',10*log10(max(avgPower,realmin)));
        set(hMax,'YData',10*log10(max(maxPower,realmin)));
        set(hImg,'CData',wf);
        set(ax2,'YLim',[1 cfg.WaterfallRows]);
        drawnow limitrate;
        lastDraw=tic;
    end
end
% Flush active events at stop and optionally save a bounded IQ capture.
active=updateEvents(active,[],posixtime(datetime('now')),evlog,cfg.LoRaBW,actual.CenterFrequency,true); %#ok<NASGU>
if ~isempty(iq), save(iqFile,'iq','cfg','actual','-v7.3'); fprintf('Raw IQ saved: %s\n',iqFile); end
fprintf('Measurement CSV: %s\nEvent CSV: %s\n',measurementFile,eventFile);
fprintf('Frames logged: %d; detected events finalized at stop. PSD values are relative dBFS/Hz.\n',avgCount);

    function stopMonitor(~,~)
        stopRequested=true;
        if isvalid(fig), set(fig,'CloseRequestFcn',''); delete(fig); end
    end

    function toggleAverage(~,~)
        if get(avgBox,'Value'), set(hAvg,'Visible','on');
        else, set(hAvg,'Visible','off'); end
    end

    function toggleMaxHold(~,~)
        if get(maxBox,'Value'), set(hMax,'Visible','on');
        else, set(hMax,'Visible','off'); end
    end
end

function clusters=maskToClusters(mask,freqMHz,excess,power)
edges=diff([false;mask(:);false]); starts=find(edges==1); stops=find(edges==-1)-1;
clusters=struct('fc',{},'bw',{},'maxP',{},'maxExcess',{});
for k=1:numel(starts)
    ix=starts(k):stops(k);
    [mp,j]=max(power(ix));
    clusters(k).fc=freqMHz(ix(j))*1e6;
    clusters(k).bw=numel(ix)*(freqMHz(2)-freqMHz(1))*1e6;
    clusters(k).maxP=mp;
    clusters(k).maxExcess=max(excess(ix));
end
end

function mask=fillShortGaps(mask,maxGap)
mask=mask(:); z=diff([true;mask;true]); a=find(z==-1); b=find(z==1)-1;
for k=1:numel(a)
    if b(k)-a(k)+1<=maxGap, mask(a(k):b(k))=true; end
end
end

function active=updateEvents(active,c,t,fh,bwCh,center,flush)
if nargin<7, flush=false; end
used=false(1,numel(active));
for j=1:numel(c)
    if isempty(active), ix=[]; else, ix=find(abs([active.fc]-c(j).fc)<max(2*c(j).bw,20e3),1); end
    if isempty(ix)
        e=struct('fc',c(j).fc,'bw',c(j).bw,'maxP',c(j).maxP,'maxExcess',c(j).maxExcess,'start',t,'last',t,'hits',1);
        active(end+1)=e; ix=numel(active); %#ok<AGROW>
    else
        active(ix).fc=c(j).fc; active(ix).bw=max(active(ix).bw,c(j).bw);
        active(ix).maxP=max(active(ix).maxP,c(j).maxP);
        active(ix).maxExcess=max(active(ix).maxExcess,c(j).maxExcess);
        active(ix).last=t; active(ix).hits=active(ix).hits+1;
    end
    used(ix)=true;
end
for k=numel(active):-1:1
    if flush || t-active(k).last>1.0
        dur=max(active(k).last-active(k).start,0);
        overlap=abs(active(k).fc-center)<= (active(k).bw+bwCh)/2;
        if active(k).hits>=4 && dur>=1.0, label='persistent'; else, label='intermittent'; end
        t0=char(datetime(active(k).start,'ConvertFrom','posixtime','Format','yyyy-MM-dd HH:mm:ss.SSS'));
        t1=char(datetime(active(k).last,'ConvertFrom','posixtime','Format','yyyy-MM-dd HH:mm:ss.SSS'));
        fprintf(fh,'"%s","%s",%.0f,%.0f,%.2f,%.2f,%.3f,%d,%s\n', ...
            t0,t1,active(k).fc,active(k).bw,active(k).maxP,active(k).maxExcess,dur,overlap,label);
        active(k)=[];
    end
end
end

function s=csvSafe(s)
s=strrep(char(s),'"','""');
end

function closeLogs(a,b)
if a~=-1, fclose(a); end
if b~=-1, fclose(b); end
end
